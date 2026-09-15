import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/remote/xtream_client.dart';
import 'package:clubtivi/data/models/vod_title.dart';
import 'package:clubtivi/data/models/vod_item.dart';
import 'package:clubtivi/data/repositories/vod_repository.dart';

void main() {
  group('VodItem Xtream factories', () {
    test('fromXtreamVod builds movie URL and parses metadata', () {
      final item = VodItem.fromXtreamVod(
        json: {
          'stream_id': 123,
          'name': 'Dune (2021)',
          'container_extension': 'mkv',
          'stream_icon': 'http://img/poster.jpg',
          'category_id': '7',
          'category_name': 'Movies',
          'rating': '8.5',
          'rating_5based': 4.2,
          'tmdb': '438631',
          'plot': 'Desert epic',
        },
        providerId: 'p1',
        baseUrl: 'http://line.tv:8080',
        username: 'u',
        password: 'p',
      );

      expect(item.id, 'p1_vod_123');
      expect(item.type, VodType.movie);
      expect(item.streamUrl, 'http://line.tv:8080/movie/u/p/123.mkv');
      expect(item.categoryId, '7');
      expect(item.rating, 8.5);
      expect(item.rating5based, 4.2);
      expect(item.tmdb, '438631');
      expect(item.plot, 'Desert epic');
    });

    test('fromXtreamSeries parses cover and has no stream URL', () {
      final item = VodItem.fromXtreamSeries(
        json: {
          'series_id': 42,
          'name': 'Breaking Bad',
          'cover': 'http://img/cover.jpg',
          'category_id': '3',
          'youtube_trailer': 'abc123',
          'rating_5based': '9.50',
        },
        providerId: 'p1',
      );

      expect(item.id, 'p1_series_42');
      expect(item.type, VodType.series);
      expect(item.isSeries, isTrue);
      expect(item.streamUrl, isNull);
      expect(item.posterUrl, 'http://img/cover.jpg');
      expect(item.trailer, 'abc123');
    });
  });

  group('XtreamSeriesInfo', () {
    Map<String, dynamic> sampleJson() => {
          'info': {'name': 'Breaking Bad'},
          'seasons': [
            {'name': 'Season 1', 'season_number': 1, 'episode_count': 2},
          ],
          'episodes': {
            '1': [
              {
                'id': 1001,
                'episode_num': 1,
                'season': 1,
                'title': 'Pilot',
                'container_extension': 'mp4',
              },
              {
                'id': 1002,
                'episode_num': 2,
                'season': 1,
                'title': "Cat's in the Bag",
                'container_extension': 'mkv',
              },
            ],
          },
        };

    test('parses seasons and episodes keyed by season number', () {
      final info = XtreamSeriesInfo.fromJson(sampleJson());
      expect(info.name, 'Breaking Bad');
      expect(info.seasons, hasLength(1));
      expect(info.seasons.first.seasonNumber, 1);
      expect(info.episodesBySeason[1], hasLength(2));
    });

    test('findEpisode locates the right episode id and extension', () {
      final info = XtreamSeriesInfo.fromJson(sampleJson());
      final ep = info.findEpisode(1, 2);
      expect(ep, isNotNull);
      expect(ep!.id, 1002);
      expect(ep.containerExtension, 'mkv');
      expect(info.findEpisode(1, 99), isNull);
      expect(info.findEpisode(9, 1), isNull);
    });
  });

  group('Xtream VOD/Series tables', () {
    late db.AppDatabase database;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p1',
              name: 'Test Provider',
              type: 'xtream',
            ),
          );
    });

    tearDownAll(() async {
      await database.close();
    });

    test('upsert + case-insensitive VOD search', () async {
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Dune Part Two (2024)',
          streamUrl: 'http://line.tv/movie/u/p/1.mp4',
          rating: const Value(8.6),
        ),
      ]);

      final hits = await database.searchXtreamVod('dune part');
      expect(hits, hasLength(1));
      expect(hits.first.streamId, 1);
      expect(hits.first.rating, 8.6);

      expect(await database.searchXtreamVod('nonexistent'), isEmpty);
    });

    test('upsert on conflict updates existing VOD row', () async {
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Dune Part Two (2024) Remastered',
          streamUrl: 'http://line.tv/movie/u/p/1.mp4',
        ),
      ]);

      final hits = await database.searchXtreamVod('dune part');
      expect(hits, hasLength(1));
      expect(hits.first.name, contains('Remastered'));
    });

    test('upsert + search + delete series rows', () async {
      await database.upsertXtreamSeries([
        db.XtreamSeriesCompanion.insert(
          id: 'p1_series_42',
          providerId: 'p1',
          seriesId: 42,
          name: 'Breaking Bad',
          cover: const Value('http://img/cover.jpg'),
        ),
      ]);

      final hits = await database.searchXtreamSeries('breaking');
      expect(hits, hasLength(1));
      expect(hits.first.seriesId, 42);

      await database.deleteXtreamSeriesForProvider('p1');
      expect(await database.getAllXtreamSeries(), isEmpty);

      // VOD rows for other providers are untouched by series delete
      expect(await database.getAllXtreamVod(), hasLength(1));
      await database.deleteXtreamVodForProvider('p1');
      expect(await database.getAllXtreamVod(), isEmpty);
    });
  });

  group('Xtream title matching', () {
    late db.AppDatabase database;
    late VodRepository repo;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p2',
              name: 'Sports + Movies',
              type: 'xtream',
            ),
          );
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p2_vod_10',
          providerId: 'p2',
          streamId: 10,
          name: 'Moana (2016)',
          streamUrl: 'http://line.tv/movie/u/p/10.mp4',
          tmdb: const Value('277834'),
        ),
        db.XtreamVodCompanion.insert(
          id: 'p2_vod_11',
          providerId: 'p2',
          streamId: 11,
          name: 'SOC - Highlanders vs Moana Pasifika',
          streamUrl: 'http://line.tv/movie/u/p/11.mp4',
        ),
        db.XtreamVodCompanion.insert(
          id: 'p2_vod_12',
          providerId: 'p2',
          streamId: 12,
          name: 'Moana 2 (2024)',
          streamUrl: 'http://line.tv/movie/u/p/12.mp4',
          tmdb: const Value('1241982'),
        ),
      ]);
      repo = VodRepository(database: database);
    });

    tearDownAll(() async {
      await database.close();
    });

    test('partial-word sports hit is excluded without TMDB id', () async {
      final results = await repo.findXtreamStreams(
        title: 'Moana',
        year: 2016,
        mediaType: VodTitleType.movie,
      );
      final names = results.map((r) => r.filename).toList();
      expect(names, contains('Moana (2016)'));
      expect(
        names.where((n) => n.contains('Highlanders')),
        isEmpty,
        reason: 'Rugby match merely mentions Moana: $names',
      );
    });

    test('exact title ranks above sequel for the same query', () async {
      final results = await repo.findXtreamStreams(
        title: 'Moana',
        year: 2016,
        mediaType: VodTitleType.movie,
      );
      expect(results.first.filename, 'Moana (2016)');
    });

    test('provider TMDB id match wins outright', () async {
      final results = await repo.findXtreamStreams(
        title: 'Moana',
        year: 2016,
        tmdbId: 277834,
        mediaType: VodTitleType.movie,
      );
      expect(results.first.filename, 'Moana (2016)');
      expect(
        results.map((r) => r.filename),
        isNot(contains('SOC - Highlanders vs Moana Pasifika')),
      );
    });
  });
}
