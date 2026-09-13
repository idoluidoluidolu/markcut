import 'dart:convert';

import '../models/watermark_settings.dart';

/// Whole-canvas effects cannot be moved as a single object without changing
/// their repeat grid / animation amplitude. They retain the raster path.
bool overlayCanTransform(bool tiled, WmAnimation animation) =>
    !tiled && (animation == WmAnimation.none || animation == WmAnimation.blink);

String watermarkVisualSignature(
  WatermarkSettings settings, {
  bool rasterOnly = false,
}) {
  final json = settings.toJson();
  json.remove('activeText');
  json.remove('activeLogo');
  for (final field in ['texts', 'logos']) {
    for (final mark in (json[field] as List).cast<Map<String, dynamic>>()) {
      final image = mark['b64'];
      if (image is String) mark['b64'] = '${image.length}#${image.hashCode}';
      // Drawing edit history is not part of its rendered PNG.
      mark.remove('drawData');
      if (rasterOnly &&
          overlayCanTransform(mark['tiled'] == true, settings.animation)) {
        for (final key in [
          'x',
          'y',
          'sizeFrac',
          'rotation',
          if (field == 'logos') 'opacity',
        ]) {
          mark.remove(key);
        }
      }
    }
  }
  return jsonEncode(json);
}

List<Map<String, dynamic>> watermarkGeometryItems(
  WatermarkSettings settings,
  String prefix, {
  bool visible = true,
}) {
  Map<String, dynamic> item(
    String id,
    bool tiled,
    double x,
    double y,
    double scale,
    double rotation,
    double opacity,
  ) {
    final movable = overlayCanTransform(tiled, settings.animation);
    return {
      'id': id,
      'x': movable ? x : 0.5,
      'y': movable ? y : 0.5,
      'scale': movable ? scale : 1.0,
      'rot': movable ? rotation : 0.0,
      'opacity': visible ? (movable ? opacity : 1.0) : 0.0,
    };
  }

  return [
    for (var i = 0; i < settings.logos.length; i++)
      if (settings.logos[i].enabled && settings.logos[i].b64 != null)
        item(
          '$prefix:l$i',
          settings.logos[i].tiled,
          settings.logos[i].x,
          settings.logos[i].y,
          settings.logos[i].sizeFrac,
          settings.logos[i].rotation,
          settings.logos[i].opacity,
        ),
    for (var i = 0; i < settings.texts.length; i++)
      if (settings.texts[i].enabled && settings.texts[i].text.trim().isNotEmpty)
        item(
          '$prefix:t$i',
          settings.texts[i].tiled,
          settings.texts[i].x,
          settings.texts[i].y,
          settings.texts[i].sizeFrac,
          settings.texts[i].rotation,
          1,
        ),
  ];
}
