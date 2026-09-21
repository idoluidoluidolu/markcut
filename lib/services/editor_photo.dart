import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crop_image_decoder.dart';
import 'file_reader.dart';

/// Editor previews never retain a camera photo's full-resolution raster.
/// On iOS ImageIO downsamples directly from the file; only the bounded PNG crosses
/// the platform channel. The original path remains the export/crop source.
class EditorPhoto {
  const EditorPhoto(this.width, this.height, this.bytes);

  final int width, height;
  final Uint8List bytes;
  static const maxSide = 2048;
  static const _channel = MethodChannel('markcut/photo');
  static bool get native =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<EditorPhoto> load(String path) async {
    if (native) {
      final value = await _channel.invokeMapMethod<String, dynamic>('preview', {
        'path': path,
        'maxSide': maxSide,
      });
      if (value != null &&
          value['bytes'] is Uint8List &&
          (value['w'] as num) > 0 &&
          (value['h'] as num) > 0) {
        return EditorPhoto(
          (value['w'] as num).toInt(),
          (value['h'] as num).toInt(),
          value['bytes'] as Uint8List,
        );
      }
      // Never retry a failed bounded native decode with a full-size Dart decode.
      throw StateError('讀不到照片');
    }
    final bytes = await readFileBytes(path);
    if (bytes == null) throw StateError('讀不到照片');
    final decoded = await decodeCropImage(bytes, maxSide: maxSide);
    try {
      if (decoded.sourceWidth <= maxSide && decoded.sourceHeight <= maxSide) {
        return EditorPhoto(decoded.sourceWidth, decoded.sourceHeight, bytes);
      }
      final png = await decoded.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) throw StateError('讀不到照片');
      return EditorPhoto(
        decoded.sourceWidth,
        decoded.sourceHeight,
        png.buffer.asUint8List(),
      );
    } finally {
      decoded.image.dispose();
    }
  }

  /// A whole-photo confirmation keeps the original HEIC and its HDR gain map.
  /// Cropping on iOS stays file-to-file, preserving source resolution and HDR.
  static Future<String> crop(String path, ui.Rect rect) async {
    if ((rect.left.abs() +
            rect.top.abs() +
            (rect.width - 1).abs() +
            (rect.height - 1).abs()) <
        0.000001) {
      return path;
    }
    final output = await _channel.invokeMethod<String>('crop', {
      'path': path,
      'rect': [rect.left, rect.top, rect.width, rect.height],
    });
    if (output == null) throw StateError('裁切結果存不下來');
    return output;
  }

  static Future<void> checkpoint(String stage) async {
    if (!native) return;
    try {
      await _channel.invokeMethod<void>('imageWork', stage);
    } catch (_) {
      // Diagnostics cannot prevent importing or releasing the preparation pause.
    }
  }
}
