import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';

/// 疊在預覽畫面上的浮水印圖層：單指拖曳調位置、雙指捏合調大小。
/// 大小以「佔畫面寬度比例」計算，跟輸出時的算法一致，所見即所得。
/// 元素會自動夾在畫面內：太長的文字靠邊也不會超出去（匯出同一套規則）。
class WatermarkLayer extends StatefulWidget {
  final WatermarkSettings settings;
  final VoidCallback onChanged;

  /// 開始拖曳（父層拿來拍「上一步」快照）
  final VoidCallback? onDragStart;

  /// 選取狀態：true 時文字/Logo 外圍畫細白框提醒
  final bool selected;

  /// 點浮水印元素（父層拿來設定選取）
  final VoidCallback? onTap;

  /// 點浮水印「文字」時另外觸發（父層拿來直接開文字輸入）；
  /// 沒給就退回 onTap
  final VoidCallback? onTapText;

  /// 目前播放時間（秒）；動畫預覽用，靜態畫面給 null
  final double? time;

  const WatermarkLayer({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onDragStart,
    this.selected = false,
    this.onTap,
    this.onTapText,
    this.time,
  });

  @override
  State<WatermarkLayer> createState() => _WatermarkLayerState();
}

class _WatermarkLayerState extends State<WatermarkLayer> {
  // 捏合縮放的起點值
  double _baseTextSize = 0;
  double _baseLogoSize = 0;

