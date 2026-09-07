import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/gif_store.dart';

/// 畫一個 GIF。參照可能是檔案路徑，也可能是內建範例
/// （Web 的展示模式，見 [GifStore.demoRefs]）——兩種都會動
class GifImage extends StatelessWidget {
  final String ref;
  final BoxFit fit;

  /// 解碼寬度（實體像素）。磚上的 GIF 一律要給：匯入的 GIF 尺寸不限
  /// （可 1080 寬），不給的話每一格都以原尺寸解碼再縮到一百多點，
  /// 三塊磚就是三組 1080 寬的影格常駐。ResizeImage 對動圖同樣有效
  /// （整個 codec 以目標尺寸建，每一格都是縮過的）。null＝原尺寸
  /// （燈箱那種一次只放大看一張的地方）
  final int? cacheWidth;

  const GifImage(
    this.ref, {
    super.key,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  @override
  Widget build(BuildContext context) => GifStore.isAsset(ref)
      ? Image.asset(
          GifStore.assetKey(ref),
          fit: fit,
          gaplessPlayback: true,
          cacheWidth: cacheWidth,
        )
      : Image.file(
          File(ref),
          fit: fit,
          gaplessPlayback: true,
          cacheWidth: cacheWidth,
        );
}

/// 一個 GIF 的寬高比（寬÷高）；讀不到回 null。
///
/// 只讀檔頭：ImageDescriptor 只解出尺寸，不解任何一格像素。以前用
/// instantiateImageCodec＋getNextFrame，等於為了量尺寸把第一格整張
/// 解開（1080 寬的 GIF 一格就是 4MB），而且 codec 沒 dispose。
/// buffer 與 descriptor 都是原生記憶體，量完一定要放掉
Future<double?> gifAspect(String ref) async {
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  try {
    buf = GifStore.isAsset(ref)
        ? await ui.ImmutableBuffer.fromAsset(GifStore.assetKey(ref))
        : await ui.ImmutableBuffer.fromFilePath(ref);
    desc = await ui.ImageDescriptor.encoded(buf);
    if (desc.width <= 0 || desc.height <= 0) return null;
    return desc.width / desc.height;
  } catch (_) {
    return null;
  } finally {
    desc?.dispose();
    buf?.dispose();
  }
}
