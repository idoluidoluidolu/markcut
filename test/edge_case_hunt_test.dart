// 邊角獵捕：針對最近改動的高風險邏輯做對抗性測試——
// 草稿索引自癒、seeding 保護、模型對壞資料的行為。
// 每一條都是「使用者資料在最壞情況下會怎樣」的具體提問。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/preset_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String draftJson({String? savedAt, int clips = 2}) => jsonEncode({
    'savedAt': savedAt ?? DateTime.now().toIso8601String(),
    'clips': List.generate(clips, (i) => {'id': i}),
  });

  group('草稿索引自癒', () {
    test('索引整包壞掉：從內容鍵重建，兩份草稿都要列得出來', () async {
      SharedPreferences.setMockInitialValues({
        'projects_index_v1': '{{{{不是JSON',
        'project_data_a1': draftJson(savedAt: '2026-08-20T10:00:00'),
        'project_data_b2': draftJson(savedAt: '2026-08-21T11:00:00'),
      });
      final list = await DraftStore.list();
      expect(list.map((m) => m.id).toSet(), {'a1', 'b2'});
      // 新到舊
      expect(list.first.id, 'b2');
      // 壞掉的原字串要留備份
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('projects_index_backup'), '{{{{不是JSON');
    });

    test('索引不見了（鍵被清掉）：一樣從內容鍵重建', () async {
      SharedPreferences.setMockInitialValues({
        'project_data_x9': draftJson(),
      });
      final list = await DraftStore.list();
      expect(list.single.id, 'x9');
    });

    test('索引壞掉時 save()：舊草稿不能被擠掉', () async {
      SharedPreferences.setMockInitialValues({
        'projects_index_v1': 'garbage',
        'project_data_old1': draftJson(savedAt: '2026-08-19T09:00:00'),
      });
      final ok = await DraftStore.save('new2', draftJson());
      expect(ok, true);
      final list = await DraftStore.list();
      // 以前這一步會把索引重寫成「只有 new2」——old1 從此列不出來
      expect(list.map((m) => m.id).toSet(), {'old1', 'new2'});
    });

    test('內容鍵本身也壞：仍要列出來（讓使用者自己決定刪不刪）', () async {
      SharedPreferences.setMockInitialValues({
        'projects_index_v1': 'garbage',
        'project_data_bad': '也不是JSON',
        'project_data_good': draftJson(),
      });
      final list = await DraftStore.list();
      expect(list.map((m) => m.id).toSet(), {'bad', 'good'});
    });

    test('索引有一筆欄位型別錯：整包走重建，不會只剩半份清單', () async {
      SharedPreferences.setMockInitialValues({
        'projects_index_v1': jsonEncode([
          {'id': 'ok1', 'savedAt': '2026-08-21T10:00:00'},
          {'id': 'bad', 'savedAt': '2026-08-21T11:00:00', 'clips': 'abc'},
        ]),
        'project_data_ok1': draftJson(),
        'project_data_bad': draftJson(),
      });
      final list = await DraftStore.list();
      expect(list.map((m) => m.id).toSet(), {'ok1', 'bad'});
    });

    test('remove() 在索引壞掉時：刪目標、留其他', () async {
      SharedPreferences.setMockInitialValues({
        'projects_index_v1': 'garbage',
        'project_data_keep': draftJson(),
        'project_data_gone': draftJson(),
      });
      await DraftStore.remove('gone');
      final list = await DraftStore.list();
      expect(list.map((m) => m.id).toSet(), {'keep'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('project_data_gone'), isNull);
    });
  });

  group('範本 seeding 保護', () {
    test('清單裡有解不開的一筆：這一趟不回寫、旗標不立、原字串保留', () async {
      SharedPreferences.setMockInitialValues({
        'wm_presets_v1': <String>['這不是範本JSON'],
      });
      await PresetStore.ensureSeededV4();
      final prefs = await SharedPreferences.getInstance();
      // 壞的那筆還在（以前 read-modify-write 會把它無聲抹掉）
      expect(prefs.getStringList('wm_presets_v1'), ['這不是範本JSON']);
      // 旗標沒立＝下次還會再試
      expect(prefs.getBool('wm_presets_seeded_v4') ?? false, false);
    });

    test('清單乾淨：seeding 正常跑完、旗標立起', () async {
      SharedPreferences.setMockInitialValues({});
      await PresetStore.ensureSeededV4();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('wm_presets_seeded_v4'), true);
    });
  });

  group('模型對壞資料的行為（_loadDraft 容錯的前提）', () {
    test('MediaSource.fromJson 遇到型別錯會丟例外（載入端必須逐筆包）', () {
      expect(
        () => MediaSource.fromJson({'kind': 12345, 'path': 3}),
        throwsA(anything),
      );
    });

    test('TimelineClip.fromJson 缺欄位要能用預設補起來', () {
      final c = TimelineClip.fromJson({
        'id': 1,
        'sourceIndex': 0,
        'trimStart': 0.0,
        'trimEnd': 1.0,
        'offset': 0.0,
      });
      expect(c.track, 0);
      expect(c.reverse, false);
      expect(c.speed, 1.0);
    });

    test('videosAt 同軌多段照插入順序（排序去 O(n²) 後順序不能變）', () {
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(
          path: 'a',
          name: 'a',
          kind: ClipKind.video,
          duration: 10,
        ),
      );
      for (var i = 0; i < 5; i++) {
        tl.clips.add(
          TimelineClip(
            id: i,
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 2,
            // 全部蓋住 t=1，各在不同插入順序
            offset: 0,
            track: i.isEven ? 0 : 2,
          ),
        );
      }
      final got = tl.videosAt(1.0);
      // 先 track 小 → 大；同 track 照 clips 裡的先後
      expect(got.map((c) => c.id).toList(), [0, 2, 4, 1, 3]);
    });
  });
}