  /// 選取框
  BoxDecoration? get _selDeco => widget.selected
      ? BoxDecoration(
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.9), width: 1.2),
        )
      : null;

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final onChanged = widget.onChanged;
    final onDragStart = widget.onDragStart;
    final onTap = widget.onTap;
    final onTapText = widget.onTapText;
    final time = widget.time;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final h = box.maxHeight;
      // 動畫（只在有時間軸的畫面生效）
      final anim = time == null
          ? (dx: 0.0, dy: 0.0, alpha: 1.0)
          : settings.animAt(time);
      final pad = w * 0.012;
      final children = <Widget>[];

      final logo = settings.logo;
      final logoBytes = logo.bytes;
      // Logo 滿版平鋪：整面重複，不能拖曳（位置無意義）
      if (logo.enabled && logoBytes != null && logo.tiled) {
        children.add(Positioned.fill(
          child: IgnorePointer(child: _TiledLogo(logo: logo)),
        ));
      } else if (logo.enabled && logoBytes != null) {
        final logoW = logo.sizeFrac * w;
        // 高度未知（解碼是非同步的），用寬度近似做垂直夾限；匯出端會精準夾
        final left = (logo.x * w - logoW / 2)
            .clamp(pad, math.max(pad, w - logoW - pad))
            .toDouble();
        final top = (logo.y * h - logoW / 2)
            .clamp(-logoW / 2, h - logoW / 2)
            .toDouble();
        children.add(Positioned(
          left: left,
          top: top,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            // 單指拖＝移動、雙指捏＝調大小
            onScaleStart: (_) {
              onDragStart?.call();
              _baseLogoSize = logo.sizeFrac;
            },
            onScaleUpdate: (d) {
              logo.x = ((logo.x * w + d.focalPointDelta.dx) / w)
                  .clamp(0.0, 1.0);
              logo.y = ((logo.y * h + d.focalPointDelta.dy) / h)
                  .clamp(0.0, 1.0);
              if (d.pointerCount > 1) {
                logo.sizeFrac =
                    (_baseLogoSize * d.scale).clamp(0.03, 0.9);
              }
              onChanged();
            },
            child: Container(
              decoration: _selDeco,
              child: Opacity(
                opacity: logo.opacity,
                child: Transform.rotate(
                  angle: logo.rotation * math.pi / 180,
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(logo.corner * logoW / 2),
                    child: Image.memory(logoBytes,
                        width: logoW, gaplessPlayback: true),
                  ),
                ),
              ),
            ),
          ),
        ));
      }

      final t = settings.text;
      // 滿版平鋪（棋盤格）：整面重複，不能拖曳（位置無意義）
      if (t.enabled && t.text.trim().isNotEmpty && t.tiled) {
        children.add(Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _TiledTextPainter(t, w)),
          ),
        ));
      } else if (t.enabled && t.text.trim().isNotEmpty) {
        // 不自動換行：過寬時整段等比縮小字級（跟匯出同一套規則）
        var fontSize = t.sizeFrac * w;
        final maxW = w * 0.96;

        TextPainter measure(double fs) => TextPainter(
              text: TextSpan(
                text: t.text,
                style: TextStyle(
                    fontFamily: t.fontFamily,
                    fontSize: fs,
                    letterSpacing: fs * t.spacing),
              ),
              textDirection: TextDirection.ltr,
            )..layout();

        var probe = measure(fontSize);
        if (probe.width > maxW) {
          fontSize *= maxW / probe.width;
          probe = measure(fontSize);
        }

        final style = TextStyle(
          fontFamily: t.fontFamily,
          fontSize: fontSize,
          letterSpacing: fontSize * t.spacing,
          color: t.color.withValues(alpha: t.opacity),
          shadows: t.shadow
              ? [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.55 * t.opacity),
                    blurRadius: fontSize * 0.08,
                    offset: Offset(fontSize * 0.03, fontSize * 0.03),
                  ),
                ]
              : null,
        );
        final left = (t.x * w - probe.width / 2)
            .clamp(pad, math.max(pad, w - probe.width - pad))
            .toDouble();
        final top = (t.y * h - probe.height / 2)
            .clamp(pad, math.max(pad, h - probe.height - pad))
            .toDouble();

        Widget textWidget(TextStyle st) => Text(
              t.text,
              softWrap: false,
              overflow: TextOverflow.visible,
              textScaler: TextScaler.noScaling,
              style: st,
            );

        children.add(Positioned(
          left: left,
          top: top,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapText ?? onTap,
            // 單指拖＝移動、雙指捏＝調字級
            onScaleStart: (_) {
              onDragStart?.call();
              _baseTextSize = t.sizeFrac;
            },
            onScaleUpdate: (d) {
              t.x = ((t.x * w + d.focalPointDelta.dx) / w)
                  .clamp(0.0, 1.0);
              t.y = ((t.y * h + d.focalPointDelta.dy) / h)
                  .clamp(0.0, 1.0);
              if (d.pointerCount > 1) {
                t.sizeFrac =
                    (_baseTextSize * d.scale).clamp(0.015, 0.4);
              }
              onChanged();
            },
            child: Transform.rotate(
              angle: t.rotation * math.pi / 180,
              child: Container(
              decoration: _selDeco,
              child: Container(
              padding: t.bg
                  ? EdgeInsets.symmetric(
                      horizontal: fontSize * 0.35 * t.bgPad,
                      vertical: fontSize * 0.18 * t.bgPad)
                  : EdgeInsets.zero,
              decoration: t.bg
                  ? BoxDecoration(
                      color: t.bgColor.withValues(alpha: t.bgOpacity),
                      borderRadius:
                          BorderRadius.circular(fontSize * t.bgCorner),
                    )
                  : null,
              child: t.outline
                  ? Stack(
                      children: [
                        textWidget(style.copyWith(
                          color: null,
                          shadows: null,
                          foreground: Paint()
                            ..style = PaintingStyle.stroke
                            ..strokeWidth =
                                math.max(1, fontSize * t.outlineWidth)
                            ..color = t.outlineColor
                                .withValues(alpha: t.opacity),
                        )),
                        textWidget(style),
                      ],
                    )
                  : textWidget(style),
              ),
            ),
            ),
          ),
        ));
      }

      // 動畫：整組浮水印一起位移＋淡出（閃爍＝alpha 0/1）
      if (anim.dx != 0 || anim.dy != 0 || anim.alpha != 1) {
        return Opacity(
          opacity: anim.alpha.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(anim.dx * w, anim.dy * h),
            child: Stack(children: children),
          ),
        );
      }
      return Stack(children: children);
    });
  }
}

/// Logo 滿版平鋪：解碼一次，之後用 CustomPaint 重複畫
class _TiledLogo extends StatefulWidget {
  final LogoMark logo;

  const _TiledLogo({required this.logo});

  @override
  State<_TiledLogo> createState() => _TiledLogoState();
}

class _TiledLogoState extends State<_TiledLogo> {
  ui.Image? _img;
  Uint8List? _decodedFrom;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_TiledLogo old) {
    super.didUpdateWidget(old);
    if (widget.logo.bytes != _decodedFrom) _decode();
  }

  void _decode() {
    final b = widget.logo.bytes;
    if (b == null) return;
    _decodedFrom = b;
    ui.decodeImageFromList(b, (img) {
      if (mounted) setState(() => _img = img);
    });
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _TiledLogoPainter(widget.logo, _img));
  }
}

