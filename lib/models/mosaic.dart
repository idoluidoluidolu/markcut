/// 馬賽克的樣式設定（影片素材、照片區塊共用；獨立成檔避免
/// timeline / watermark_settings 互相依賴）
class MosaicStyle {
  /// 濃度 0~1：像素化＝格子越大、模糊＝越糊（純色遮蓋不吃這個）
  double strength;

  /// 0=像素化、1=模糊、2=純色遮蓋
  int type;

  /// 純色遮蓋的顏色（ARGB，只用 RGB；預設黑）
  int color;

  /// 模糊的邊緣柔化 0~1（0=硬邊；只有模糊樣式用）
  double feather;

  MosaicStyle({
    this.strength = 0.5,
    this.type = 0,
    this.color = 0xFF000000,
    this.feather = 0,
  });

  Map<String, dynamic> toJson() => {
    'strength': strength,
    'type': type,
    'color': color,
    'feather': feather,
  };

  factory MosaicStyle.fromJson(Map<String, dynamic> j) => MosaicStyle(
    strength: ((j['strength'] ?? 0.5).toDouble() as double).clamp(0.0, 1.0),
    type: ((j['type'] ?? 0) as int) % 3,
    color: (j['color'] ?? 0xFF000000) as int,
    feather: ((j['feather'] ?? 0.0).toDouble() as double).clamp(0.0, 1.0),
  );

  MosaicStyle copy() => MosaicStyle(
    strength: strength,
    type: type,
    color: color,
    feather: feather,
  );
}

/// 會動的馬賽克（影片自動找臉）：一串關鍵點，攤平成
/// `[s, cx, cy, w, h, s, cx, cy, w, h, …]`——s 是這個馬賽克素材自己的
/// 秒數（TimelineClip.sourceTimeAt，所以拖動、左邊修剪、切割都對得上），
/// cx／cy／w／h 是畫布的 0~1（w 對畫布寬、h 對畫布高）。
///
/// 位置在兩點之間照時間線性內插；**大小一段一段固定**：FFmpeg 那條匯出路
/// 一段只能有一個大小（crop 的寬高建好就不能動），預覽、iOS 合成也照
/// 同一套規則，三邊才長得一樣。[quantizeMosaicPath] 負責把差不多大的
/// 連續幾點併成同一個大小（取最大的，寧可多蓋）
class MosaicPathPoint {
  final double cx, cy, w, h;

  const MosaicPathPoint(this.cx, this.cy, this.w, this.h);
}

/// [keys]（見上）在素材秒數 [s] 時的位置與大小；超出頭尾回 null
MosaicPathPoint? mosaicPathAt(List<double> keys, double s) {
  final n = keys.length ~/ 5;
  if (n == 0) return null;
  double t(int i) => keys[i * 5];
  // 頭尾容許一格（30fps）的誤差：時間換算的捨入不該讓第一格沒碼到
  const eps = 1 / 60;
  if (s < t(0) - eps || s > t(n - 1) + eps) return null;
  if (n == 1 || s <= t(0)) {
    return MosaicPathPoint(keys[1], keys[2], keys[3], keys[4]);
  }
  if (s >= t(n - 1)) {
    final b = (n - 1) * 5;
    return MosaicPathPoint(keys[b + 1], keys[b + 2], keys[b + 3], keys[b + 4]);
  }
  var lo = 0, hi = n - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (t(mid) <= s) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = lo * 5, b = hi * 5;
  final span = keys[b] - keys[a];
  final f = span <= 0 ? 0.0 : ((s - keys[a]) / span).clamp(0.0, 1.0);
  return MosaicPathPoint(
    keys[a + 1] + (keys[b + 1] - keys[a + 1]) * f,
    keys[a + 2] + (keys[b + 2] - keys[a + 2]) * f,
    // 大小不內插：沿用前一點那一段的大小（理由見上）
    keys[a + 3],
    keys[a + 4],
  );
}

