import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/cutout.dart';
import '../services/cutout_mask.dart';
import '../services/cutout_photo.dart' show maskToImage;

/// 預覽上 Flutter 畫的那幾條路的去背：Android 的播放器圖層、拖曳時的
/// 快取幀、iOS 合成播放器還沒接手時的逐片段播放器。子元件（整張畫面，
/// 拉滿這一層的框）照遮罩挖掉背景、墊上背景。
///
/// 原生合成器那條（iOS 預覽與匯出）在 Swift 的 MCCutoutSpec，FFmpeg 匯出
/// 在 video_engine_io；三條路讀同一份遮罩檔、同一個時間對照
/// （models/cutout.dart 的 cutoutMaskTime），背景模糊都是長邊的 2%
class CutoutLayer extends StatefulWidget {
  const CutoutLayer({
    super.key,
    required this.maskPath,
    required this.time,
    required this.cut,
    required this.child,
    this.blurSource,
  });

  final String maskPath;

  /// 這一格要用的遮罩秒數（呼叫端照播放器現在的位置算好）
  final double time;
  final ClipCutout cut;
  final Widget child;

  /// 模糊背景要再畫一份同樣的畫面（同一個材質再掛一次）；沒給就退回純黑
  final Widget? blurSource;

  @override
  State<CutoutLayer> createState() => _CutoutLayerState();
}

class _CutoutLayerState extends State<CutoutLayer> {
  CutoutMaskFile? _file;
  String? _filePath;
  ui.Image? _img;
  int _imgIndex = -1;
  int _want = -1;

  /// 正在解的那一格（-1＝沒在解）：同一格不要因為又重畫一次就再排一次
  int _inflight = -1;

  @override
  void dispose() {
    _file?.close();
    _img?.dispose();
    super.dispose();
  }

  CutoutMaskFile? _open() {
    if (_filePath != widget.maskPath) {
      _file?.close();
      _file = CutoutMaskFile.openSync(widget.maskPath);
      _filePath = widget.maskPath;
      _imgIndex = -1;
    }
    return _file;
  }

  /// 第 [i] 格解成影像（同時只解一格；解的時候又要別格就記著，解完接著解）
  Future<void> _decode(int i) async {
    final f = _file;
    if (f == null) return;
    if (_inflight >= 0) {
      if (i != _inflight) _want = i;
      return;
    }
    try {
      var next = i;
      while (mounted && next >= 0 && identical(f, _file)) {
        _want = -1;
        _inflight = next;
        final m = f.frame(next);
        if (m == null) break;
        final img = await maskToImage(m, f.width, f.height);
        if (!mounted || !identical(f, _file)) {
          img.dispose();
          break;
        }
        final old = _img;
        setState(() {
          _img = img;
          _imgIndex = next;
        });
        old?.dispose();
        next = _want;
      }
    } finally {
      _inflight = -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _open();
    // 遮罩檔讀不到（被清掉、寫壞）：照舊整張畫，不要整層不見
    if (f == null) return widget.child;
    final i = f.indexAt(widget.time);
    if (i != _imgIndex && i != _want && i != _inflight) _decode(i);
    final img = _img;
    if (img == null) return widget.child;
    final fg = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => ImageShader(
        img,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.diagonal3Values(
          rect.width / img.width,
          rect.height / img.height,
          1,
        ).storage,
        filterQuality: FilterQuality.medium,
      ),
      child: widget.child,
    );
    switch (widget.cut.bg) {
      case CutoutBg.none:
        return fg;
      case CutoutBg.color:
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Color(widget.cut.color)),
            fg,
          ],
        );
      case CutoutBg.blur:
        final src = widget.blurSource;
        return LayoutBuilder(
          builder: (context, box) {
            final s =
                (box.biggest.longestSide.isFinite
                    ? box.biggest.longestSide
                    : 0.0) *
                0.02;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (src == null)
                  const ColoredBox(color: Colors.black)
                else
                  ClipRect(
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: s,
                        sigmaY: s,
                        tileMode: TileMode.clamp,
                      ),
                      child: src,
                    ),
                  ),
                fg,
              ],
            );
          },
        );
    }
  }
}
