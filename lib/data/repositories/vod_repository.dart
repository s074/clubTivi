import 'package:collection/collection.dart';
import 'package:logger/logger.dart';
import 'package:string_similarity/string_similarity.dart';
import '../datasources/local/database.dart' as db;
import '../datasources/remote/trakt_client.dart';
import '../datasources/remote/tmdb_client.dart';
import '../datasources/remote/debrid_service.dart';
import '../datasources/remote/torrent_search_client.dart';
import '../datasources/remote/xtream_client.dart';
import '../../core/fuzzy_match.dart';
import '../models/vod_title.dart';

/// Combines Trakt, TMDB, debrid, torrent search, and local Xtream VOD/series
/// catalogs into a unified VOD data source
class VodRepository {
  final TraktClient? _trakt;
  final TmdbClient? _tmdb;
  final DebridService? _debrid;
  final TorrentSearchClient _torrentSearch;
  final db.AppDatabase? _db;
  final _log = Logger(printer: SimplePrinter());

  VodRepository({
    TraktClient? trakt,
    TmdbClient? tmdb,
    DebridService? debrid,
    TorrentSearchClient? torrentSearch,
    db.AppDatabase? database,
  })  : _trakt = trakt,
        _tmdb = tmdb,
        _debrid = debrid,
        _torrentSearch = torrentSearch ?? TorrentSearchClient(),
        _db = database;

  bool get hasTrakt => _trakt != null;
  bool get hasTmdb => _tmdb != null;
  bool get hasDebrid => _debrid != null;
  bool get hasXtreamDb => _db != null;

  /// Get trending series, enriched with TMDB posters
  Future<List<VodTitle>> getTrendingSeries({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final series = await _trakt.getTrendingSeries(page: page, limit: limit);
      return _enrichWithTmdb(series);
    }
    if (_tmdb != null) {
      return _tmdbResultsToVodTitles(await _tmdb.getTrendingTv(page: page), VodTitleType.series);
    }
    return [];
  }

  /// Get popular series, enriched with TMDB posters
  Future<List<VodTitle>> getPopularSeries({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final series = await _trakt.getPopularSeries(page: page, limit: limit);
      return _enrichWithTmdb(series);
    }
    if (_tmdb != null) {
      return _tmdbResultsToVodTitles(await _tmdb.getPopularTv(page: page), VodTitleType.series);
    }
    return [];
  }

  /// Get trending movies, enriched with TMDB posters
  Future<List<VodTitle>> getTrendingMovies({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final movies = await _trakt.getTrendingMovies(page: page, limit: limit);
      return _enrichWithTmdb(movies);
    }
    if (_tmdb != null) {
      return _tmdbResultsToVodTitles(await _tmdb.getTrendingMovie(page: page), VodTitleType.movie);
    }
    return [];
  }

  /// Get popular movies, enriched with TMDB posters
  Future<List<VodTitle>> getPopularMovies({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final movies = await _trakt.getPopularMovies(page: page, limit: limit);
      return _enrichWithTmdb(movies);
    }
    if (_tmdb != null) {
      return _tmdbResultsToVodTitles(await _tmdb.getPopularMovie(page: page), VodTitleType.movie);
    }
    return [];
  }

  /// Search shows and movies
  Future<List<VodTitle>> search(String query) async {
    if (_trakt != null) {
      final results = await _trakt.search(query);
      return _enrichWithTmdb(results);
    }
    if (_tmdb != null) {
      final tvResults = await _tmdb.searchTv(query);
      final movieResults = await _tmdb.searchMovie(query);
      return [
        ..._tmdbResultsToVodTitles(tvResults, VodTitleType.series),
        ..._tmdbResultsToVodTitles(movieResults, VodTitleType.movie),
      ];
    }
    return [];
  }

  /// Get full VOD title detail with seasons
  Future<VodTitleDetail?> getVodTitleDetail(int traktId, {VodTitleType type = VodTitleType.series}) async {
    // Trakt-based detail
    if (_trakt != null) {
      final vodTitle = type == VodTitleType.movie
          ? await _trakt.getMovie(traktId)
          : await _trakt.getSeries(traktId);
      final enriched = await _enrichSingle(vodTitle);

      List<Season> seasons = [];
      if (type == VodTitleType.series) {
        seasons = await _trakt.getSeasons(traktId);
        seasons = seasons.where((s) => s.number > 0).toList();
        if (_tmdb != null && enriched.tmdbId != null) {
          seasons = await _enrichSeasons(enriched.tmdbId!, seasons);
        }
      }
      return VodTitleDetail(vodTitle: enriched, seasons: seasons);
    }

    // TMDB-only fallback — traktId is actually tmdbId in this case
    if (_tmdb != null) {
      return _getVodTitleDetailFromTmdb(traktId, type: type);
    }

    return null;
  }