/// 把差不多大（寬、高各自最大÷最小不超過 1+[tolerance]）的連續幾點併成
/// 同一個大小，取那一段裡最大的（寧可多蓋）。回新的一串，不動傳進來的
List<double> quantizeMosaicPath(List<double> keys, {double tolerance = 0.15}) {
  final out = List<double>.of(keys);
  final n = keys.length ~/ 5;
  var start = 0;
  while (start < n) {
    var minW = keys[start * 5 + 3], maxW = minW;
    var minH = keys[start * 5 + 4], maxH = minH;
    var end = start + 1;
    while (end < n) {
      final w = keys[end * 5 + 3], h = keys[end * 5 + 4];
      final nMinW = w < minW ? w : minW, nMaxW = w > maxW ? w : maxW;
      final nMinH = h < minH ? h : minH, nMaxH = h > maxH ? h : maxH;
      if (nMaxW > nMinW * (1 + tolerance) || nMaxH > nMinH * (1 + tolerance)) {
        break;
      }
      minW = nMinW;
      maxW = nMaxW;
      minH = nMinH;
      maxH = nMaxH;
      end++;
    }
    for (var i = start; i < end; i++) {
      out[i * 5 + 3] = maxW;
      out[i * 5 + 4] = maxH;
    }
    start = end;
  }
  return out;
}

/// 照片上的一塊馬賽克：
/// - 區域：中心座標（0~1）＋寬（短邊比例）＋高寬比 [aspect]；
///   [oval] 時是橢圓（臉用）
/// - 筆刷筆畫（[stroke] 非 null）：一串 0~1 的點（x,y 交錯攤平）＋
///   筆刷粗細 [brush]（短邊比例）。這時 x/y/scale 不使用，
///   移動＝把每個點一起平移
/// 掛在 WatermarkSettings 上，跟著範本一起存／套用
class PhotoMosaic {
  double x;
  double y;
  double scale;
  MosaicStyle style;

  /// 筆刷筆畫的點（0~1，x,y 交錯攤平）。null＝方形區域
  List<double>? stroke;

  /// 筆刷直徑（短邊比例）
  double brush;

  /// 高÷寬（1＝正方形）。寬是 [scale]×畫布短邊，高照這個比例
  double aspect;

  /// 橢圓：補丁裁成內切橢圓（蓋臉比方塊自然）
  bool oval;

  /// 自動找到的臉（馬賽克模式點一下＝切換碼／不碼，不是選取）
  bool face;

  /// 這張臉使用者點掉了：留著位置（再點一下會回來），但不畫、不匯出
  bool off;

  PhotoMosaic({
    this.x = 0.5,
    this.y = 0.5,
    // 預設就要蓋得住主體，太小每次都得先放大（跟影片編輯同一個值）
    this.scale = 0.72,
    MosaicStyle? style,
    this.stroke,
    this.brush = 0.16,
    this.aspect = 1.0,
    this.oval = false,
    this.face = false,
    this.off = false,
  }) : style = style ?? MosaicStyle();

  bool get isStroke => stroke != null && stroke!.length >= 2;

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'scale': scale,
    'style': style.toJson(),
    if (stroke != null) 'stroke': stroke,
    if (stroke != null) 'brush': brush,
    // 預設值不寫：舊版存出來的 JSON 跟現在一字不差
    if (aspect != 1.0) 'aspect': aspect,
    if (oval) 'oval': true,
    if (face) 'face': true,
    if (off) 'off': true,
  };

  factory PhotoMosaic.fromJson(Map<String, dynamic> j) => PhotoMosaic(
    x: ((j['x'] ?? 0.5).toDouble() as double).clamp(0.0, 1.0),
    y: ((j['y'] ?? 0.5).toDouble() as double).clamp(0.0, 1.0),
    // 預設跟建構子一致（0.72）：不一致的話殘缺 JSON 會拿到
    // 跟新建不同的大小
    scale: ((j['scale'] ?? 0.72).toDouble() as double).clamp(0.02, 3.0),
    style: j['style'] is Map
        ? MosaicStyle.fromJson(Map<String, dynamic>.from(j['style'] as Map))
        : MosaicStyle(),
    stroke: j['stroke'] is List
        ? (j['stroke'] as List).map((e) => (e as num).toDouble()).toList()
        : null,
    brush: ((j['brush'] ?? 0.16).toDouble() as double).clamp(0.02, 0.6),
    aspect: ((j['aspect'] ?? 1.0).toDouble() as double).clamp(0.2, 5.0),
    oval: j['oval'] == true,
    face: j['face'] == true,
    off: j['off'] == true,
  );

  PhotoMosaic copy() => PhotoMosaic(
    x: x,
    y: y,
    scale: scale,
    style: style.copy(),
    stroke: stroke == null ? null : List.of(stroke!),
    brush: brush,
    aspect: aspect,
    oval: oval,
    face: face,
    off: off,
  );
}
