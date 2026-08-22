import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'mosaic.dart';

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

  /// 動畫（文字「素材」用；速度與幅度用預設值，不另外開滑桿）。
  /// 全域浮水印的動畫仍在 WatermarkSettings 上，這個欄位在那邊不用
  WmAnimation animation;

  TextMark({
    this.enabled = true,
    this.text = '@我的浮水印',
    this.fontFamily = 'NotoSansTC',
    this.colorValue = 0xFFFFFFFF,
    // 預設：置中、大字、較透明（一眼看得出浮水印在哪、怎麼調）
    this.opacity = 0.55,
    this.sizeFrac = 0.12, // 上限見面板滑桿（可放到超出畫面）
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
    this.animation = WmAnimation.none,
  });

  /// 動畫在某個時間點的位移與透明度（速度/幅度固定 1）
  ({double dx, double dy, double alpha}) animAt(double t) =>
      wmAnimOffset(animation, t);

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
    if (animation != WmAnimation.none) 'anim': animation.index,
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
    animation: WmAnimation
        .values[((j['anim'] ?? 0) as int) % WmAnimation.values.length],
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

  /// 這張是手繪的：圖片卡多一顆「編輯」把它載回畫板繼續畫
  bool drawn;

  /// 手繪的筆畫資料（JSON）。有它「編輯」還原的是一筆一筆活的筆畫；
  /// 沒有（舊資料）就退回鋪 PNG 當底的做法
  String? drawData;

  Uint8List? _cache;

  /// 裁切前的原圖。有它才能「還原」再重新裁一次——不然裁小了之後
  /// 再進裁切畫面，只會在已經裁過的那一小塊裡面繼續裁，回不去。
  ///
  /// 刻意不寫進 JSON：範本／草稿本來就自帶一份 PNG，再存一份原圖等於
  /// 體積翻倍（web 的 localStorage 只有 5MB）。所以它只活在這一次編輯
  /// 期間——裁完馬上想反悔的情境，這樣就夠了
  Uint8List? origBytes;

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
    this.drawn = false,
    this.drawData,
  });

  /// 同一張 Logo 會被複製到很多份設定（批次單張、多組浮水印、範本、
  /// undo 快照還原），base64 字串是共享參照，但解碼後的 bytes 原本
  /// 每份各解各的：一張 2MB 的 Logo 複製 20 份就是 40MB＋20 次解碼。
  /// 用兩格小池子讓同一個字串只解一次、所有副本共用同一份 bytes——
  /// 順帶讓 Image.memory 在框架的圖片快取裡也命中同一個 key
  static String? _poolKeyA, _poolKeyB;
  static Uint8List? _poolValA, _poolValB;

  Uint8List? get bytes {
    final s = b64;
    if (s == null) return null;
    if (_cache != null) return _cache;
    if (identical(s, _poolKeyA)) return _cache = _poolValA;
    if (identical(s, _poolKeyB)) return _cache = _poolValB;
    final v = base64Decode(s);
    _poolKeyB = _poolKeyA;
    _poolValB = _poolValA;
    _poolKeyA = s;
    _poolValA = v;
    return _cache = v;
  }

  set bytesValue(Uint8List v) {
    _cache = v;
    b64 = base64Encode(v);
    // 順手登記進池子：之後的 copy 直接共用這份，不再各自解碼
    _poolKeyB = _poolKeyA;
    _poolValB = _poolValA;
    _poolKeyA = b64;
    _poolValA = v;
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
    if (drawn) 'drawn': true,
    if (drawData != null) 'drawData': drawData,
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
    drawn: j['drawn'] ?? false,
    drawData: j['drawData'],
  );

  LogoMark copy() => LogoMark.fromJson(toJson());
}

/// 浮水印動畫（只對影片有效，照片輸出忽略）
enum WmAnimation { none, blink, drift, marquee }

/// 動畫的共用數學（浮水印設定與文字素材同一套，
/// 預覽跟兩條匯出路算出來的位移才會一致）
double wmBlinkCycle(double speed) => 1.2 / speed;
double wmBlinkOn(double speed, double range) =>
    wmBlinkCycle(speed) * (0.58 * range).clamp(0.1, 0.92);
double wmMarqueeCycle(double speed) => 8 / speed;

/// 動畫在某個時間點的位移（相對畫面寬高的比例）與透明度倍率
({double dx, double dy, double alpha}) wmAnimOffset(
  WmAnimation animation,
  double t, {
  double speed = 1,
  double range = 1,
}) {
  switch (animation) {
    case WmAnimation.none:
      return (dx: 0, dy: 0, alpha: 1);
    case WmAnimation.blink:
      return (
        dx: 0,
        dy: 0,
        alpha: (t % wmBlinkCycle(speed)) < wmBlinkOn(speed, range) ? 1.0 : 0.0,
      );
    case WmAnimation.drift:
      final amp = 0.02 * range;
      return (
        dx: math.sin(t * 1.3 * speed) * amp,
        dy: math.cos(t * 0.9 * speed) * amp,
        alpha: 1,
      );
    case WmAnimation.marquee:
      // 一輪從畫面右外側進、左外側出
      final cy = wmMarqueeCycle(speed);
      return (dx: 1 - (t % cy) / (cy / 2), dy: 0, alpha: 1);
  }
}

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