  /// TMDB-only VOD title detail
  Future<VodTitleDetail?> _getVodTitleDetailFromTmdb(int tmdbId, {VodTitleType type = VodTitleType.series}) async {
    if (_tmdb == null) return null;
    try {
      final detail = type == VodTitleType.movie
          ? await _tmdb.getMovie(tmdbId)
          : await _tmdb.getTvShow(tmdbId);

      _log.i('TMDB detail for $tmdbId: title=${detail.title}, imdb=${detail.imdbId}, seasons=${detail.numberOfSeasons}');

      final vodTitle = VodTitle(
        traktId: tmdbId,
        tmdbId: tmdbId,
        imdbId: detail.imdbId,
        title: detail.title,
        posterUrl: detail.posterUrl.isNotEmpty ? detail.posterUrl : null,
        backdropUrl: detail.backdropUrl.isNotEmpty ? detail.backdropUrl : null,
        overview: detail.overview,
        rating: detail.voteAverage,
        votes: detail.voteCount,
        year: detail.year,
        genres: detail.genres,
        type: type,
      );

      // For TV shows, build seasons list from TMDB
      List<Season> seasons = [];
      if (type == VodTitleType.series) {
        final numSeasons = detail.numberOfSeasons ?? 0;
        _log.i('Fetching $numSeasons seasons for ${detail.title}');
        for (int i = 1; i <= numSeasons; i++) {
          try {
            final tmdbSeason = await _tmdb.getTvSeason(tmdbId, i);
            seasons.add(Season(
              number: i,
              overview: tmdbSeason.overview,
              episodeCount: tmdbSeason.episodes.length,
              airedEpisodes: tmdbSeason.episodes.length,
              posterUrl: tmdbSeason.posterPath != null
                  ? TmdbClient.posterUrl(tmdbSeason.posterPath)
                  : null,
            ));
          } catch (e) {
            _log.w('Failed to fetch season $i for $tmdbId: $e');
            seasons.add(Season(number: i));
          }
        }
      }

      return VodTitleDetail(vodTitle: vodTitle, seasons: seasons);
    } catch (e) {
      _log.e('TMDB detail failed for $tmdbId: $e');
      return null;
    }
  }

  /// Get episodes for a season
  Future<List<Episode>> getEpisodes(int traktId, int seasonNumber) async {
    // Trakt-based
    if (_trakt != null) {
      final episodes = await _trakt.getEpisodes(traktId, seasonNumber);
      if (_tmdb != null) {
        try {
          final vodTitle = await _trakt.getSeries(traktId);
          if (vodTitle.tmdbId != null) {
            return _enrichEpisodesWithTmdb(episodes, vodTitle.tmdbId!, seasonNumber);
          }
        } catch (_) {}
      }
      return episodes;
    }

    // TMDB-only fallback — traktId is actually tmdbId
    if (_tmdb != null) {
      return _getEpisodesFromTmdb(traktId, seasonNumber);
    }

    return [];
  }

  /// Get episodes directly from TMDB
  Future<List<Episode>> _getEpisodesFromTmdb(int tmdbId, int seasonNumber) async {
    if (_tmdb == null) return [];
    try {
      final tmdbSeason = await _tmdb.getTvSeason(tmdbId, seasonNumber);
      return tmdbSeason.episodes.map((e) => Episode(
        season: seasonNumber,
        number: e.episodeNumber,
        title: e.name,
        overview: e.overview,
        rating: e.voteAverage,
        stillUrl: e.stillUrl.isNotEmpty ? e.stillUrl : null,
        tmdbId: e.episodeNumber,
      )).toList();
    } catch (e) {
      _log.e('TMDB episodes failed for $tmdbId S$seasonNumber: $e');
      return [];
    }
  }