/// Logo 平鋪的排列（跟匯出 WatermarkRenderer 同一套邏輯）
class _TiledLogoPainter extends CustomPainter {
  final LogoMark logo;
  final ui.Image? img;

  _TiledLogoPainter(this.logo, this.img);

  @override
  void paint(Canvas canvas, Size size) {
    final im = img;
    if (im == null) return;
    final w = size.width;
    final h = size.height;
    final targetW = logo.sizeFrac * w;
    final targetH = targetW * im.height / im.width;
    final stepX = targetW * 1.8;
    final stepY = targetH * 1.9;
    final src = Rect.fromLTWH(
        0, 0, im.width.toDouble(), im.height.toDouble());
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Colors.white.withValues(alpha: logo.opacity);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (logo.rotation.abs() > 0.01) {
      canvas.translate(w / 2, h / 2);
      canvas.rotate(logo.rotation * math.pi / 180);
      canvas.translate(-w / 2, -h / 2);
    }
    var row = 0;
    for (var y = -h; y < h * 2; y += stepY, row++) {
      final shift = row.isOdd ? stepX / 2 : 0.0;
      for (var x = -w - shift; x < w * 2; x += stepX) {
        final rect = Rect.fromLTWH(x, y, targetW, targetH);
        if (logo.corner > 0.01) {
          final r = logo.corner * math.min(targetW, targetH) / 2;
          canvas.save();
          canvas.clipRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(r)));
          canvas.drawImageRect(im, src, rect, paint);
          canvas.restore();
        } else {
          canvas.drawImageRect(im, src, rect, paint);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TiledLogoPainter old) =>
      old.logo != logo || old.img != img;
}

/// 滿版平鋪浮水印：跟匯出（WatermarkRenderer）同一套排列邏輯
class _TiledTextPainter extends CustomPainter {
  final TextMark t;
  final double canvasW; // 字級以畫面寬為基準

  _TiledTextPainter(this.t, this.canvasW);

  @override
  void paint(Canvas canvas, Size size) {
    final fontSize = t.sizeFrac * canvasW;
    final painter = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          fontFamily: t.fontFamily,
          fontSize: fontSize,
          letterSpacing: fontSize * t.spacing,
          color: t.color.withValues(alpha: t.opacity),
          shadows: t.shadow
              ? [
                  Shadow(
                    color:
                        Colors.black.withValues(alpha: 0.55 * t.opacity),
                    blurRadius: fontSize * 0.08,
                    offset: Offset(fontSize * 0.03, fontSize * 0.03),
                  ),
                ]
              : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // 描邊層（跟匯出同一套）
    TextPainter? strokePainter;
    if (t.outline) {
      strokePainter = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            fontFamily: t.fontFamily,
            fontSize: fontSize,
            letterSpacing: fontSize * t.spacing,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1, fontSize * t.outlineWidth)
              ..color = t.outlineColor.withValues(alpha: t.opacity),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }

    final w = size.width;
    final h = size.height;
    final stepX = painter.width + fontSize * 2.2;
    final stepY = painter.height + fontSize * 2.6;
    final padH = fontSize * 0.35 * t.bgPad;
    final padV = fontSize * 0.18 * t.bgPad;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (t.rotation.abs() > 0.01) {
      canvas.translate(w / 2, h / 2);
      canvas.rotate(t.rotation * math.pi / 180);
      canvas.translate(-w / 2, -h / 2);
    }
    var row = 0;
    for (var y = -h; y < h * 2; y += stepY, row++) {
      final shift = row.isOdd ? stepX / 2 : 0.0;
      for (var x = -w - shift; x < w * 2; x += stepX) {
        // 每一顆都畫完整的底色→描邊→文字
        if (t.bg) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x - padH, y - padV,
                  painter.width + padH * 2, painter.height + padV * 2),
              Radius.circular(fontSize * t.bgCorner),
            ),
            Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
          );
        }
        strokePainter?.paint(canvas, Offset(x, y));
        painter.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TiledTextPainter old) =>
      old.t != t || old.canvasW != canvasW;
}
