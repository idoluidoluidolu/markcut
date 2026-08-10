import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../models/watermark_settings.dart';

/// 疊在預覽畫面上的浮水印圖層：單指拖曳調位置、雙指捏合調大小。
/// 大小以「佔畫面寬度比例」計算，跟輸出時的算法一致，所見即所得。
/// 元素會自動夾在畫面內：太長的文字靠邊也不會超出去（匯出同一套規則）。
/// 浮水印的兩個獨立部件
enum WmPart { none, text, logo }

class WatermarkLayer extends StatefulWidget {
  final WatermarkSettings settings;
  final VoidCallback onChanged;

  /// 開始拖曳（父層拿來拍「上一步」快照）
  final VoidCallback? onDragStart;

  /// 選取到哪一個部件：被選的那個外圍畫白框，縮放也只動它。
  /// 文字和圖片是兩個獨立的東西，一起縮放會把調好的搭配弄壞
  final WmPart selectedPart;

  /// 點到哪個部件（父層拿來記選取）
  final ValueChanged<WmPart>? onSelectPart;

  /// 點浮水印元素（父層拿來設定選取）
  final VoidCallback? onTap;

  /// 點浮水印「文字」時另外觸發（父層拿來直接開文字輸入）；
  /// 沒給就退回 onTap
  final VoidCallback? onTapText;

  /// 目前播放時間（秒）；動畫預覽用，靜態畫面給 null
  final double? time;

  /// 回傳 true 時暫停單指拖曳。
  /// 兩指捏合縮放時，其中一指滑過別的元素會把它拖走——
  /// 捏合期間要把拖曳整個鎖住
  final bool Function()? panLocked;

  /// 回傳 false 時該部件完全不註冊拖曳（只留點選）。
  /// 父層在「別的素材被選取」時用這個把拖曳讓給選中的素材
  final bool Function(WmPart part)? panAllowed;

  const WatermarkLayer({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onDragStart,
    this.selectedPart = WmPart.none,
    this.onSelectPart,
    this.onTap,
    this.onTapText,
    this.time,
    this.panLocked,
    this.panAllowed,
  });

  @override
  State<WatermarkLayer> createState() => _WatermarkLayerState();
}

class _WatermarkLayerState extends State<WatermarkLayer> {
  // 捏合縮放的起點值