  /// Find streams for a show/movie. Merges instant Xtream matches from the
  /// local DB (stored at provider refresh — no live API calls) with
  /// torrent sources so the user can pick. Xtream direct-play sources
  /// come first, then cached torrents, then the rest.
  Future<List<ResolvedStream>> resolveStreams({
    required String imdbId,
    String? title,
    int? year,
    int? tmdbId,
    VodTitleType mediaType = VodTitleType.movie,
    int? season,
    int? episode,
  }) async {
    // Step 0: Xtream matches from the local DB (best-effort, never throws)
    var xtreamStreams = <ResolvedStream>[];
    if (title != null && title.isNotEmpty) {
      try {
        xtreamStreams = await findXtreamStreams(
          title: title,
          year: year,
          tmdbId: tmdbId,
          mediaType: mediaType,
          season: season,
          episode: episode,
        );
      } catch (e) {
        _log.w('Xtream DB lookup failed for $title: $e');
      }
    }

    // Step 1: Search for torrent hashes via Torrentio
    List<TorrentResult> torrents;
    try {
      if (season != null && episode != null) {
        torrents = await _torrentSearch.searchEpisode(
          imdbId,
          season: season,
          episode: episode,
        );
      } else {
        torrents = await _torrentSearch.searchMovie(imdbId);
      }
    } catch (e) {
      _log.w('Torrent search failed for $imdbId: $e');
      torrents = [];
    }

    if (torrents.isEmpty) {
      _log.w('No torrents found for $imdbId');
      return xtreamStreams;
    }

    // Sort by quality (best first)
    torrents.sort((a, b) => b.qualityScore.compareTo(a.qualityScore));

    // Step 2: Check debrid instant availability
    Set<String> cachedHashes = {};
    if (_debrid != null) {
      try {
        final hashes = torrents.map((t) => t.infoHash).toList();
        final available = await _debrid.checkInstantAvailability(hashes);
        cachedHashes = available.keys.toSet();
      } catch (e) {
        _log.w('Debrid availability check failed: $e');
      }
    }

    // Step 3: Build stream list — Xtream direct-play first, then cached,
    // then non-cached torrents
    final results = <ResolvedStream>[...xtreamStreams];
    for (final torrent in torrents) {
      final hashLower = torrent.infoHash.toLowerCase();
      final cached = cachedHashes.contains(hashLower);
      results.add(ResolvedStream(
        url: '', // resolved on-demand when user picks
        filename: torrent.title.isNotEmpty ? torrent.title : torrent.name,
        quality: torrent.quality.isNotEmpty ? torrent.quality : null,
        filesize: null,
        source: cached ? 'real-debrid ⚡' : 'torrent',
        isCached: cached,
        magnetUrl: torrent.magnetUrl,
        seeds: torrent.seeds,
      ));
      if (results.length >= 15) break;
    }

    // Sort: direct-play + cached first (stable for the rest)
    results.sort((a, b) {
      final aInstant = a.isDirectPlay || a.isCached;
      final bInstant = b.isDirectPlay || b.isCached;
      if (aInstant != bInstant) return aInstant ? -1 : 1;
      return 0;
    });

    return results;
  }

  /// Find Xtream VOD/series matches for a title in the local DB.
  ///
  /// Movies resolve to prebuilt direct-play URLs stored at refresh time.
  /// Series resolve the exact season/episode via a single `get_series_info`
  /// call per candidate (the catalog match itself needs no API calls).
  /// Matching combines the provider's TMDB id (exact, when populated) with
  /// a gated title comparison so partial-word hits like a sports event
  /// mentioning the title don't surface. Returns at most 5 streams,
  /// best match first.
  Future<List<ResolvedStream>> findXtreamStreams({
    required String title,
    int? year,
    int? tmdbId,
    VodTitleType mediaType = VodTitleType.movie,
    int? season,
    int? episode,
  }) async {
    final database = _db;
    if (database == null) return [];

    final query = _normalizeXtreamTitle(title);
    if (query.isEmpty) return [];

    final providers = await database.getAllProviders();
    final xtreamProviders = providers.where((p) => p.type == 'xtream').toList();
    if (xtreamProviders.isEmpty) return [];
    final providerNames = {for (final p in xtreamProviders) p.id: p.name};

    if (mediaType == VodTitleType.movie) {
      final candidates = await database.searchXtreamVod(_likeToken(query));
      final ranked = _rankByTitle(
        candidates
            .map((c) => (name: c.name, tmdb: c.tmdb, value: c))
            .toList(),
        query,
        year: year,
        tmdbId: tmdbId,
      );
      return ranked.take(5).map((c) {
        final vod = c.value;
        return ResolvedStream(
          url: vod.streamUrl,
          filename: vod.name,
          source: 'Xtream 📺 ${providerNames[vod.providerId] ?? ''}'.trim(),
          isCached: true,
          providerId: vod.providerId,
        );
      }).toList();
    }

    // TV show: match series rows, then resolve the episode URL on demand.
    final candidates = await database.searchXtreamSeries(_likeToken(query));
    final ranked = _rankByTitle(
      candidates
          .map((c) => (name: c.name, tmdb: c.tmdb, value: c))
          .toList(),
      query,
      year: year,
      tmdbId: tmdbId,
    );

    final results = <ResolvedStream>[];
    for (final c in ranked.take(3)) {
      final row = c.value;
      final provider = xtreamProviders
          .where((p) => p.id == row.providerId)
          .firstOrNull;
      if (provider?.url == null ||
          provider?.username == null ||
          provider?.password == null) {
        continue;
      }
      // Without a specific episode, offer the series entry itself when the
      // caller only needs a series-level match.
      if (season == null || episode == null) {
        results.add(ResolvedStream(
          url: '',
          filename: '${row.name} (series)',
          source: 'Xtream 📺 ${provider!.name}',
          isCached: true,
          providerId: row.providerId,
          xtreamSeriesId: row.seriesId,
        ));
        continue;
      }
      try {
        final client = XtreamClient(
          baseUrl: provider!.url!,
          username: provider.username!,
          password: provider.password!,
        );
        try {
          final resolved = await client.resolveSeriesEpisode(
            seriesId: row.seriesId,
            season: season,
            episode: episode,
          );
          if (resolved == null) continue;
          results.add(ResolvedStream(
            url: resolved.url,
            filename:
                '${row.name} S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}',
            source: 'Xtream 📺 ${provider.name}',
            isCached: true,
            providerId: row.providerId,
            xtreamSeriesId: row.seriesId,
          ));
        } finally {
          client.dispose();
        }
      } catch (e) {
        _log.w('Series episode resolve failed for ${row.name}: $e');
      }
      if (results.length >= 5) break;
    }
    return results;
  }

