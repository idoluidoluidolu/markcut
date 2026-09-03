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
        for (final e in savedAtById.entries) {'id': e.key, 'savedAt': e.value},
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

    /// 種 [n] 份草稿：d0 最舊、d{n-1} 最新。
    /// 上限固定 30（DraftStore.maxDrafts），要看到清理就得先超過它
    Map<String, Object> manyDrafts(
      int n, {
      Map<String, String> data = const {},
    }) => seeded({
      for (var i = 0; i < n; i++)
        'd$i': DateTime(2026, 1, 1).add(Duration(days: i)).toIso8601String(),
    }, data: data);

    const cap = DraftStore.maxDrafts;

    test('上限是固定的 30，沒有設定可以調', () {
      expect(cap, 30);
    });

    test('舊裝置上調過的「保留份數」不再算數，而且那個鍵會被刪掉', () async {
      // 上限還能調的時候有人把它設成 5：現在一律回到 30
      SharedPreferences.setMockInitialValues({
        'drafts_max_v1': 5,
        ...manyDrafts(cap),
      });
      // list() 會順手做搬家／清鍵
      expect((await DraftStore.list()).length, cap);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('drafts_max_v1'), isNull, reason: '舊設定要被刪掉');
      // 30 份沒有超過上限＝一份都不清（要是還讀那個 5 就會刪掉 25 份）
      expect(await DraftStore.prune(), isEmpty);
      expect((await DraftStore.list()).length, cap);
    });

    test('清理超過上限：最舊的被刪（內容、封面都清），剛存的留著', () async {
      SharedPreferences.setMockInitialValues(manyDrafts(cap));
      expect(await DraftStore.save('new', '{"clips":[1]}'), isTrue);
      // 存檔本身不清理（掃描太貴，見 DraftStore.save）：清理是按掃把才做
      expect((await DraftStore.list()).length, cap + 1);
      expect(await DraftStore.prune(keep: {'new'}), ['d0']);
      final ids = (await DraftStore.list()).map((m) => m.id).toList();
      expect(ids.length, cap);
      expect(ids.first, 'new');
      expect(ids, isNot(contains('d0')));
      expect(await DraftStore.load('d0'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('project_thumb_d0'), isNull);
      expect(prefs.getString('project_data_d1'), isNotNull);
    });

    test('剛存的那份永遠不會被清理刪掉（就算它最舊）', () async {
      // 全部種在未來，剛存的那份反而是最舊的一筆
      SharedPreferences.setMockInitialValues(
        seeded({
          for (var i = 0; i < cap; i++)
            'f$i': DateTime(
              2030,
              1,
              1,
            ).add(Duration(days: i)).toIso8601String(),
        }),
      );
      await DraftStore.save('c', '{"clips":[1]}');
      expect(await DraftStore.prune(keep: {'c'}), ['f0']);
      expect((await DraftStore.list()).map((m) => m.id), contains('c'));
    });

    test('沒超過上限：什麼都不動', () async {
      SharedPreferences.setMockInitialValues(manyDrafts(cap));
      expect(await DraftStore.prune(), isEmpty);
      expect((await DraftStore.list()).length, cap);
    });

    test('清理（沒有 keep）：超過的最舊幾份全清、順序照存檔時間', () async {
      SharedPreferences.setMockInitialValues(manyDrafts(cap + 2));
      expect((await DraftStore.prune()).toSet(), {'d0', 'd1'});
      final ids = (await DraftStore.list()).map((m) => m.id).toList();
      expect(ids.length, cap);
      expect(ids.first, 'd${cap + 1}'); // 最新的排最前面
      expect(ids.last, 'd2');
    });

    test('正在編輯中的草稿就算最舊也不刪，改刪下一個', () async {
      SharedPreferences.setMockInitialValues(manyDrafts(cap + 1));
      DraftStore.holdOpen('d0');
      try {
        expect(await DraftStore.prune(), ['d1']);
        expect((await DraftStore.list()).map((m) => m.id), contains('d0'));
      } finally {
        DraftStore.releaseOpen('d0');
      }
    });

    test('全部都受保護：寧可超過上限也一份都不刪', () async {
      SharedPreferences.setMockInitialValues(manyDrafts(cap + 1));
      DraftStore.holdOpen('d0');
      try {
        final rest = {for (var i = 1; i <= cap; i++) 'd$i'};
        expect(await DraftStore.prune(keep: rest), isEmpty);
        expect((await DraftStore.list()).length, cap + 1);
      } finally {
        DraftStore.releaseOpen('d0');
      }
    });

    test('內容壞掉的草稿也清得掉，不會卡住整輪清理', () async {
      SharedPreferences.setMockInitialValues(
        manyDrafts(cap + 1, data: {'d0': '不是JSON'}),
      );
      expect(await DraftStore.prune(), ['d0']);
      expect((await DraftStore.list()).length, cap);
    });

    test('存檔跟清理同時跑：排隊做，剛存的不會被清掉', () async {
      SharedPreferences.setMockInitialValues(manyDrafts(cap));
      await Future.wait<void>([
        DraftStore.save('new', '{"clips":[1]}'),
        DraftStore.prune(),
        DraftStore.save('new', '{"clips":[1,2]}'),
      ]);
      final ids = (await DraftStore.list()).map((m) => m.id).toList();
      expect(ids.length, cap);
      expect(ids, contains('new'));
      expect((await DraftStore.load('new'))!['clips'], [1, 2]);
    });
  });
}
