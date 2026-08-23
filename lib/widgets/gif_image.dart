import 'dart:io';

import 'package:flutter/material.dart';

import '../services/gif_store.dart';

/// 畫一個 GIF。參照可能是檔案路徑，也可能是內建範例
/// （Web 的展示模式，見 [GifStore.demoRefs]）——兩種都會動
class GifImage extends StatelessWidget {
  final String ref;
  final BoxFit fit;

  const GifImage(this.ref, {super.key, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) => GifStore.isAsset(ref)
      ? Image.asset(GifStore.assetKey(ref), fit: fit, gaplessPlayback: true)
      : Image.file(File(ref), fit: fit, gaplessPlayback: true);
}
