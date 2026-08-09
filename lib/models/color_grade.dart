import 'dart:math' as math;
import 'dart:ui' as ui;

/// 一組調色設定。影片片段和照片共用同一份。
///
/// 三條顏色軸用互補色而不是抽象的色相角度——使用者說得出來的是
/// 「有點紅」「有點藍」，說不出「色相 +37 度」。
/// 正值＝加那個顏色，負值＝加它的互補色。
class ColorGrade {
  double balR; // 紅 ←→ 青
  double balG; // 綠 ←→ 洋紅
  double balB; // 藍 ←→ 黃
  double saturation; // 0 ~ 3（1 = 原樣）
  double brightness; // -1 ~ 1（0 = 原樣）＝整體加減
  double contrast; // 0 ~ 3（1 = 原樣）

  /// 曝光，單位是「級」（stop）。-1 = 暗一級、+1 = 亮一級。
  /// 跟亮度不同：亮度是加減、曝光是乘法，救過曝欠曝比較不會發灰
  double exposure;

  ColorGrade({
    this.balR = 0,
    this.balG = 0,
    this.balB = 0,
    this.saturation = 1,
    this.brightness = 0,
    this.contrast = 1,
    this.exposure = 0,
  });

  /// 有沒有調過（沒調就不套濾鏡，匯出時省一層）
  bool get hasColor =>
      balR.abs() > 0.001 ||
      balG.abs() > 0.001 ||
      balB.abs() > 0.001 ||
      brightness.abs() > 0.001 ||
      exposure.abs() > 0.001 ||
      (contrast - 1).abs() > 0.001 ||
      (saturation - 1).abs() > 0.001;

  void reset() {
    balR = 0;
    balG = 0;
    balB = 0;
    saturation = 1;
    brightness = 0;
    contrast = 1;
    exposure = 0;
  }

  ColorGrade copy() => ColorGrade(
    balR: balR,
    balG: balG,
    balB: balB,
    saturation: saturation,
    brightness: brightness,
    contrast: contrast,
    exposure: exposure,
  );

  void copyFrom(ColorGrade o) {
    balR = o.balR;
    balG = o.balG;
    balB = o.balB;
    saturation = o.saturation;
    brightness = o.brightness;
    contrast = o.contrast;
    exposure = o.exposure;
  }

  Map<String, dynamic> toJson() => {
    'balR': balR,
    'balG': balG,
    'balB': balB,
    'saturation': saturation,
    'brightness': brightness,
    'contrast': contrast,
    'exposure': exposure,
  };

  factory ColorGrade.fromJson(Map<String, dynamic> j) => ColorGrade(
    balR: (j['balR'] ?? 0).toDouble(),
    balG: (j['balG'] ?? 0).toDouble(),
    balB: (j['balB'] ?? 0).toDouble(),
    saturation: (j['saturation'] ?? 1.0).toDouble(),
    brightness: (j['brightness'] ?? 0).toDouble(),
    contrast: (j['contrast'] ?? 1.0).toDouble(),
    exposure: (j['exposure'] ?? 0).toDouble(),
  );

  /// 預覽用的 4x5 色彩矩陣。
  ///
  /// 套用順序跟匯出端的濾鏡一致：先色彩平衡（每個通道加減），再飽和度，
  /// 然後對比（繞 0.5 中灰），最後亮度平移。順序不一致預覽就會跟成品對不上
  List<double> get matrix {
    // Rec.709 亮度權重
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final inv = 1 - saturation;
    final s = saturation;
    final m = <double>[
      lr * inv + s,
      lg * inv,
      lb * inv,
      lr * inv,
      lg * inv + s,
      lb * inv,
      lr * inv,
      lg * inv,
      lb * inv + s,
    ];
    final c = contrast;
    // 曝光＝乘法增益（一級＝兩倍），跟對比一起乘在係數上
    final gain = math.pow(2, exposure).toDouble();
    // 對比繞中灰旋轉 + 亮度平移，是所有通道共用的常數項
    final base = 255 * (0.5 - 0.5 * c) + brightness * 255;
    // 色彩平衡：各通道自己的位移。±1 對應約 ±64 階，再大就壓爆通道了
    const k = 64.0;
    return [
      m[0] * c * gain,
      m[1] * c * gain,
      m[2] * c * gain,
      0,
      base + balR * k,
      m[3] * c * gain,
      m[4] * c * gain,
      m[5] * c * gain,
      0,
      base + balG * k,
      m[6] * c * gain,
      m[7] * c * gain,
      m[8] * c * gain,
      0,
      base + balB * k,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  ui.ColorFilter? get filter => hasColor ? ui.ColorFilter.matrix(matrix) : null;

  /// 匯出用的 FFmpeg 濾鏡片段。沒調過回空字串。
  /// 前面帶逗號，因為都是接在既有濾鏡後面。
  ///
  /// 只用 LGPL 建置一定有的濾鏡——eq 是 GPL 授權，min 版沒編進去
  /// （會直接 "No such filter: 'eq'"）。這裡把預覽的 4x5 矩陣拆成：
  /// 飽和度＝colorchannelmixer 的跨通道混合；
  /// 對比×曝光×亮度×色彩平衡＝lutrgb 的每通道仿射。
  /// 數學上跟預覽矩陣一字不差，成品和預覽才對得上
  String get ffmpeg {
    if (!hasColor) return '';
    String f(double v) => v.toStringAsFixed(4);
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final out = StringBuffer();

    if ((saturation - 1).abs() > 0.001) {
      final s = saturation;
      final inv = 1 - s;
      out.write(
        ',colorchannelmixer='
        'rr=${f(lr * inv + s)}:rg=${f(lg * inv)}:rb=${f(lb * inv)}:'
        'gr=${f(lr * inv)}:gg=${f(lg * inv + s)}:gb=${f(lb * inv)}:'
        'br=${f(lr * inv)}:bg=${f(lg * inv)}:bb=${f(lb * inv + s)}',
      );
    }

    // 每通道仿射：out = val×(對比×曝光增益) + 對比中灰補償 + 亮度 + 平衡位移
    final a = contrast * math.pow(2, exposure);
    final base = 255 * (0.5 - 0.5 * contrast) + brightness * 255;
    final offR = base + balR * 64;
    final offG = base + balG * 64;
    final offB = base + balB * 64;
    final needLut =
        (a - 1).abs() > 0.001 ||
        offR.abs() > 0.5 ||
        offG.abs() > 0.5 ||
        offB.abs() > 0.5;
    if (needLut) {
      String ch(double off) =>
          'clip(val*${f(a.toDouble())}'
          '${off < 0 ? '' : '+'}${f(off)}\\,0\\,255)';
      out.write(",lutrgb=r='${ch(offR)}':g='${ch(offG)}':b='${ch(offB)}'");
    }
    return out.toString();
  }
}
