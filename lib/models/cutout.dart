import 'timeline.dart';

/// 去背後的背景：沒有（透出下面的軌，最底下是黑畫布）／純色／原畫面模糊。
///
/// 用 index 序列化：新種類一定要加在最尾端
enum CutoutBg { none, color, blur }

/// 一個影片片段的去背設定。
///
/// 遮罩是「素材」的（[MediaSource.cutMask]，同一支影片切成幾段都共用
/// 一份、算一次），開不開、背景換什麼是「片段」的
class ClipCutout {
  CutoutBg bg;

  /// 純色背景（ARGB）
  int color;

  ClipCutout({this.bg = CutoutBg.none, this.color = 0xFFFFFFFF});

  ClipCutout copy() => ClipCutout(bg: bg, color: color);

  Map<String, dynamic> toJson() => {
    'bg': bg.index,
    if (bg == CutoutBg.color) 'color': color,
  };

  static ClipCutout? fromJson(Object? j) {
    if (j is! Map) return null;
    final i = (j['bg'] as num?)?.toInt() ?? 0;
    return ClipCutout(
      bg: CutoutBg.values[i.clamp(0, CutoutBg.values.length - 1)],
      color: (j['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ClipCutout && other.bg == bg && other.color == color;

  @override
  int get hashCode => Object.hash(bg, color);
}

/// 純色背景的選項（成品的內容色，不是介面色：介面照舊黑白）
const kCutoutColors = <int>[
  0xFFFFFFFF,
  0xFF000000,
  0xFF8A8A94,
  0xFF00B140, // 綠幕綠：去背後再拿去別的軟體摳
  0xFF0047BB, // 藍幕藍
  0xFFF5E6CC,
  0xFFFFC0CB,
  0xFF87CEEB,
];

/// 片段在時間軸 [t] 那一刻要查遮罩的「素材秒數」。
///
/// 遮罩是照原檔算的；倒轉檔（[MediaSource.revOf]）的第 u 秒是原檔
/// 那一段倒過來的 revEnd − u 秒
double cutoutMaskTime(TimelineClip c, MediaSource s, double t) =>
    cutoutMaskTimeOfSource(s, c.sourceTimeAt(t));

/// 素材檔案自己的第 [u] 秒 → 遮罩的秒數（見 [cutoutMaskTime]）
double cutoutMaskTimeOfSource(MediaSource s, double u) =>
    s.revOf != null ? s.revEnd - u : u;

/// 原生合成器用的線性對照：片段開頭那一格的遮罩秒數（m0）與方向（dir）。
/// 合成器自己知道「每一秒合成時間走幾秒素材」（含變速、整體變速），
/// 遮罩秒數＝m0＋dir×素材秒數的位移
({double m0, int dir}) cutoutMaskMap(TimelineClip c, MediaSource s) {
  final rev = s.revOf != null;
  return (m0: rev ? s.revEnd - c.trimStart : c.trimStart, dir: rev ? -1 : 1);
}

/// 片段的去背真的會畫出來嗎：開了、遮罩也算好了
bool cutoutActive(TimelineClip c, MediaSource s) =>
    c.cutout != null && s.isVideo && (s.cutMask?.isNotEmpty ?? false);

/// 原生合成器（預覽）與原生匯出的去背欄位（Swift 端組 MCCutoutSpec）；
/// 沒開、遮罩還沒算好回 null（那就照舊整張畫）
Map<String, Object>? cutoutPayload(TimelineClip c, MediaSource s) {
  if (!cutoutActive(c, s)) return null;
  final cut = c.cutout!;
  final m = cutoutMaskMap(c, s);
  return {
    'mask': s.cutMask!,
    'm0': m.m0,
    'dir': m.dir,
    'bg': cut.bg.index,
    'color': cut.color,
  };
}
