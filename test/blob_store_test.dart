// 大資料搬出 SharedPreferences（BUILD 218：iOS 開 App 就把整個設定檔讀進
// 記憶體，Flutter 又整包複製一份到 Dart——上百份草稿各帶一份 Logo 的
// base64，實機剛開 App 就 1.4GB，開 App 一兩秒衝到 2.9GB）。這裡釘住：
//   1. 檔案讀寫刪、列鍵名
//   2. 舊資料自動搬：寫成功才從 prefs 刪，不相干的設定不動
//   3. 寫不進去的留在 prefs，讀的時候照樣拿得到
//   4. 草稿整條路（存、讀、清單、封面、刪）走檔案；舊版存在 prefs 的草稿照樣讀得到
//   5. 沒有檔案系統（web、單元測試沒掛 path_provider）照舊用 prefs
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/preset_store.dart';
import 'package:markcut/services/sticker_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  File blob(String key) =>
      File('${dir.path}${Platform.pathSeparator}blobs${Platform.pathSeparator}$key.txt');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('markcut_blobs_');
    BlobStore.dirOverride = dir;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    BlobStore.dirOverride = null;
    BlobStore.resetForTest();
    dir.deleteSync(recursive: true);
  });

  test('讀寫刪、列鍵名都走檔案，prefs 裡什麼都不留', () async {
    expect(await BlobStore.read('project_data_a'), isNull);
    expect(await BlobStore.write('project_data_a', '{"x":1}'), isTrue);
    expect(await BlobStore.write('project_data_b', 'b'), isTrue);
    expect(await BlobStore.write('project_thumb_a', 't'), isTrue);
    expect(await BlobStore.read('project_data_a'), '{"x":1}');
    expect(blob('project_data_a').readAsStringSync(), '{"x":1}');
    expect(await BlobStore.exists('project_thumb_a'), isTrue);
    expect(
      (await BlobStore.keysWithPrefix('project_data_'))..sort(),
      ['project_data_a', 'project_data_b'],
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty, reason: '大資料不能再進設定檔');

    expect(await BlobStore.delete('project_data_a'), isTrue);
    expect(await BlobStore.read('project_data_a'), isNull);
    expect(await BlobStore.exists('project_data_a'), isFalse);
    expect(
      Directory('${dir.path}${Platform.pathSeparator}blobs')
          .listSync()
          .where((e) => e.path.endsWith('.tmp')),
      isEmpty,
      reason: '暫存檔要換名成正式檔',
    );
  });

  test('舊資料自動搬：寫成功才從 prefs 刪，清單照原樣，不相干的設定不動', () async {
    SharedPreferences.setMockInitialValues({
      'project_data_old': '{"clips":[1]}',
      'project_thumb_old': 'dGh1bWI=',
      'wm_presets_v1': ['{"name":"A"}', '{"name":"B"}'],
      'stickers_v1': ['c3RpY2tlcg=='],
      'projects_index_v1': '[]',
      'wm_presets_seeded_v1': true,
    });
    await BlobStore.migrate();
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys(),
      {'projects_index_v1', 'wm_presets_seeded_v1'},
      reason: '索引與旗標很小，留在 prefs',
    );
    expect(blob('project_data_old').readAsStringSync(), '{"clips":[1]}');
    expect(await BlobStore.read('project_thumb_old'), 'dGh1bWI=');
    expect(await BlobStore.readList('wm_presets_v1'), [
      '{"name":"A"}',
      '{"name":"B"}',
    ]);
    expect(await BlobStore.readList('stickers_v1'), ['c3RpY2tlcg==']);
  });

  test('寫不進去的留在 prefs，讀的時候照樣拿得到', () async {
    SharedPreferences.setMockInitialValues({'project_data_stuck': 'keep me'});
    // 正式檔的位置被一個資料夾佔住：換名一定失敗
    Directory(
      '${dir.path}${Platform.pathSeparator}blobs${Platform.pathSeparator}'
      'project_data_stuck.txt.tmp',
    ).createSync(recursive: true);
    await BlobStore.migrate();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('project_data_stuck'), 'keep me');
    expect(await BlobStore.read('project_data_stuck'), 'keep me');
  });

  test('草稿整條路走檔案；舊版存在 prefs 的草稿照樣讀得到', () async {
    SharedPreferences.setMockInitialValues({
      'project_data_legacy': jsonEncode({
        'clips': [1, 2],
        'savedAt': '2026-09-01T00:00:00.000',
      }),
      'project_thumb_legacy': 'bGVnYWN5',
      'projects_index_v1': jsonEncode([
        {'id': 'legacy', 'savedAt': '2026-09-01T00:00:00.000', 'hasThumb': true, 'clips': 2},
      ]),
    });
    expect((await DraftStore.load('legacy'))?['clips'], [1, 2]);
    expect(await DraftStore.thumb('legacy'), 'bGVnYWN5');

    final id = DraftStore.newId();
    expect(
      await DraftStore.save(id, '{"clips":[1],"savedAt":"2026-09-23T00:00:00.000"}',
          thumb: 'bmV3', clipCount: 1),
      isTrue,
    );
    expect((await DraftStore.load(id))?['clips'], [1]);
    expect(await DraftStore.thumb(id), 'bmV3');
    expect((await DraftStore.list()).map((m) => m.id), containsAll([id, 'legacy']));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where(BlobStore.owns),
      isEmpty,
      reason: '內容與封面都在檔案裡',
    );

    await DraftStore.remove(id);
    expect(await DraftStore.load(id), isNull);
    expect(await DraftStore.thumb(id), isNull);
    expect((await DraftStore.list()).map((m) => m.id), ['legacy']);
  });

  test('範本與貼圖存成檔案', () async {
    await PresetStore.ensureSeeded();
    expect((await PresetStore.load()).map((p) => p.name), ['頻道標準']);
    await StickerStore.add(Uint8List.fromList([1, 2, 3]));
    expect(await StickerStore.load(), [
      [1, 2, 3],
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('wm_presets_v1'), isFalse);
    expect(prefs.containsKey('stickers_v1'), isFalse);
    expect(blob('wm_presets_v1').existsSync(), isTrue);
    expect(blob('stickers_v1').existsSync(), isTrue);
  });

  test('沒有檔案系統：照舊用 prefs', () async {
    BlobStore.dirOverride = null;
    BlobStore.resetForTest(); // 單元測試沒掛 path_provider＝拿不到目錄
    expect(await BlobStore.write('project_data_web', 'w'), isTrue);
    expect(await BlobStore.writeList('stickers_v1', ['s']), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('project_data_web'), 'w');
    expect(prefs.getStringList('stickers_v1'), ['s']);
    expect(await BlobStore.read('project_data_web'), 'w');
    expect(await BlobStore.readList('stickers_v1'), ['s']);
  });
}
