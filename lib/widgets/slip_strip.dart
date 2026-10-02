import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 換段（slip）的縮圖帶：整條＝整支原片，亮著的框＝這段片段用到的
/// 那一截。框的寬度固定（片段長度不變，使用者選的是「長度不變、換原片
/// 的另一段」），左右拖整條任何地方都會帶著框走；點一下＝起點移到
/// 那裡。拖的過程只回報 [onChanged]（畫框），放手才回報 [onEnd]——套用
/// 要重組合成，不能每一格都做
class SlipStrip extends StatefulWidget {
  /// 整支原片均勻抽的縮圖（第 i 張在 i/n 那個時間附近）。還沒抽好是空的
  final List<Uint8List> frames;

  /// 原片長度（秒）
  final double duration;

  /// 框的起點（原片秒）
  final double start;

  /// 框的長度（原片秒）
  final double length;

  /// 選段工具提供按時間抽取的影格，避免把稀疏的粗縮圖當成精準畫面。
  /// null 結果代表尚未載入，不能拿前一張影格冒充。
  final Uint8List? Function(double seconds)? frameAt;

  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  const SlipStrip({
    super.key,
    required this.frames,
    required this.duration,
    required this.start,
    required this.length,
    required this.onChanged,
    required this.onEnd,
    this.frameAt,
  });

  /// 整條的高度（縮圖也照這個高度排，近方形）
  static const double height = 56;

  @override
  State<SlipStrip> createState() => _SlipStripState();
}

class _SlipStripState extends State<SlipStrip> {
  /// 拖曳中累計的起點。累計在自己身上（不是每一下都從 widget.start
  /// 起算）：同一格裡來好幾個拖曳事件、父層還沒重畫時才不會吃掉位移。
  /// 一樣夾在頭尾之間：撞到頭再往外拖，回頭時框馬上就跟著動
  double? _raw;

  double get _maxStart =>
      (widget.duration - widget.length).clamp(0.0, double.infinity);

  void _moveTo(double s) {
    final v = s.clamp(0.0, _maxStart);
    if ((v - widget.start).abs() > 1e-6) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth;
      final dur = widget.duration;
      final span = dur <= 0 ? 1.0 : dur;
      double x(double t) => t / span * w;
      final left = x(widget.start);
      final right = x(widget.start + widget.length);
      final width = (right - left).clamp(4.0, double.infinity);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _raw = widget.start,
        onHorizontalDragUpdate: (d) {
          if (w <= 0) return;
          _raw = ((_raw ?? widget.start) + d.delta.dx / w * span).clamp(
            0.0,
            _maxStart,
          );
          _moveTo(_raw!);
        },
        onHorizontalDragEnd: (_) {
          _raw = null;
          widget.onEnd();
        },
        onHorizontalDragCancel: () {
          if (_raw == null) return;
          _raw = null;
          widget.onEnd();
        },
        onTapUp: (d) {
          if (w <= 0) return;
          _moveTo(d.localPosition.dx / w * span);
          widget.onEnd();
        },
        child: SizedBox(
          height: SlipStrip.height,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _Filmstrip(
                    frames: widget.frames,
                    duration: widget.duration,
                    frameAt: widget.frameAt,
                  ),
                ),
              ),
              // 框外壓暗：用到的那一截才是亮的
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: left.clamp(0.0, w),
                child: const _Shade(left: true),
              ),
              Positioned(
                left: right.clamp(0.0, w),
                right: 0,
                top: 0,
                bottom: 0,
                child: const _Shade(left: false),
              ),
              Positioned(
                left: left,
                top: 0,
                bottom: 0,
                width: width,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: kSelect, width: 2.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 框外那兩塊壓暗（圓角跟縮圖帶外緣對齊）
class _Shade extends StatelessWidget {
  final bool left;

  const _Shade({required this.left});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: left
            ? const BorderRadius.horizontal(left: Radius.circular(6))
            : const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
    ),
  );
}

/// 整支原片的縮圖帶：格子近方形（寬＝高），一格挑時間上最接近它中間
/// 的那一張縮圖
class _Filmstrip extends StatelessWidget {
  final List<Uint8List> frames;
  final double duration;
  final Uint8List? Function(double)? frameAt;

  const _Filmstrip({
    required this.frames,
    required this.duration,
    this.frameAt,
  });

  @override
  Widget build(BuildContext context) {
    if (frames.isEmpty && frameAt == null) {
      return const ColoredBox(color: kPanel);
    }
    return LayoutBuilder(
      builder: (context, box) {
        final tiles = (box.maxWidth / box.maxHeight).ceil().clamp(1, 64);
        Uint8List? tile(int k) {
          final at = (k + 0.5) / tiles * duration;
          if (frameAt != null) return frameAt!(at);
          return frames[(at / duration * frames.length).floor().clamp(
            0,
            frames.length - 1,
          )];
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var k = 0; k < tiles; k++)
              Expanded(
                child: tile(k) == null
                    ? const ColoredBox(color: kPanelHi)
                    : Image.memory(
                        tile(k)!,
                        fit: BoxFit.cover,
                        gaplessPlayback: false,
                      ),
              ),
          ],
        );
      },
    );
  }
}
