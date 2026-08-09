import 'package:shared_preferences/shared_preferences.dart';

import '../models/watermark_settings.dart';

/// 浮水印範本的儲存與讀取（存在本機，App 重開仍在）
class PresetStore {
  static const _key = 'wm_presets_v1';
  static const _seededKey = 'wm_presets_seeded_v1';

  /// 第一次使用時放幾個示範範本（使用者存過東西就不動）
  static Future<void> ensureSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seededKey) ?? false) return;
    if ((prefs.getStringList(_key) ?? []).isNotEmpty) {
      await prefs.setBool(_seededKey, true);
      return;
    }

    // 只種一筆基本款，其餘樣式範本由 ensureSeededV2/V3 補
    final demos = [
      WatermarkPreset(
        name: '頻道標準',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 0.85,
            sizeFrac: 0.045,
            x: 0.86,
            y: 0.9,
          ),
        ),
      ),
    ];
    await prefs.setStringList(
        _key, demos.map((p) => p.encode()).toList());
    // 旗標最後才立：寫到一半被殺掉的話下次還會重種
    await prefs.setBool(_seededKey, true);
  }

  /// v2 追加的基本樣式（舊使用者也補種，不覆蓋同名）
  static Future<void> ensureSeededV2() async {
    final prefs = await SharedPreferences.getInstance();
    const k2 = 'wm_presets_seeded_v2';
    if (prefs.getBool(k2) ?? false) return;

    final extra = [
      WatermarkPreset(
        name: '大字滿版',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 0.2,
            sizeFrac: 0.13,
            x: 0.5,
            y: 0.5,
            rotation: -18,
            shadow: false,
          ),
        ),
      ),
      WatermarkPreset(
        name: '棋盤格',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 0.15,
            sizeFrac: 0.045,
            rotation: -30,
            tiled: true,
            shadow: false,
          ),
        ),
      ),
      WatermarkPreset(
        name: '底部橫幅',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 0.95,
            sizeFrac: 0.032,
            x: 0.5,
            y: 0.96,
            shadow: false,
            bg: true,
            bgColorValue: 0xFF000000,
            bgOpacity: 0.55,
            bgPad: 1.5,
            bgCorner: 0.2,
          ),
        ),
      ),
    ];

    final cur = await load();
    final names = cur.map((p) => p.name).toSet();
    var changed = false;
    for (final p in extra) {
      if (!names.contains(p.name)) {
        cur.add(p);
        changed = true;
      }
    }
    if (changed) await saveAll(cur);
    await prefs.setBool(k2, true); // 資料寫完才立旗標
  }

  /// v3：內建範本全面改「樣式」導向——移除純字體變化的示範
  /// （粉圓手感/宋體雅致）與重複的滿版防盜，補上樣式範本
  static Future<void> ensureSeededV3() async {
    final prefs = await SharedPreferences.getInstance();
    const k3 = 'wm_presets_seeded_v3';
    if (prefs.getBool(k3) ?? false) return;

    const removals = {'粉圓手感', '宋體雅致', '滿版防盜'};
    final extra = [
      WatermarkPreset(
        name: '描邊標題',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 1,
            sizeFrac: 0.055,
            x: 0.16,
            y: 0.9,
            shadow: false,
            outline: true,
            outlineColorValue: 0xFF000000,
            outlineWidth: 0.09,
          ),
        ),
      ),
      WatermarkPreset(
        name: '膠囊標籤',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 0.95,
            sizeFrac: 0.03,
            x: 0.85,
            y: 0.93,
            shadow: false,
            bg: true,
            bgColorValue: 0xFF000000,
            bgOpacity: 0.5,
            bgPad: 1.6,
            bgCorner: 1,
          ),
        ),
      ),
      WatermarkPreset(
        name: '手寫簽名',
        settings: WatermarkSettings(
          text: TextMark(
            text: 'My Channel',
            fontFamily: 'Lobster',
            colorValue: 0xFFFFFFFF,
            opacity: 0.9,
            sizeFrac: 0.07,
            x: 0.82,
            y: 0.88,
            rotation: -6,
            shadow: true,
          ),
        ),
      ),
      WatermarkPreset(
        name: '角落細字',
        settings: WatermarkSettings(
          text: TextMark(
            text: '@我的頻道',
            fontFamily: 'NotoSansTC',
            colorValue: 0xFFFFFFFF,
            opacity: 0.55,
            sizeFrac: 0.026,
            x: 0.13,
            y: 0.06,
            shadow: false,
          ),
        ),
      ),
    ];

    final cur = await load();
    cur.removeWhere((p) => removals.contains(p.name));
    final names = cur.map((p) => p.name).toSet();
    for (final p in extra) {
      if (!names.contains(p.name)) cur.add(p);
    }
    await saveAll(cur);
    await prefs.setBool(k3, true); // 資料寫完才立旗標
  }

  /// v4：範本歸範本（使用者的完整存檔）、樣式改到面板的「樣式」區。
  /// 把 v2/v3 種進來的內建樣式範本移除，只留「頻道標準」示範。
  static Future<void> ensureSeededV4() async {
    final prefs = await SharedPreferences.getInstance();
    const k4 = 'wm_presets_seeded_v4';
    if (prefs.getBool(k4) ?? false) return;

    const removals = {
      '大字滿版',
      '棋盤格',
      '底部橫幅',
      '描邊標題',
      '膠囊標籤',
      '手寫簽名',
      '角落細字',
    };
    final cur = await load();
    cur.removeWhere((p) => removals.contains(p.name));
    await saveAll(cur);
    await prefs.setBool(k4, true); // 資料寫完才立旗標
  }

  static Future<List<WatermarkPreset>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    final presets = <WatermarkPreset>[];
    for (final s in list) {
      try {
        presets.add(WatermarkPreset.decode(s));
      } catch (_) {
        // 略過壞掉的資料
      }
    }
    return presets;
  }

  static Future<void> saveAll(List<WatermarkPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, presets.map((p) => p.encode()).toList());
  }

  static Future<void> add(WatermarkPreset preset) async {
    final presets = await load();
    // 同名的直接覆蓋
    presets.removeWhere((p) => p.name == preset.name);
    presets.add(preset);
    await saveAll(presets);
  }

  static Future<void> remove(String name) async {
    final presets = await load();
    presets.removeWhere((p) => p.name == name);
    await saveAll(presets);
  }

  /// 改名；新名字撞到既有範本回 false（不覆蓋）
  static Future<bool> rename(String oldName, String newName) async {
    final presets = await load();
    if (presets.any((p) => p.name == newName)) return false;
    final i = presets.indexWhere((p) => p.name == oldName);
    if (i < 0) return false;
    presets[i] = WatermarkPreset(
        name: newName, settings: presets[i].settings);
    await saveAll(presets);
    return true;
  }
}
