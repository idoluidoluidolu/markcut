import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// 可選字型（全部為免費開源授權 SIL OFL）
const kFontOptions = <({String label, String family})>[
  (label: '思源黑體', family: 'NotoSansTC'),
  (label: '思源宋體', family: 'NotoSerifTC'),
  (label: 'jf open 粉圓', family: 'OpenHuninn'),
  (label: '文楷', family: 'LXGWWenKaiTC'),
  (label: '朱古力黑體', family: 'ChocolateClassicalSans'),
  (label: 'Montserrat', family: 'Montserrat'),
  (label: 'Playfair', family: 'PlayfairDisplay'),
  (label: 'Pacifico', family: 'Pacifico'),
  (label: 'Bebas Neue', family: 'BebasNeue'),
  (label: 'Oswald', family: 'Oswald'),
  (label: 'Lobster', family: 'Lobster'),
  (label: 'Anton', family: 'Anton'),
  (label: 'Courier Prime', family: 'CourierPrime'),
];

/// 文字浮水印設定。位置與大小皆為相對值，套用到任何解析度都一致。
class TextMark {
  bool enabled;
  String text;
  String fontFamily;
  int colorValue;
  double opacity; // 0~1
  double sizeFrac; // 字體大小佔畫面寬度的比例
  double spacing; // 字距（相對字級 0~0.6）
  double x; // 中心點位置 0~1
  double y;
  double rotation; // 旋轉角度 -180 ~ 180
  bool tiled; // 滿版平鋪（棋盤格防盜：整個畫面重複鋪排，忽略 x/y）
  bool shadow; // 陰影讓浮水印在亮背景上也看得清楚
  bool outline; // 描邊
  int outlineColorValue;
  double outlineWidth; // 粗度，相對字級 0.02~0.2
  bool bg; // 底色塊
  int bgColorValue;
  double bgOpacity; // 底色透明度
  double bgCorner; // 底色圓角（相對字級 0~1）
  double bgPad; // 底色留白倍率（1 = 標準）

  TextMark({
    this.enabled = true,
    this.text = '@我的浮水印',
    this.fontFamily = 'NotoSansTC',
    this.colorValue = 0xFFFFFFFF,
    // 預設：置中、大字、較透明（一眼看得出浮水印在哪、怎麼調）
    this.opacity = 0.55,
    this.sizeFrac = 0.12,
    this.spacing = 0,
    this.x = 0.5,
    this.y = 0.5,
    this.rotation = 0,
    this.tiled = false,
    this.shadow = true,
    this.outline = false,
    this.outlineColorValue = 0xFF000000,
    this.outlineWidth = 0.07,
    this.bg = false,
    this.bgColorValue = 0xFF000000,
    this.bgOpacity = 0.45,
    this.bgCorner = 0.25,
    this.bgPad = 1.0,
  });

  Color get color => Color(colorValue);
  Color get outlineColor => Color(outlineColorValue);
  Color get bgColor => Color(bgColorValue);

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'text': text,
        'fontFamily': fontFamily,
        'colorValue': colorValue,
        'opacity': opacity,
        'sizeFrac': sizeFrac,
        'spacing': spacing,
        'x': x,
        'y': y,
        'rotation': rotation,
        'tiled': tiled,
        'shadow': shadow,
        'outline': outline,
        'outlineColorValue': outlineColorValue,
        'outlineWidth': outlineWidth,
        'bg': bg,
        'bgColorValue': bgColorValue,
        'bgOpacity': bgOpacity,
        'bgCorner': bgCorner,
        'bgPad': bgPad,
      };

  factory TextMark.fromJson(Map<String, dynamic> j) => TextMark(
        enabled: j['enabled'] ?? true,
        text: j['text'] ?? '',
        fontFamily: j['fontFamily'] ?? 'NotoSansTC',
        colorValue: j['colorValue'] ?? 0xFFFFFFFF,
        opacity: (j['opacity'] ?? 0.8).toDouble(),
        sizeFrac: (j['sizeFrac'] ?? 0.05).toDouble(),
        spacing: (j['spacing'] ?? 0).toDouble(),
        x: (j['x'] ?? 0.82).toDouble(),
        y: (j['y'] ?? 0.92).toDouble(),
        rotation: (j['rotation'] ?? 0).toDouble(),
        tiled: j['tiled'] ?? false,
        shadow: j['shadow'] ?? true,
        outline: j['outline'] ?? false,
        outlineColorValue: j['outlineColorValue'] ?? 0xFF000000,
        outlineWidth: (j['outlineWidth'] ?? 0.07).toDouble(),
        bg: j['bg'] ?? false,
        bgColorValue: j['bgColorValue'] ?? 0xFF000000,
        bgOpacity: (j['bgOpacity'] ?? 0.45).toDouble(),
        bgCorner: (j['bgCorner'] ?? 0.25).toDouble(),
        bgPad: (j['bgPad'] ?? 1.0).toDouble(),
      );

  TextMark copy() => TextMark.fromJson(toJson());
}

/// 圖片 Logo 浮水印設定。
/// Logo 以 base64 直接存進設定（挑選時已縮到 1024px 內），
/// 這樣範本自帶圖檔、跨平台（含 Web）都能用。
class LogoMark {
  bool enabled;
  String? b64; // PNG base64
  double opacity;
  double sizeFrac; // Logo 寬度佔畫面寬度的比例
  double x;
  double y;
  double rotation; // 旋轉角度 -180 ~ 180
  double corner; // 圓角 0~1（1 = 半徑為寬度一半）
  bool tiled; // 滿版平鋪（棋盤格），開啟後 x/y 無意義

