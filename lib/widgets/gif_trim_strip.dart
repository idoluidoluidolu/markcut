import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/gif_strip.dart' show nearestLoaded;
import '../theme.dart';

/// GIF 頁的修剪條：縮圖帶＋起訖把手＋播放頭。
///
/// 把手只畫、不吃觸控（使用者指定：拉桿改成無法靠觸控拖曳，頭尾一律
/// 靠自己按起點終點）。之前三個熱區疊在 Stack 裡互搶手勢，範圍縮到
/// 零點幾秒就整個卡死；現在整條上的每一次觸碰都是同一件事——移動
/// 播放頭。點哪跳哪、拖到哪跟到哪。
///
/// 播放頭不受起訖點限制（使用者指定：整條都可以自由移動），
/// 可以停在選取範圍外面；範圍外要看什麼由呼叫端決定
class GifTrimStrip extends StatelessWidget {
  const GifTrimStrip({
    super.key,
    required this.dur,
    required this.start,
    required this.end,
    required this.pos,
    required this.cells,
    required this.onTapAt,
    required this.onScrubStart,
    required this.onScrubBy,
    required this.onScrubEnd,
  });

  /// 琥珀直條的寬度。起點直條貼在範圍內緣 [xs, xs+13]、終點在
  /// [xe-13, xe]，跟編輯器片段的內側雙把手同一個位置關係
  static const double barWidth = 13;

  /// 整條的高度（縮圖也抽這個高度）
  static const double stripHeight = 56;

  final double dur;
  final double start;
  final double end;

  /// 播放頭位置（秒）。只有這一根細線會重畫，整條不用跟著 setState
  final ValueListenable<double> pos;

  /// 縮圖帶的格子（還沒抽到的是 null，畫的時候借最近一格）
  final List<Uint8List?> cells;

  /// 點一下：播放頭跳到這一秒
  final void Function(double t) onTapAt;

  /// 拖曳起手：播放頭先跳到手指下面這一秒，之後跟著走
  final void Function(double t) onScrubStart;

  /// 拖曳中的位移，已經換算成秒（整條寬度＝整支影片）
  final void Function(double dt) onScrubBy;

  final VoidCallback onScrubEnd;

  double _xOf(double t, double w) => dur <= 0 ? 0 : w * (t / dur);

  double _tOf(double x, double w) => w <= 0 ? 0 : (x / w * dur).clamp(0.0, dur);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: stripHeight,
      child: LayoutBuilder(
        builder: (context, cons) {
          final w = cons.maxWidth;
          final xs = _xOf(start, w);
          final xe = _xOf(end, w);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _cellsRow(),
                ),
              ),
              // 範圍外壓暗
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: xs,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.62)),
              ),
              Positioned(
                left: xe,
                top: 0,
                bottom: 0,
                right: 0,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.62)),
              ),
              // 選取範圍的上下框線
              Positioned(
                left: xs,
                width: math.max(0, xe - xs),
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                      horizontal: BorderSide(color: kSelect, width: 2),
                    ),
                  ),
                ),
              ),
              _handleBar(x: xs, left: true),
              _handleBar(x: xe, left: false),
              // 播放頭：純白 2px 細線，長相跟影片編輯區時間軸的一致。
              // 畫在把手「之後」＝壓在最上面：停在段落起點時它剛好
              // 疊在左把手上，畫在底下就整根被蓋住（使用者回報：
              // 看不到指針、不知道播到哪）
              ValueListenableBuilder<double>(
                valueListenable: pos,
                builder: (context, t, _) => Positioned(
                  left: _xOf(t.clamp(0.0, dur), w) - 1,
                  top: -2,
                  bottom: -2,
                  width: 2,
                  child: const ColoredBox(color: kText),
                ),
              ),
              // 手勢層蓋在最上面：整條的觸控一律是播放頭，把手接不到
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => onTapAt(_tOf(d.localPosition.dx, w)),
                  onHorizontalDragStart: (d) =>
                      onScrubStart(_tOf(d.localPosition.dx, w)),
                  onHorizontalDragUpdate: (d) =>
                      onScrubBy(w <= 0 ? 0 : d.delta.dx / w * dur),
                  onHorizontalDragEnd: (_) => onScrubEnd(),
                  onHorizontalDragCancel: onScrubEnd,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 縮圖帶的格子：抽到的畫自己，還沒到的先借最近一格（整條很快就有
  /// 輪廓，細節之後一格一格補上）；一格都沒有先用底色
  Widget _cellsRow() {
    if (cells.every((c) => c == null)) {
      return const ColoredBox(color: kPanelHi);
    }
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            child: Image.memory(
              nearestLoaded(cells, i)!,
              fit: BoxFit.cover,
              height: stripHeight,
              gaplessPlayback: true,
            ),
          ),
      ],
    );
  }

  /// 把手的長相：13px 琥珀色直條，貼在選取範圍的內緣（跟編輯器選取
  /// 片段的內側雙把手同一個位置關係；使用者回報：修剪條要跟編輯器的
  /// 軌道素材同一套長相）。只畫，不吃觸控
  Widget _handleBar({required double x, required bool left}) => Positioned(
    left: left ? x : x - barWidth,
    top: 0,
    bottom: 0,
    width: barWidth,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: kSelect,
        borderRadius: BorderRadius.horizontal(
          left: left ? const Radius.circular(4) : Radius.zero,
          right: left ? Radius.zero : const Radius.circular(4),
        ),
      ),
    ),
  );
}