/// 一組完整的浮水印設定（文字 + 圖片）
class WatermarkSettings {
  /// 文字浮水印，可以放很多個（跟 logos 同一套模式）。永遠至少一個；
  /// 「目前操作中的是哪一個」記在 [activeText]，所有舊呼叫點拿的
  /// [text] 就是操作中的那一個，多文字只是換一個對象
  final List<TextMark> texts;

  int _activeText = 0;

  /// 圖片浮水印，可以放很多張。永遠至少一張（沒選圖時是空的那張，
  /// enabled=false），第一張就是舊版的 logo。
  ///
  /// 「目前操作中的是哪一張」記在 [activeLogo]：面板、預覽上的拖曳、
  /// 捏合縮放、選取框全部作用在 [logo] 上，多圖只是換一個對象，
  /// 不必每個畫面都自己管一套索引
  final List<LogoMark> logos;

  int _active = 0;

  WmAnimation animation;
  double animSpeed; // 速度倍率 0.2~3（越大越快）
  double animRange; // 幅度倍率 0.2~3（閃爍＝亮的比例、飄移＝擺動幅度）

  /// 設計時的畫布比例（寬/高）。範本卡照這個比例畫，
  /// 預覽才長得跟設計時一樣（舊資料沒存＝16:9）
  double designAspect;

  /// 照片模式的馬賽克區塊。掛在這裡是為了跟著範本一起存／套用；
  /// 影片編輯的全域浮水印不吃這個欄位（那邊的馬賽克是時間軸素材）
  List<PhotoMosaic> mosaics;

  WatermarkSettings({
    TextMark? text,
    List<TextMark>? texts,
    int activeText = 0,
    LogoMark? logo,
    List<LogoMark>? logos,
    int activeLogo = 0,
    this.animation = WmAnimation.none,
    this.animSpeed = 1.0,
    this.animRange = 1.0,
    this.designAspect = 16 / 9,
    List<PhotoMosaic>? mosaics,
  }) : // text（單個）是舊的建構參數，留著讓既有呼叫端不用改
       texts = (texts == null || texts.isEmpty) ? [text ?? TextMark()] : texts,
       // 參數名 activeText 對應私有欄位，initializing formal 用不上
       // ignore: prefer_initializing_formals
       _activeText = activeText,
       logos = (logos == null || logos.isEmpty) ? [logo ?? LogoMark()] : logos,
       _active = activeLogo,
       mosaics = mosaics ?? [];

  /// 目前操作中的那一個文字。索引夾在範圍內
  TextMark get text => texts[activeText];

  /// 舊呼叫端有直接指派 text 的（套範本），改成蓋掉操作中那個
  set text(TextMark t) => texts[activeText] = t;

  int get activeText => _activeText.clamp(0, texts.length - 1);

  set activeText(int i) => _activeText = i.clamp(0, texts.length - 1);

  /// 有內容的文字數
  int get textCount =>
      texts.where((t) => t.enabled && t.text.trim().isNotEmpty).length;

  /// 再加一個文字，並切成操作中。位置稍微錯開＋直接開著，
  /// 不然新的那個會整個疊在舊的上面、看起來像沒加到
  TextMark addText() {
    final base = text;
    final add = TextMark(
      enabled: true,
      sizeFrac: base.sizeFrac,
      colorValue: base.colorValue,
      opacity: base.opacity,
      fontFamily: base.fontFamily,
      x: (base.x + 0.08).clamp(0.0, 1.0),
      y: (base.y + 0.08).clamp(0.0, 1.0),
    );
    texts.add(add);
    _activeText = texts.length - 1;
    return add;
  }

  /// 刪掉一個。最後一個不真的移除（清空內容就好），
  /// [text] 才永遠有東西可以回傳
  void removeText(int i) {
    if (i < 0 || i >= texts.length) return;
    if (texts.length == 1) {
      texts[0] = TextMark();
    } else {
      texts.removeAt(i);
    }
    _activeText = _activeText.clamp(0, texts.length - 1);
  }

  /// 目前操作中的那一張圖片。索引夾在範圍內：刪掉最後一張之後
  /// 還留著舊索引也不會越界
  LogoMark get logo => logos[activeLogo];

  int get activeLogo => _active.clamp(0, logos.length - 1);

  set activeLogo(int i) => _active = i.clamp(0, logos.length - 1);