  Uint8List? _cache;

  LogoMark({
    this.enabled = false,
    this.b64,
    this.opacity = 0.8,
    this.sizeFrac = 0.18,
    this.x = 0.15,
    this.y = 0.9,
    this.rotation = 0,
    this.corner = 0,
    this.tiled = false,
  });

  Uint8List? get bytes {
    if (b64 == null) return null;
    return _cache ??= base64Decode(b64!);
  }

  set bytesValue(Uint8List v) {
    _cache = v;
    b64 = base64Encode(v);
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'b64': b64,
        'opacity': opacity,
        'sizeFrac': sizeFrac,
        'x': x,
        'y': y,
        'rotation': rotation,
        'corner': corner,
        'tiled': tiled,
      };

  factory LogoMark.fromJson(Map<String, dynamic> j) => LogoMark(
        enabled: j['enabled'] ?? false,
        b64: j['b64'],
        opacity: (j['opacity'] ?? 0.8).toDouble(),
        sizeFrac: (j['sizeFrac'] ?? 0.18).toDouble(),
        x: (j['x'] ?? 0.15).toDouble(),
        y: (j['y'] ?? 0.9).toDouble(),
        rotation: (j['rotation'] ?? 0).toDouble(),
        corner: (j['corner'] ?? 0).toDouble(),
        tiled: j['tiled'] ?? false,
      );

  LogoMark copy() => LogoMark.fromJson(toJson());
}

/// 浮水印動畫（只對影片有效，照片輸出忽略）
enum WmAnimation { none, blink, drift, marquee }

extension WmAnimationInfo on WmAnimation {
  String get label => switch (this) {
        WmAnimation.none => '固定',
        WmAnimation.blink => '閃爍',
        WmAnimation.drift => '飄移',
        WmAnimation.marquee => '跑馬燈',
      };

  String get note => switch (this) {
        WmAnimation.none => '不動',
        WmAnimation.blink => '規律出現與消失',
        WmAnimation.drift => '原地輕輕漂浮',
        WmAnimation.marquee => '橫向掃過畫面',
      };
}

/// 一組完整的浮水印設定（文字 + Logo）
class WatermarkSettings {
  TextMark text;
  LogoMark logo;
  WmAnimation animation;
  double animSpeed; // 速度倍率 0.2~3（越大越快）
  double animRange; // 幅度倍率 0.2~3（閃爍＝亮的比例、飄移＝擺動幅度）

  WatermarkSettings({
    TextMark? text,
    LogoMark? logo,
    this.animation = WmAnimation.none,
    this.animSpeed = 1.0,
    this.animRange = 1.0,
  })  : text = text ?? TextMark(),
        logo = logo ?? LogoMark();

  /// 閃爍一輪的秒數
  double get blinkCycle => 1.2 / animSpeed;

  /// 閃爍時「亮著」的秒數
  double get blinkOn =>
      blinkCycle * (0.58 * animRange).clamp(0.1, 0.92);

  /// 跑馬燈掃過一輪的秒數
  double get marqueeCycle => 8 / animSpeed;

  /// 動畫在某個時間點的位移（相對畫面寬高的比例）與透明度倍率
  ({double dx, double dy, double alpha}) animAt(double t) {
    switch (animation) {
      case WmAnimation.none:
        return (dx: 0, dy: 0, alpha: 1);
      case WmAnimation.blink:
        return (
          dx: 0,
          dy: 0,
          alpha: (t % blinkCycle) < blinkOn ? 1.0 : 0.0
        );
      case WmAnimation.drift:
        final amp = 0.02 * animRange;
        return (
          dx: math.sin(t * 1.3 * animSpeed) * amp,
          dy: math.cos(t * 0.9 * animSpeed) * amp,
          alpha: 1
        );
      case WmAnimation.marquee:
        // 一輪從畫面右外側進、左外側出
        return (
          dx: 1 - (t % marqueeCycle) / (marqueeCycle / 2),
          dy: 0,
          alpha: 1
        );
    }
  }

  bool get hasAnyMark =>
      (text.enabled && text.text.trim().isNotEmpty) ||
      (logo.enabled && logo.b64 != null);

  Map<String, dynamic> toJson() => {
        'text': text.toJson(),
        'logo': logo.toJson(),
        'animation': animation.index,
        'animSpeed': animSpeed,
        'animRange': animRange,
      };

  factory WatermarkSettings.fromJson(Map<String, dynamic> j) =>
      WatermarkSettings(
        text: TextMark.fromJson(j['text'] ?? {}),
        logo: LogoMark.fromJson(j['logo'] ?? {}),
        animation: WmAnimation.values[
            ((j['animation'] ?? 0) as int) % WmAnimation.values.length],
        animSpeed: (j['animSpeed'] ?? 1.0).toDouble(),
        animRange: (j['animRange'] ?? 1.0).toDouble(),
      );

  WatermarkSettings copy() => WatermarkSettings.fromJson(toJson());
}

/// 已命名的浮水印範本（可儲存、一鍵套用）
class WatermarkPreset {
  String name;
  WatermarkSettings settings;

  WatermarkPreset({required this.name, required this.settings});

  String encode() => jsonEncode({'name': name, 'settings': settings.toJson()});

  factory WatermarkPreset.decode(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return WatermarkPreset(
      name: j['name'] ?? '未命名',
      settings: WatermarkSettings.fromJson(j['settings'] ?? {}),
    );
  }
}
