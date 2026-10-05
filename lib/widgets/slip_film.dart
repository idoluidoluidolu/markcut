import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../theme.dart';

/// 換段放大膠卷的排法：琥珀框固定在正中間、寬度是整條的四成，框寬＝
/// 片段長度，所以「一秒幾個像素」由片段長度決定（片段越短放得越大）。
///
/// 膠卷切成固定的時間格：第 k 格＝原片 [k·step, (k+1)·step)。格子跟著
/// 時間走、不跟著螢幕走，拖的時候同一格的縮圖不用重抽
class SlipFilmGeometry {
  SlipFilmGeometry({
    required this.width,
    required this.height,
    required this.duration,
    required this.length,
    double aspect = 1,
  }) : windowWidth = width * windowFraction,
       tileWidth = (height * (aspect > 0 ? aspect : 1.0)).clamp(
         height * 0.5,
         height * 2.0,
       );

  /// 框佔整條寬度的比例
  static const double windowFraction = 0.4;

  final double width;
  final double height;

  /// 原片長度（秒）
  final double duration;

  /// 片段長度（秒）＝框代表的長度
  final double length;

  final double windowWidth;

  /// 一格縮圖的寬（照原片長寬比，太扁太瘦就夾住、多的裁掉）
  final double tileWidth;

  double get windowLeft => (width - windowWidth) / 2;

  /// 一秒幾個像素
  double get pps => length > 0 ? windowWidth / length : 1;

  /// 一格幾秒
  double get step => tileWidth / pps;

  int get tileCount => duration > 0 ? (duration / step).ceil() : 0;

  /// 原片第 [t] 秒在膠卷上的 x（框的左緣＝[start]）
  double xOf(double t, double start) => windowLeft + (t - start) * pps;

  /// 起點在 [start] 時看得到的格子
  List<int> visibleTiles(double start) {
    if (tileCount == 0) return const [];
    final from = (start - windowLeft / pps) / step;
    final to = (start + (width - windowLeft) / pps) / step;
    return [
      for (
        var k = math.max(0, from.floor());
        k <= math.min(tileCount - 1, to.floor());
        k++
      )
        k,
    ];
  }

  /// 第 [k] 格抽哪一秒：看得到的那一截的正中間（最後一格可能超出片尾）
  double tileTime(int k) {
    final a = k * step;
    final b = math.min(duration, (k + 1) * step);
    return (a + b) / 2;
  }

  /// 刻度間隔：相鄰兩條至少隔 10 像素；長刻度落在短刻度的整數倍上
  ({double minor, double? major}) get ticks {
    const nice = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0];
    final minor = nice.firstWhere((v) => v * pps >= 10, orElse: () => 120);
    double? major;
    for (final v in [...nice, 120.0, 300.0, 600.0]) {
      final n = v / minor;
      if (n >= 4 && (n - n.round()).abs() < 1e-6) {
        major = v;
        break;
      }
    }
    return (minor: minor, major: major);
  }
}

/// 換段的放大膠卷：框不動、膠卷在框底下滑。左右拖＝換段（手指往左＝
/// 換成後面那段，跟拖底片一樣）；拖的過程只回報 [onChanged]，放手才
/// 回報 [onEnd]——套用要重組合成，不能每一格都做
class SlipFilm extends StatefulWidget {
  const SlipFilm({
    super.key,
    required this.geometry,
    required this.start,
    required this.frameAt,
    required this.onChanged,
    required this.onEnd,
    this.playhead,
    this.showPlayhead = false,
  });

  /// 膠卷的高度
  static const double height = 64;

  final SlipFilmGeometry geometry;

  /// 框的起點（原片秒）
  final double start;

  /// 按時間取縮圖；null＝還沒載好（畫底色，不拿隔壁格冒充）
  final Uint8List? Function(double seconds) frameAt;

  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  /// 播放中的位置（原片秒）：框裡畫一條白線
  final ValueListenable<double>? playhead;
  final bool showPlayhead;

  @override
  State<SlipFilm> createState() => _SlipFilmState();
}

