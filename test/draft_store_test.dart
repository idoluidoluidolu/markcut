import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('多草稿', () {
    test('存兩份互不覆蓋，清單新到舊', () async {
      await DraftStore.save('a', '{"clips":[1]}');
      await DraftStore.save('b', '{"clips":[1,2]}');
      final list = await DraftStore.list();
      expect(list.length, 2);
      expect(list.first.id, 'b');
      expect(await DraftStore.load('a'), isNotNull);
      expect(await DraftStore.load('b'), isNotNull);
    });

    test('同一個 id 再存是更新，不會變兩筆', () async {
      await DraftStore.save('a', '{"clips":[1]}');
      await DraftStore.save('a', '{"clips":[1,2]}');
      final list = await DraftStore.list();
      expect(list.length, 1);
      expect((await DraftStore.load('a'))!['clips'], [1, 2]);
    });

    test('建立時間只記一次，之後每次存都留著同一個', () async {
      await DraftStore.save('a', '{}');
      final first = (await DraftStore.list()).single.createdAt;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await DraftStore.save('a', '{"clips":[1]}');
      final m = (await DraftStore.list()).single;
      expect(m.createdAt, first);
      // 存檔時間則會往前走
      expect(m.savedAt.isBefore(first), isFalse);
    });

    test('刪除只刪那一份，內容也一起清掉', () async {
      await DraftStore.save('a', '{}');
      await DraftStore.save('b', '{}');
      await DraftStore.remove('a');
      final list = await DraftStore.list();
      expect(list.length, 1);
      expect(list.single.id, 'b');
      expect(await DraftStore.load('a'), isNull);
    });

    test('每次產生的 id 都不一樣', () {
      final ids = {for (var i = 0; i < 50; i++) DraftStore.newId()};
      expect(ids.length, greaterThan(1));
    });

    test('清單只讀索引，封面另外存', () async {
      await DraftStore.save(
        'a',
        '{"clips":[1,2,3]}',
        clipCount: 3,
        thumb: 'AAA',
      );
      final m = (await DraftStore.list()).single;
      expect(m.clipCount, 3);
      expect(m.hasThumb, isTrue);
      expect(await DraftStore.thumb('a'), 'AAA');
    });
  });

  group('舊版單一草稿搬家', () {
    test('舊草稿變成清單裡的第一筆，舊鍵清掉', () async {
      SharedPreferences.setMockInitialValues({
        'project_draft_v1': jsonEncode({
          'clips': [
            {'id': 1},
          ],
          'savedAt': '2026-01-02T03:04:05.000',
          'thumb': 'ZZZ',
        }),
      });
      final list = await DraftStore.list();
      expect(list.length, 1);
      expect(list.single.clipCount, 1);
      expect(list.single.hasThumb, isTrue);
      expect(await DraftStore.thumb(list.single.id), 'ZZZ');
      // 舊資料沒有建立時間，退回存檔時間
      expect(list.single.createdAt, DateTime.parse('2026-01-02T03:04:05.000'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('project_draft_v1'), isNull);
      expect(await DraftStore.load(list.single.id), isNotNull);
    });
  });

  group('草稿上限與自動清理', () {
    /// 索引直接種：savedAt 決定新舊，不用靠 sleep 拉開時間
    Map<String, Object> seeded(
      Map<String, String> savedAtById, {
      Map<String, String> data = const {},
    }) => {
      'projects_index_v1': jsonEncode([
        for (final e in savedAtById.entries)
          {'id': e.key, 'savedAt': e.value},
      ]),
      for (final e in savedAtById.entries)
        'project_data_${e.key}':
            data[e.key] ??
            jsonEncode({
              'savedAt': e.value,
              'clips': [1],
            }),
      for (final e in savedAtById.entries) 'project_thumb_${e.key}': 'T',
    };

    String withFiles(List<String> files) => jsonEncode({
      'savedAt': '2026-01-01T00:00:00',
      'sources': [
        for (final f in files) {'path': f, 'workPath': '$f.work'},
      ],
      'clips': [1],
    });

    late List<Set<String>> released;
    bool Function(String)? lastReferenced;
    setUp(() {
      released = [];
      lastReferenced = null;
      DraftStore.fileReleaser = (paths, {required referenced}) async {
        released.add(paths);
        lastReferenced = referenced;
        return paths.length;
      };
    });
    tearDown(() => DraftStore.fileReleaser = DraftStore.defaultFileReleaser);

    test('預設 30；設定會存起來，超出範圍夾回來', () async {
      expect(await DraftStore.maxDrafts(), 30);
      await DraftStore.setMaxDrafts(50);
      expect(await DraftStore.maxDrafts(), 50);
      await DraftStore.setMaxDrafts(0);
      expect(await DraftStore.maxDrafts(), DraftStore.minMax);
      await DraftStore.setMaxDrafts(99999);
      expect(await DraftStore.maxDrafts(), DraftStore.maxMax);
    });

    test('存草稿超過上限：最舊的被刪（內容、封面都清），剛存的留著', () async {
      SharedPreferences.setMockInitialValues(
        seeded({'old': '2026-01-01T00:00:00', 'mid': '2026-01-02T00:00:00'}),
      );
      await DraftStore.setMaxDrafts(2);
      expect(await DraftStore.save('new', '{"clips":[1]}'), isTrue);
      expect((await DraftStore.list()).map((m) => m.id), ['new', 'mid']);
      expect(await DraftStore.load('old'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('project_thumb_old'), isNull);
      expect(prefs.getString('project_data_mid'), isNotNull);
    });

    test('上限 1：剛存的那份永遠不會被自己觸發的清理刪掉', () async {
      SharedPreferences.setMockInitialValues(
        seeded({'a': '2026-01-01T00:00:00', 'b': '2026-01-02T00:00:00'}),
      );
      await DraftStore.setMaxDrafts(1);
      await DraftStore.save('c', '{"clips":[1]}');
      expect((await DraftStore.list()).map((m) => m.id), ['c']);
    });

    test('沒超過上限：什麼都不動', () async {
      SharedPreferences.setMockInitialValues(
        seeded({'a': '2026-01-01T00:00:00', 'b': '2026-01-02T00:00:00'}),
      );
      await DraftStore.setMaxDrafts(3);
      expect(await DraftStore.prune(), isEmpty);
      expect((await DraftStore.list()).length, 2);
      expect(released, isEmpty);
    });

    test('啟動清理（沒有 keep）：超過的最舊幾份全清、順序照存檔時間', () async {
      SharedPreferences.setMockInitialValues(
        seeded({
          'd1': '2026-01-01T00:00:00',
          'd3': '2026-01-03T00:00:00',
          'd2': '2026-01-02T00:00:00',
          'd4': '2026-01-04T00:00:00',
        }),
      );
      await DraftStore.setMaxDrafts(2);
      expect((await DraftStore.prune()).toSet(), {'d1', 'd2'});
      expect((await DraftStore.list()).map((m) => m.id), ['d4', 'd3']);
    });

    test('正在編輯中的草稿就算最舊也不刪，改刪下一個', () async {
      SharedPreferences.setMockInitialValues(
        seeded({
          'old': '2026-01-01T00:00:00',
          'mid': '2026-01-02T00:00:00',
          'new': '2026-01-03T00:00:00',
        }),
      );
      await DraftStore.setMaxDrafts(2);
      DraftStore.holdOpen('old');
      try {
        expect(await DraftStore.prune(), ['mid']);
        expect((await DraftStore.list()).map((m) => m.id).toSet(), {
          'new',
          'old',
        });
      } finally {
        DraftStore.releaseOpen('old');
      }
    });

    test('全部都受保護：寧可超過上限也一份都不刪', () async {
      SharedPreferences.setMockInitialValues(
        seeded({'a': '2026-01-01T00:00:00', 'b': '2026-01-02T00:00:00'}),
      );
      await DraftStore.setMaxDrafts(1);
      DraftStore.holdOpen('a');
      try {
        expect(await DraftStore.prune(keep: {'b'}), isEmpty);
        expect((await DraftStore.list()).length, 2);
      } finally {
        DraftStore.releaseOpen('a');
      }
    });

    test('清掉的草稿的檔案：只有它在用的交給清理，別份還在用的不碰', () async {
      SharedPreferences.setMockInitialValues(
        seeded(
          {'old': '2026-01-01T00:00:00', 'keep': '2026-01-02T00:00:00'},
          data: {
            'old': withFiles(['/w/only.mp4', '/w/shared.mp4']),
            'keep': withFiles(['/w/shared.mp4']),
          },
        ),
      );
      await DraftStore.setMaxDrafts(1);
      expect(await DraftStore.prune(), ['old']);
      expect(released.single, {'/w/only.mp4', '/w/only.mp4.work'});
      // 清理那頭還會再問一次「工作檔的原檔有沒有人用」
      expect(lastReferenced!('/w/shared.mp4'), isTrue);
      expect(lastReferenced!('/w/only.mp4'), isFalse);
      // 只認檔名也算有人用（App 更新後容器路徑的 UUID 會換）
      expect(lastReferenced!('/other/prefix/shared.mp4'), isTrue);
    });

    test('內容壞掉的草稿也清得掉，不會卡住整輪清理', () async {
      SharedPreferences.setMockInitialValues(
        seeded(
          {'old': '2026-01-01T00:00:00', 'keep': '2026-01-02T00:00:00'},
          data: {'old': '不是JSON'},
        ),
      );
      await DraftStore.setMaxDrafts(1);
      expect(await DraftStore.prune(), ['old']);
      expect((await DraftStore.list()).map((m) => m.id), ['keep']);
      expect(released, isEmpty);
    });

    test('存檔跟清理同時跑：排隊做，剛存的不會被清掉', () async {
      SharedPreferences.setMockInitialValues(
        seeded({'old': '2026-01-01T00:00:00', 'mid': '2026-01-02T00:00:00'}),
      );
      await DraftStore.setMaxDrafts(2);
      await Future.wait<void>([
        DraftStore.save('new', '{"clips":[1]}'),
        DraftStore.prune(),
        DraftStore.save('new', '{"clips":[1,2]}'),
      ]);
      expect((await DraftStore.list()).map((m) => m.id), ['new', 'mid']);
      expect((await DraftStore.load('new'))!['clips'], [1, 2]);
    });
  });
}
