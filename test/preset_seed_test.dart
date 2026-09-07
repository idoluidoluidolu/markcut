// 預設範本補種（PresetStore.ensureSeeded → V2 → V3 → V4）的兩道保險：
//
//   1. 全新安裝只該寫一次。以前是 V1 種一筆 → V2 加三筆 → V3 刪三加四 →
//      V4 刪七，四次整包回寫才回到一筆——V1 種下去的本來就是 V4 的
//      最終狀態，後面三批是給「已經有舊範本」的人做搬遷用的，
//      新裝置跑它們純粹是白寫三次 SharedPreferences
//   2. V2 跟 V3／V4 一樣，底層有任何一筆解不開就不回寫。補種是
//      read-modify-write：load() 對壞資料是「略過」，略過再整包回寫
//      ＝那筆範本被永久抹掉且無從察覺
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/preset_store.dart';

const _flags = [
  'wm_presets_seeded_v2',
  'wm_presets_seeded_v3',
  'wm_presets_seeded_v4',
];

Future<List<String>> _names() async => [
  for (final p in await PresetStore.load()) p.name,
];

void main() {
  test('全新安裝：ensureSeeded 一次到位，V2～V4 不再各自回寫', () async {
    SharedPreferences.setMockInitialValues({});
    await PresetStore.ensureSeeded();

    final prefs = await SharedPreferences.getInstance();
    for (final k in _flags) {
      expect(prefs.getBool(k), isTrue, reason: '$k 沒立旗標，那一批之後還會再讀寫一輪');
    }
    expect(await _names(), ['頻道標準']);

    // 整條鏈再跑一次：什麼都不該變
    await PresetStore.ensureSeededV2();
    await PresetStore.ensureSeededV3();
    await PresetStore.ensureSeededV4();
    expect(await _names(), ['頻道標準']);
  });

  test('舊使用者（有範本、沒旗標）：V2～V4 照舊搬遷，最後只剩自己的範本', () async {
    final mine = WatermarkPreset(
      name: '我的',
      settings: WatermarkSettings()..text.text = '@me',
    ).encode();
    SharedPreferences.setMockInitialValues({
      'wm_presets_v1': [mine],
    });
    await PresetStore.ensureSeeded();
    await PresetStore.ensureSeededV2();
    await PresetStore.ensureSeededV3();
    await PresetStore.ensureSeededV4();
    expect(await _names(), ['我的']);
  });

  test('V2 補種：底層有壞掉的一筆就不回寫（跟 V3／V4 同一道保險）', () async {
    final good = WatermarkPreset(
      name: '我的',
      settings: WatermarkSettings()..text.text = '@me',
    ).encode();
    SharedPreferences.setMockInitialValues({
      'wm_presets_seeded_v1': true,
      'wm_presets_v1': [good, '{壞掉的'],
    });
    await PresetStore.ensureSeededV2();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('wm_presets_v1'), [
      good,
      '{壞掉的',
    ], reason: '壞掉的那筆被整包回寫抹掉了');
    expect(
      prefs.getBool('wm_presets_seeded_v2'),
      isNot(isTrue),
      reason: '沒寫成功不該立旗標（下次還要再試）',
    );
  });
}
