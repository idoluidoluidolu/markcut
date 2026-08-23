import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';
import '../services/watermark_renderer.dart';

/// 單一來源浮水印顯示：畫的是 WatermarkRenderer（匯出渲染器）產的
/// PNG——跟成品共用同一份點陣，預覽即成品。
///
/// 用法：鋪在畫布上（自己撐滿父層），把 [WatermarkLayer] 設成
/// paintContent: false 疊在上面當手勢骨架。設定變了（輕量指紋比對）
/// 就以 80ms 併批重烘；重烘完成前顯示上一張（不閃空白）。
/// [time] 給了且有動畫時，位移/透明照 animAt 套在圖上——跟匯出
/// 兩條路同一顆數學。
class BakedWatermark extends StatefulWidget {
  final WatermarkSettings settings;

  /// 烘焙解析度（短邊）。縮圖磚 256、互動畫布 720~1080
  final int shortSide;

  /// 動畫時間（秒）；null＝靜態
  final double? time;

  const BakedWatermark({
    super.key,
    required this.settings,
    this.shortSide = 720,
    this.time,
  });

  @override
  State<BakedWatermark> createState() => _BakedWatermarkState();
}

class _BakedWatermarkState extends State<BakedWatermark> {
  Uint8List? _png;
  String? _sig; // 已顯示圖的指紋（不含解析度檔位）
  bool _sigIsFull = false; // 顯示中的是全解析版嗎
  bool _baking = false;
  Timer? _settle;

  /// 輕量指紋：不 jsonEncode（Logo 的 base64 動輒幾百 KB，每一格
  /// 編碼一次會把預覽拖垮）。b64 用「同一個字串物件」當身分——
  /// 沒換圖就是同一個 reference
  static String _lightSig(WatermarkSettings s, int bw, int bh) {
    final b = StringBuffer('$bw x$bh|${s.animation.index}');
    for (final t in s.texts) {
      b.write(
        '|T${t.enabled}|${t.text}|${t.fontFamily}|${t.colorValue}'
        '|${t.opacity}|${t.sizeFrac}|${t.spacing}|${t.x}|${t.y}'
        '|${t.rotation}|${t.tiled}|${t.shadow}'
        '|${t.shadowOpacity}|${t.shadowBlur}|${t.outline}'
        '|${t.outlineColorValue}|${t.outlineWidth}|${t.bg}'
        '|${t.bgColorValue}|${t.bgOpacity}|${t.bgCorner}|${t.bgPad}',
      );
    }
    for (final l in s.logos) {
      b.write(
        '|L${l.enabled}|${identityHashCode(l.b64)}|${l.b64?.length ?? 0}'
        '|${l.opacity}|${l.sizeFrac}|${l.x}|${l.y}|${l.rotation}'
        '|${l.corner}|${l.tiled}',
      );
    }
    return b.toString();
  }

  /// 雙檔位：設定一變就立刻以低解析（短邊 288，~幾 ms）連續
  /// 烘——滑桿拖曳即時跟手；停手 250ms 後換全解析正式版
  void _maybeBake(int bw, int bh) {
    final sig = _lightSig(widget.settings, bw, bh);
    if (sig == _sig && _sigIsFull) return;
    if (sig != _sig) {
      // 設定變了：快檔位馬上跟（不防抖，靠 _baking 串流）
      unawaited(_bake(bw, bh, full: false));
    }
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 250), () {
      unawaited(_bake(bw, bh, full: true));
    });
  }

  Future<void> _bake(int bw, int bh, {required bool full}) async {
    if (_baking) return; // 上一張還在烘：下一輪 build 會再來
    final want = _lightSig(widget.settings, bw, bh);
    if (want == _sig && (_sigIsFull || !full)) return;
    _baking = true;
    try {
      final k = full ? 1.0 : (288 / widget.shortSide).clamp(0.1, 1.0);
      final png = await WatermarkRenderer.renderOverlayPng(
        widget.settings,
        (bw * k).round().clamp(1, 4096),
        (bh * k).round().clamp(1, 4096),
      );
      if (!mounted) return;
      setState(() {
        _png = png;
        _sig = want;
        _sigIsFull = full;
      });
    } catch (_) {
      // 烘不出來就維持上一張
    } finally {
      _baking = false;
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        final h = cons.maxHeight;
        if (!w.isFinite || !h.isFinite || w < 1 || h < 1) {
          return const SizedBox.shrink();
        }
        final aspect = w / h;
        final int bw;
        final int bh;
        if (aspect >= 1) {
          bh = widget.shortSide;
          bw = (widget.shortSide * aspect).round().clamp(1, 4096);
        } else {
          bw = widget.shortSide;
          bh = (widget.shortSide / aspect).round().clamp(1, 4096);
        }
        _maybeBake(bw, bh);
        final png = _png;
        if (png == null) return const SizedBox.shrink();
        Widget img = Image.memory(png, fit: BoxFit.fill, gaplessPlayback: true);
        final t = widget.time;
        if (t != null && widget.settings.animation != WmAnimation.none) {
          final av = widget.settings.animAt(t);
          img = Transform.translate(
            offset: Offset(av.dx * w, av.dy * h),
            child: Opacity(
              opacity: av.alpha.clamp(0.0, 1.0).toDouble(),
              child: img,
            ),
          );
        }
        return img;
      },
    );
  }
}
