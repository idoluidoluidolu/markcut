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
}
