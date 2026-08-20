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

/// 照片上的一塊馬賽克區域：中心座標（0~1）＋大小（短邊比例）＋樣式。
/// 掛在 WatermarkSettings 上，跟著範本一起存／套用
class PhotoMosaic {
  double x;
  double y;
  double scale;
  MosaicStyle style;

  PhotoMosaic({
    this.x = 0.5,
    this.y = 0.5,
    // 預設就要蓋得住主體，太小每次都得先放大（跟影片編輯同一個值）
    this.scale = 0.72,
    MosaicStyle? style,
  }) : style = style ?? MosaicStyle();

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'scale': scale,
    'style': style.toJson(),
  };

  factory PhotoMosaic.fromJson(Map<String, dynamic> j) => PhotoMosaic(
    x: ((j['x'] ?? 0.5).toDouble() as double).clamp(0.0, 1.0),
    y: ((j['y'] ?? 0.5).toDouble() as double).clamp(0.0, 1.0),
    scale: ((j['scale'] ?? 0.35).toDouble() as double).clamp(0.02, 3.0),
    style: j['style'] is Map
        ? MosaicStyle.fromJson(Map<String, dynamic>.from(j['style'] as Map))
        : MosaicStyle(),
  );

  PhotoMosaic copy() =>
      PhotoMosaic(x: x, y: y, scale: scale, style: style.copy());
}
