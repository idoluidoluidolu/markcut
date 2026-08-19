import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 貼圖庫：Emoji 與「自己常用的圖片」。
///
/// 兩者最後都是一張透明背景的 PNG，走現有的圖片浮水印那條路——
/// 位置、縮放、旋轉、透明度、平鋪、匯出全部直接繼承，這裡只負責
/// 「產出／記住那張圖」。
///
/// 自訂貼圖用 base64 存在本機（跟範本同一套做法）。Emoji 不存圖，
/// 只存字元，用到時才畫成 PNG——一顆 emoji 的 PNG 大約 30KB，
/// 全部存起來會把 web 的 localStorage（5MB）吃光
class StickerStore {
  static const _key = 'stickers_v1';

  /// 內建的 Emoji 貼圖（常用的表情、手勢、符號、動物、食物）
  static const emojis = <String>[
    '😀', '😂', '🥹', '😍', '🤩', '😎', '🥳', '😭',
    '😱', '🤔', '😴', '🤗', '😤', '🙄', '😇', '🤯',
    '❤️', '💔', '✨', '⭐', '🔥', '💯', '🎉', '🎊',
    '👍', '👎', '👏', '🙏', '💪', '👀', '🤙', '✌️',
    '🐶', '🐱', '🐰', '🐻', '🦊', '🐼', '🐷', '🦄',
    '🍎', '🍰', '🍕', '🍜', '🍺', '☕', '🍓', '🍿',
    '☀️', '🌙', '☁️', '🌈', '❄️', '💧', '🌸', '🍀',
    '📌', '🔔', '💡', '🎵', '📷', '🎬', '💰', '🚀',
  ];

  /// 使用者收藏的圖片貼圖（新的排在最前面）
  static Future<List<Uint8List>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    final out = <Uint8List>[];
    for (final s in raw) {
      try {
        out.add(base64Decode(s));
      } catch (_) {
        // 壞掉的那筆跳過就好，不要讓整個貼圖庫讀不出來
      }
    }
    return out;
  }

  /// 收藏一張。重複的（同一份位元組）往前挪，不再存第二份
  static Future<void> add(Uint8List png) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = List<String>.of(prefs.getStringList(_key) ?? const []);
    final b64 = base64Encode(png);
    raw.remove(b64);
    raw.insert(0, b64);
    // 上限 60 張：web 的 localStorage 只有 5MB，無上限會存到爆
    while (raw.length > 60) {
      raw.removeLast();
    }
    await prefs.setStringList(_key, raw);
  }

  static Future<void> removeAt(int i) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = List<String>.of(prefs.getStringList(_key) ?? const []);
    if (i < 0 || i >= raw.length) return;
    raw.removeAt(i);
    await prefs.setStringList(_key, raw);
  }

  /// 把一顆 Emoji 畫成透明背景的 PNG（邊長 [size]）。
  ///
  /// 直接當圖片浮水印用：貼圖的縮放、旋轉、平鋪全部免費繼承，
  /// 匯出也不用另外處理字型（PNG 裡就是畫好的樣子）。
  ///
  /// 1024：使用者會把 emoji 拉到滿版（sizeFrac 最大 2.0），
  /// 256px 的圖放到 1080p 畫布上是一團糊
  static Future<Uint8List?> renderEmoji(String emoji,
      {double size = 1024}) async {
    final painter = TextPainter(
      text: TextSpan(text: emoji, style: TextStyle(fontSize: size * 0.82)),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = painter.width;
    final h = painter.height;
    if (w < 2 || h < 2) return null;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    painter.paint(canvas, Offset.zero);
    final img = await rec.endRecording().toImage(w.ceil(), h.ceil());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }
}