class _SlipFilmState extends State<SlipFilm> {
  /// 拖曳中累計的起點（同一格裡來好幾個事件、父層還沒重畫時才不會吃掉
  /// 位移）；夾在頭尾之間，撞到頭再往外拖，回頭時膠卷馬上就跟著動
  double? _raw;

  double get _maxStart => math.max(
    0.0,
    widget.geometry.duration - widget.geometry.length,
  );

  void _end() {
    if (_raw == null) return;
    _raw = null;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.geometry;
    final start = widget.start;
    final filmEnd = g.xOf(g.duration, start);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 膠卷黏著手指走：過拖曳門檻前那一小段也算（不然會差半個指頭）
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (_) => _raw = start,
      onHorizontalDragUpdate: (d) {
        final from = _raw ?? start;
        final next = (from - d.delta.dx / g.pps).clamp(0.0, _maxStart);
        _raw = next;
        if ((next - widget.start).abs() > 1e-9) widget.onChanged(next);
      },
      onHorizontalDragEnd: (_) => _end(),
      onHorizontalDragCancel: _end,
      child: SizedBox(
        height: g.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: kPanelHi)),
              for (final k in g.visibleTiles(start))
                _tile(g, k, start, filmEnd),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _Ticks(g, start)),
                ),
              ),
              // 框外壓暗：框裡那一截才是這段用到的
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: g.windowLeft,
                child: const _Shade(),
              ),
              Positioned(
                left: g.windowLeft + g.windowWidth,
                right: 0,
                top: 0,
                bottom: 0,
                child: const _Shade(),
              ),
              Positioned(
                left: g.windowLeft,
                top: 0,
                bottom: 0,
                width: g.windowWidth,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: kSelect, width: 2.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
              if (widget.showPlayhead && widget.playhead != null)
                ValueListenableBuilder<double>(
                  valueListenable: widget.playhead!,
                  builder: (context, t, _) {
                    final x = g.xOf(
                      t.clamp(start, start + g.length).toDouble(),
                      start,
                    );
                    return Positioned(
                      left: x - 1,
                      top: 0,
                      bottom: 0,
                      width: 2,
                      child: const IgnorePointer(
                        child: ColoredBox(color: kText),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(SlipFilmGeometry g, int k, double start, double filmEnd) {
    final left = g.xOf(k * g.step, start);
    // 多半個像素蓋住相鄰格的接縫；最後一格切在片尾
    final width = math.min(g.tileWidth + 0.5, filmEnd - left);
    final bytes = widget.frameAt(g.tileTime(k));
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: math.max(0.0, width),
      child: bytes == null
          ? const ColoredBox(color: kPanelHi)
          : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

/// 框外壓暗
class _Shade extends StatelessWidget {
  const _Shade();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
  );
}

/// 膠卷底邊的刻度：拖的時候畫面相近也看得出在動、動了多少
class _Ticks extends CustomPainter {
  _Ticks(this.g, this.start);

  final SlipFilmGeometry g;
  final double start;

  @override
  void paint(Canvas canvas, Size size) {
    final ticks = g.ticks;
    final minor = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 1;
    final from = math.max(0.0, start - g.windowLeft / g.pps);
    final to = math.min(g.duration, start + (g.width - g.windowLeft) / g.pps);
    for (
      var i = (from / ticks.minor).ceil();
      i * ticks.minor <= to + 1e-9;
      i++
    ) {
      final t = i * ticks.minor;
      final big = ticks.major != null && _onGrid(t, ticks.major!);
      final x = g.xOf(t, start).roundToDouble() + 0.5;
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x, size.height - (big ? 10 : 5)),
        big ? major : minor,
      );
    }
  }

  static bool _onGrid(double t, double every) {
    final n = t / every;
    return (n - n.round()).abs() < 1e-6;
  }

  @override
  bool shouldRepaint(_Ticks old) =>
      old.start != start ||
      old.g.width != g.width ||
      old.g.length != g.length ||
      old.g.duration != g.duration;
}