  /// 選取框（只畫在被選的那個部件上）
  BoxDecoration? _deco(WmPart part) => widget.selectedPart == part
      ? BoxDecoration(
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.9),
            width: 1.2,
          ),
        )
      : null;

  /// 這個部件現在能不能拖：
  /// 有部件被選取時只有被選的能拖；父層說不行（別的素材選取中）就不行。
  /// 回 false 時連手勢都不註冊，拖曳會落到下層的「選取路由」去
  bool _canDrag(WmPart part) {
    if (widget.selectedPart != WmPart.none && widget.selectedPart != part) {
      return false;
    }
    return widget.panAllowed?.call(part) ?? true;
  }

  /// 正在拖哪個部件（畫置中輔助線用）
  WmPart _panning = WmPart.none;

  /// 上一刻有沒有吸在中線上（吸上去的瞬間震一下）
  bool _centerSnapped = false;

  /// 拖曳期間「未吸附」的原始座標。吸附只作用在顯示值上——
  /// 若直接把吸完的值當下一刻的起點，單次手指位移永遠小於吸附半徑,
  /// 吸上中線後就再也拖不出來（會一直被吸回去）
  double _rawX = 0, _rawY = 0;

  /// 拖曳時把座標吸到置中線（0.5）附近；回傳吸完的值
  double _snapCenter(double v) {
    if ((v - 0.5).abs() < 0.015) return 0.5;
    return v;
  }

  void _feedbackCenter(double x, double y) {
    final on = x == 0.5 || y == 0.5;
    if (on != _centerSnapped) {
      _centerSnapped = on;
      if (on) HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final onChanged = widget.onChanged;
    final onDragStart = widget.onDragStart;
    final onTap = widget.onTap;
    final onTapText = widget.onTapText;
    final time = widget.time;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        // 動畫（只在有時間軸的畫面生效）
        final anim = time == null
            ? (dx: 0.0, dy: 0.0, alpha: 1.0)
            : settings.animAt(time);
        final children = <Widget>[];

        final logo = settings.logo;
        final logoBytes = logo.bytes;
        // Logo 滿版平鋪：整面重複，不能拖曳（位置無意義）
        if (logo.enabled && logoBytes != null && logo.tiled) {
          children.add(
            Positioned.fill(
              child: IgnorePointer(child: _TiledLogo(logo: logo)),
            ),
          );
        } else if (logo.enabled && logoBytes != null) {
          // 大小以「短邊」為基準：同一個範本套到 16:9 或 9:16，
          // 看起來的比例才會一樣（用寬的話直式/橫式差超多）
          final logoW = logo.sizeFrac * math.min(w, h);
          // 不夾限：允許放大到超出畫面（跟匯出同一套規則）
          final left = logo.x * w - logoW / 2;
          final top = logo.y * h - logoW / 2;
          children.add(
            Positioned(
              left: left,
              top: top,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.onSelectPart?.call(WmPart.logo);
                  onTap?.call();
                },
                // 單指拖＝移動（雙指縮放由預覽層的 Listener 處理：
                // 元素本身範圍太小，兩指張開時第二指會落在範圍外）
                onPanStart: !_canDrag(WmPart.logo)
                    ? null
                    : (_) {
                        if (widget.panLocked?.call() ?? false) return;
                        _rawX = logo.x;
                        _rawY = logo.y;
                        setState(() => _panning = WmPart.logo);
                        onDragStart?.call();
                      },
                onPanUpdate: !_canDrag(WmPart.logo)
                    ? null
                    : (d) {
                        if (widget.panLocked?.call() ?? false) return;
                        // 手指位置累積在原始座標上；顯示值才吸中線,
                        // 拖離吸附半徑就自然脫離
                        _rawX = (_rawX + d.delta.dx / w).clamp(0.0, 1.0);
                        _rawY = (_rawY + d.delta.dy / h).clamp(0.0, 1.0);
                        logo.x = _snapCenter(_rawX);
                        logo.y = _snapCenter(_rawY);
                        _feedbackCenter(logo.x, logo.y);
                        onChanged();
                      },
                onPanEnd: !_canDrag(WmPart.logo)
                    ? null
                    : (_) => setState(() => _panning = WmPart.none),
                onPanCancel: !_canDrag(WmPart.logo)
                    ? null
                    : () => setState(() => _panning = WmPart.none),
                // 選取框放在旋轉「裡面」：框才會跟著 Logo 轉
                //（文字那邊本來就是這樣，兩邊要一致）
                child: Opacity(
                  opacity: logo.opacity,
                  child: Transform.rotate(
                    angle: logo.rotation * math.pi / 180,
                    child: Container(
                      decoration: _deco(WmPart.logo),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          logo.corner * logoW / 2,
                        ),
                        child: Image.memory(
                          logoBytes,
                          width: logoW,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final t = settings.text;
        // 滿版平鋪（棋盤格）：整面重複，不能拖曳（位置無意義）
        if (t.enabled && t.text.trim().isNotEmpty && t.tiled) {
          children.add(
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _TiledTextPainter(t, math.min(w, h))),
              ),
            ),
          );
        } else if (t.enabled && t.text.trim().isNotEmpty) {
          // 不自動換行、也不自動縮小：使用者調多大就多大，
          // 超出畫面是允許的（跟匯出同一套規則）
          final fontSize = t.sizeFrac * math.min(w, h); // 短邊基準

          TextPainter measure(double fs) => TextPainter(
            text: TextSpan(
              text: t.text,
              style: TextStyle(
                fontFamily: t.fontFamily,
                fontSize: fs,
                letterSpacing: fs * t.spacing,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

          final probe = measure(fontSize);

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
          // 不夾限：允許放大到超出畫面（跟匯出同一套規則）
          final left = t.x * w - probe.width / 2;
          final top = t.y * h - probe.height / 2;

          Widget textWidget(TextStyle st) => Text(
            t.text,
            softWrap: false,
            overflow: TextOverflow.visible,
            textScaler: TextScaler.noScaling,
            style: st,
          );

          children.add(
            Positioned(
              left: left,
              top: top,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.onSelectPart?.call(WmPart.text);
                  (onTapText ?? onTap)?.call();
                },
                // 單指拖＝移動（雙指縮放由預覽層的 Listener 處理）
                onPanStart: !_canDrag(WmPart.text)
                    ? null
                    : (_) {
                        if (widget.panLocked?.call() ?? false) return;
                        _rawX = t.x;
                        _rawY = t.y;
                        setState(() => _panning = WmPart.text);
                        onDragStart?.call();
                      },
                onPanUpdate: !_canDrag(WmPart.text)
                    ? null
                    : (d) {
                        if (widget.panLocked?.call() ?? false) return;
                        // 手指位置累積在原始座標上；顯示值才吸中線,
                        // 拖離吸附半徑就自然脫離
                        _rawX = (_rawX + d.delta.dx / w).clamp(0.0, 1.0);
                        _rawY = (_rawY + d.delta.dy / h).clamp(0.0, 1.0);
                        t.x = _snapCenter(_rawX);
                        t.y = _snapCenter(_rawY);
                        _feedbackCenter(t.x, t.y);
                        onChanged();
                      },
                onPanEnd: !_canDrag(WmPart.text)
                    ? null
                    : (_) => setState(() => _panning = WmPart.none),
                onPanCancel: !_canDrag(WmPart.text)
                    ? null
                    : () => setState(() => _panning = WmPart.none),
                child: Transform.rotate(
                  angle: t.rotation * math.pi / 180,
                  child: Container(
                    decoration: _deco(WmPart.text),
                    child: Container(
                      padding: t.bg
                          ? EdgeInsets.symmetric(
                              horizontal: fontSize * 0.35 * t.bgPad,
                              vertical: fontSize * 0.18 * t.bgPad,
                            )
                          : EdgeInsets.zero,
                      decoration: t.bg
                          ? BoxDecoration(
                              color: t.bgColor.withValues(alpha: t.bgOpacity),
                              borderRadius: BorderRadius.circular(
                                fontSize * t.bgCorner,
                              ),
                            )
                          : null,
                      child: t.outline
                          ? Stack(
                              children: [
                                textWidget(
                                  style.copyWith(
                                    color: null,
                                    shadows: null,
                                    foreground: Paint()
                                      ..style = PaintingStyle.stroke
                                      ..strokeWidth = math.max(
                                        1,
                                        fontSize * t.outlineWidth,
                                      )
                                      ..color = t.outlineColor.withValues(
                                        alpha: t.opacity,
                                      ),
                                  ),
                                ),
                                textWidget(style),
                              ],
                            )
                          : textWidget(style),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // 置中輔助線：拖曳中吸在中線上時，畫出垂直／水平線
        if (_panning != WmPart.none) {
          final p = _panning == WmPart.text ? settings.text : null;
          final lgP = _panning == WmPart.logo ? settings.logo : null;
          final px = p?.x ?? lgP?.x;
          final py = p?.y ?? lgP?.y;
          if (px == 0.5) {
            children.add(
              Positioned(
                left: w / 2 - 0.5,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    width: 1,
                    color: const Color(0xFFFFC24B).withValues(alpha: 0.9),
                  ),
                ),
              ),
            );
          }
          if (py == 0.5) {
            children.add(
              Positioned(
                top: h / 2 - 0.5,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    color: const Color(0xFFFFC24B).withValues(alpha: 0.9),
                  ),
                ),
              ),
            );
          }
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
      },
    );
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
    final targetW = logo.sizeFrac * math.min(w, h); // 短邊基準
    final targetH = targetW * im.height / im.width;
    final stepX = targetW * 1.8;
    final stepY = targetH * 1.9;
    final src = Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble());
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
          canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
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
                    color: Colors.black.withValues(alpha: 0.55 * t.opacity),
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
              Rect.fromLTWH(
                x - padH,
                y - padV,
                painter.width + padH * 2,
                painter.height + padV * 2,
              ),
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