  /// 有內容（選過圖）的張數
  int get logoCount => logos.where((l) => l.b64 != null).length;

  /// 把另一組的浮水印內容整個搬過來（復原快照、套範本、讀草稿都用它）。
  /// 不換掉物件本身——面板與預覽拿的是同一個參照，換掉的話它們會繼續
  /// 對著舊物件改。馬賽克不在此列：那是照片上的東西，不跟著範本走。
  ///
  /// [other] 的 LogoMark 是直接接手不再複製，傳進來的通常是剛從 JSON
  /// 讀出來的暫時物件；要保留原件請自己先 copy()
  void copyMarksFrom(WatermarkSettings other) {
    texts
      ..clear()
      ..addAll(other.texts);
    activeText = other.activeText;
    logos
      ..clear()
      ..addAll(other.logos);
    activeLogo = other.activeLogo;
    animation = other.animation;
    animSpeed = other.animSpeed;
    animRange = other.animRange;
    designAspect = other.designAspect;
  }

  /// 再加一張圖片，並切成操作中。位置稍微錯開，不然新的那張
  /// 會整個疊在舊的上面、看起來像沒加到
  LogoMark addLogo() {
    final base = logo;
    final add = LogoMark(
      enabled: true,
      opacity: base.opacity,
      sizeFrac: base.sizeFrac,
      x: (base.x + 0.08).clamp(0.0, 1.0),
      y: (base.y + 0.08).clamp(0.0, 1.0),
      corner: base.corner,
    );
    logos.add(add);
    _active = logos.length - 1;
    return add;
  }

  /// 刪掉一張。最後一張不真的移除（清空內容就好），
  /// [logo] 才永遠有東西可以回傳
  void removeLogo(int i) {
    if (i < 0 || i >= logos.length) return;
    if (logos.length == 1) {
      logos[0] = LogoMark();
    } else {
      logos.removeAt(i);
    }
    _active = _active.clamp(0, logos.length - 1);
  }

  /// 閃爍一輪的秒數
  double get blinkCycle => wmBlinkCycle(animSpeed);

  /// 閃爍時「亮著」的秒數
  double get blinkOn => wmBlinkOn(animSpeed, animRange);

  /// 跑馬燈掃過一輪的秒數
  double get marqueeCycle => wmMarqueeCycle(animSpeed);

  /// 動畫在某個時間點的位移（相對畫面寬高的比例）與透明度倍率
  ({double dx, double dy, double alpha}) animAt(double t) =>
      wmAnimOffset(animation, t, speed: animSpeed, range: animRange);

  bool get hasAnyMark =>
      texts.any((t) => t.enabled && t.text.trim().isNotEmpty) ||
      logos.any((l) => l.enabled && l.b64 != null);

  // 只寫 logos，不再寫舊的 logo 鍵：圖片是 base64 存在設定裡的，
  // 兩份等於草稿與範本的體積翻倍（web 的 localStorage 只有 5MB）
  Map<String, dynamic> toJson() => {
    'texts': texts.map((t) => t.toJson()).toList(),
    'activeText': activeText,
    'logos': logos.map((l) => l.toJson()).toList(),
    'activeLogo': activeLogo,
    'animation': animation.index,
    'animSpeed': animSpeed,
    'animRange': animRange,
    'designAspect': designAspect,
    if (mosaics.isNotEmpty) 'mosaics': mosaics.map((m) => m.toJson()).toList(),
  };

  factory WatermarkSettings.fromJson(
    Map<String, dynamic> j,
  ) => WatermarkSettings(
    // 舊資料（草稿、範本）只有單個的 text，讀成一個的清單
    texts: ((j['texts'] as List?) ?? [j['text'] ?? const {}])
        .map((e) => TextMark.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    activeText: (j['activeText'] ?? 0) as int,
    // 舊資料（草稿、範本）只有單張的 logo，讀成一張的清單
    logos: ((j['logos'] as List?) ?? [j['logo'] ?? const {}])
        .map((e) => LogoMark.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    activeLogo: (j['activeLogo'] ?? 0) as int,
    mosaics: ((j['mosaics'] as List?) ?? const [])
        .map((e) => PhotoMosaic.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    animation: WmAnimation
        .values[((j['animation'] ?? 0) as int) % WmAnimation.values.length],
    // clamp 到滑桿範圍：0 會讓閃爍週期變 Infinity，
    // 進到 FFmpeg 濾鏡整個匯出直接失敗
    animSpeed: ((j['animSpeed'] ?? 1.0).toDouble() as double).clamp(0.2, 3.0),
    animRange: ((j['animRange'] ?? 1.0).toDouble() as double).clamp(0.2, 3.0),
    designAspect: ((j['designAspect'] ?? (16 / 9)).toDouble() as double).clamp(
      0.2,
      5.0,
    ),
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