  /// Normalize a Trakt/TMDB title for provider-catalog matching:
  /// lowercase, strip year/tags, collapse separators.
  String _normalizeXtreamTitle(String title) {
    var s = title.toLowerCase();
    s = s.replaceAll(RegExp(r'\(\d{4}\)'), ' '); // " (2021)"
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' '); // "[...]"
    s = s.replaceAll(RegExp(r'[._\-:]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// Pick a selective LIKE token (longest alphanumeric word ≥3 chars) so
  /// the DB scan stays narrow; final ranking happens in Dart.
  String _likeToken(String normalizedQuery) {
    final words = normalizedQuery
        .split(' ')
        .where((w) => RegExp(r'^[a-z0-9]+$').hasMatch(w) && w.length >= 3)
        .toList();
    if (words.isEmpty) return normalizedQuery;
    words.sort((a, b) => b.length.compareTo(a.length));
    return words.first;
  }

  /// Rank candidates by title + TMDB identity.
  ///
  /// A provider-linked TMDB id match is trusted outright (strongest signal).
  /// Otherwise a candidate must survive a similarity gate: exact normalized
  /// equality, query-as-prefix/suffix, or Dice similarity ≥ 0.5. This drops
  /// titles that merely contain the query as one word among many (e.g.
  /// "Moana" vs "SOC - Highlanders vs Moana Pasifika", similarity ~0.2).
  /// A known year boosts same-year hits and penalizes different-year ones.
  List<({String name, T value})> _rankByTitle<T>(
    List<({String name, String? tmdb, T value})> candidates,
    String normalizedQuery, {
    int? year,
    int? tmdbId,
  }) {
    final scored = <({String name, T value, double score})>[];
    for (final c in candidates) {
      final tmdbMatch = tmdbId != null &&
          c.tmdb != null &&
          int.tryParse(c.tmdb!.trim()) == tmdbId;
      final normalizedName = _normalizeXtreamTitle(c.name);
      if (!tmdbMatch) {
        // Prefilter: every query word must appear in the candidate.
        if (!fuzzyMatchPasses(normalizedQuery, [c.name])) continue;
        final exact = normalizedName == normalizedQuery;
        final affix = normalizedName.startsWith('$normalizedQuery ') ||
            normalizedName.endsWith(' $normalizedQuery');
        final similarity = StringSimilarity.compareTwoStrings(
          normalizedQuery,
          normalizedName,
        );
        if (!exact && !affix && similarity < 0.5) continue;
      }
      var score = fuzzyMatch(normalizedQuery, [c.name]);
      if (tmdbMatch) {
        score += 100;
      } else {
        if (normalizedName == normalizedQuery) score += 10;
        if (year != null) {
          if (c.name.contains('$year')) {
            score += 5;
          } else {
            final otherYear = _firstYearIn(c.name);
            if (otherYear != null && otherYear != year) score -= 8;
          }
        }
      }
      scored.add((name: c.name, value: c.value, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => (name: e.name, value: e.value)).toList();
  }

  /// First 4-digit year (1900–2029) in a raw provider title, if any.
  int? _firstYearIn(String text) {
    final match = RegExp(r'\b(19\d{2}|20[0-2]\d)\b').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Resolve a specific torrent via Real-Debrid (add magnet → wait → stream URL)
  Future<ResolvedStream?> resolveMagnet(
    String magnetUrl, {
    void Function(String status, int progress)? onProgress,
  }) async {
    if (_debrid == null) {
      throw Exception('No Real-Debrid API key configured');
    }
    return await _debrid.resolveFromMagnet(magnetUrl, onProgress: onProgress);
  }

  /// Enrich a list of VOD titles with TMDB poster/backdrop URLs
  Future<List<VodTitle>> _enrichWithTmdb(List<VodTitle> vodTitles) async {
    if (_tmdb == null) return vodTitles;

    final enriched = <VodTitle>[];
    for (final vodTitle in vodTitles) {
      enriched.add(await _enrichSingle(vodTitle));
    }
    return enriched;
  }

  /// Enrich seasons with TMDB posters/overviews
  Future<List<Season>> _enrichSeasons(int tmdbId, List<Season> seasons) async {
    if (_tmdb == null) return seasons;
    final result = <Season>[];
    for (final season in seasons) {
      try {
        final tmdbSeason = await _tmdb.getTvSeason(tmdbId, season.number);
        result.add(Season(
          number: season.number,
          title: season.title,
          overview: tmdbSeason.overview ?? season.overview,
          episodeCount: season.episodeCount,
          airedEpisodes: season.airedEpisodes,
          rating: season.rating,
          posterUrl: tmdbSeason.posterPath != null
              ? TmdbClient.posterUrl(tmdbSeason.posterPath)
              : null,
          firstAired: season.firstAired,
          traktId: season.traktId,
          tmdbId: season.tmdbId,
        ));
      } catch (_) {
        result.add(season);
      }
    }
    return result;
  }

  /// Enrich Trakt episodes with TMDB stills
  Future<List<Episode>> _enrichEpisodesWithTmdb(
      List<Episode> episodes, int tmdbId, int seasonNumber) async {
    if (_tmdb == null) return episodes;
    try {
      final tmdbSeason = await _tmdb.getTvSeason(tmdbId, seasonNumber);
      final tmdbEpMap = {for (final e in tmdbSeason.episodes) e.episodeNumber: e};
      return episodes.map((ep) {
        final tmdbEp = tmdbEpMap[ep.number];
        if (tmdbEp == null) return ep;
        return Episode(
          season: ep.season,
          number: ep.number,
          title: ep.title ?? tmdbEp.name,
          overview: ep.overview ?? tmdbEp.overview,
          rating: ep.rating,
          votes: ep.votes,
          runtime: ep.runtime,
          firstAired: ep.firstAired,
          stillUrl: tmdbEp.stillUrl.isNotEmpty ? tmdbEp.stillUrl : null,
          traktId: ep.traktId,
          tmdbId: ep.tmdbId,
        );
      }).toList();
    } catch (_) {
      return episodes;
    }
  }

  /// Enrich a single VOD title with TMDB images and IMDB ID
  Future<VodTitle> _enrichSingle(VodTitle vodTitle) async {
    if (_tmdb == null || vodTitle.tmdbId == null) return vodTitle;
    try {
      final detail = vodTitle.type == VodTitleType.movie
          ? await _tmdb.getMovie(vodTitle.tmdbId!)
          : await _tmdb.getTvShow(vodTitle.tmdbId!);
      return vodTitle.copyWith(
        imdbId: detail.imdbId,
        posterUrl: detail.posterUrl.isNotEmpty ? detail.posterUrl : null,
        backdropUrl: detail.backdropUrl.isNotEmpty ? detail.backdropUrl : null,
        overview: vodTitle.overview ?? detail.overview,
      );
    } catch (e) {
      _log.w('TMDB enrichment failed for ${vodTitle.title}: $e');
      return vodTitle;
    }
  }

  /// Convert TMDB search results to VodTitle objects (fallback when Trakt unavailable)
  List<VodTitle> _tmdbResultsToVodTitles(List<TmdbSearchResult> results, VodTitleType type) {
    return results.map((r) => VodTitle(
      traktId: r.id,
      tmdbId: r.id,
      title: r.displayName,
      year: r.year,
      overview: r.overview,
      rating: r.voteAverage,
      posterUrl: r.posterUrl.isNotEmpty ? r.posterUrl : null,
      backdropUrl: r.backdropUrl.isNotEmpty ? r.backdropUrl : null,
      type: type,
    )).toList();
  }
}
