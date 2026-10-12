import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../services/gif_strip.dart' show nearestLoaded;
import '../theme.dart';

/// 修剪條上被抓住的是哪一根竿子
enum TrimEdge { start, end }

/// GIF 頁的修剪條：縮圖帶＋起訖竿子＋播放頭。
///
/// 竿子能不能用手拖看呼叫端有沒有接 [GifTrimStrip.onEdgeStart]：
/// - GIF 頁有接（使用者 10-12 定案：引導使用者拖左右竿子設起點終點）：
///   手指落在竿子左右 [GifTrimStrip.edgeHitWidth] 內就是抓竿子，其他地方
///   照舊是播放頭。兩根貼在一起（都在範圍內）時先不決定，看手往哪邊走：
///   往左＝起點、往右＝終點——以前三個熱區疊在 Stack 裡互搶，範圍縮到
///   零點幾秒兩根就黏死（使用者回報「拉近就再也拉不開」），這樣判就
///   永遠拉得開。
/// - 音樂挑選頁沒接：竿子只畫、不吃觸控（使用者當初指定的「頭尾一律
///   靠自己按」），整條上的每一次觸碰都是播放頭。
///
/// 播放頭不受起訖點限制（使用者指定：整條都可以自由移動），
/// 可以停在選取範圍外面；範圍外要看什麼由呼叫端決定
class GifTrimStrip extends StatefulWidget {
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
    this.onEdgeStart,
    this.onEdgeMove,
    this.onEdgeEnd,
    this.hint = false,
  });

  /// 起訖標記的寬度：各一條 2px 琥珀細線，正好壓在起點／終點那一秒上
  ///（使用者指定：「框框不要這麼粗，細細一個判斷這裡是起點跟終點就好，
  /// 不然時間太緊密整個擠在一起」——以前是 13px 的把手加上下框線，
  /// 範圍一短兩個把手就黏成一塊）。可以拖了也不加圓點（使用者指定：
  /// 竿子不用有下面那個圓圈），抓的範圍靠 [edgeHitWidth]
  static const double barWidth = 2;

  /// 手指落在竿子左右這麼多 px 內就算抓到竿子（線本身只有 2px）
  static const double edgeHitWidth = 22;

  /// 整條的高度（縮圖也抽這個高度）
  static const double stripHeight = 56;

  /// 還沒設過起訖點時蓋在縮圖帶上的引導（使用者定案戊案的字）
  static const String hintText = '拖兩邊的竿子選取範圍';

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

  /// 抓到竿子：[edge] 是哪一根、[t] 是手指按下去那一秒（手指不一定
  /// 剛好壓在線上，呼叫端拿它跟竿子的差，拖的時候竿子才不會跳）。
  /// 沒接＝竿子不吃觸控
  final void Function(TrimEdge edge, double t)? onEdgeStart;

  /// 拖竿子中：手指現在在第幾秒（沒夾在影片範圍內，夾由呼叫端做——
  /// 手指抓偏一點時竿子才拉得到頭尾）
  final void Function(double t)? onEdgeMove;

  final VoidCallback? onEdgeEnd;

  /// 縮圖帶整條壓暗、中間寫 [hintText]。只畫、不吃觸控，什麼時候
  /// 收掉由呼叫端決定
  final bool hint;

  @override
  State<GifTrimStrip> createState() => _GifTrimStripState();
}

/// 這一次拖曳在動什麼：播放頭／兩根貼在一起還沒決定／竿子
enum _Grab { none, scrub, pending, edge }

class _GifTrimStripState extends State<GifTrimStrip> {
  _Grab _grab = _Grab.none;

  /// 兩根貼在一起時手指按下去那一秒（決定是哪一根之後才交出去）
  double _downT = 0;

  double _xOf(double t, double w) => widget.dur <= 0 ? 0 : w * (t / widget.dur);

  double _rawT(double x, double w) => w <= 0 ? 0 : x / w * widget.dur;

  double _tOf(double x, double w) => _rawT(x, w).clamp(0.0, widget.dur);

  void _dragStart(DragStartDetails d, double w) {
    final x = d.localPosition.dx;
    if (widget.onEdgeStart != null) {
      const hit = GifTrimStrip.edgeHitWidth;
      final ds = (x - _xOf(widget.start, w)).abs();
      final de = (x - _xOf(widget.end, w)).abs();
      if (ds <= hit && de <= hit) {
        _grab = _Grab.pending;
        _downT = _rawT(x, w);
        return;
      }
      if (ds <= hit || de <= hit) {
        _grab = _Grab.edge;
        widget.onEdgeStart!(
          ds <= hit ? TrimEdge.start : TrimEdge.end,
          _rawT(x, w),
        );
        return;
      }
    }
    _grab = _Grab.scrub;
    widget.onScrubStart(_tOf(x, w));
  }

  void _dragUpdate(DragUpdateDetails d, double w) {
    switch (_grab) {
      case _Grab.pending:
        if (d.delta.dx == 0) return;
        _grab = _Grab.edge;
        widget.onEdgeStart!(
          d.delta.dx < 0 ? TrimEdge.start : TrimEdge.end,
          _downT,
        );
        widget.onEdgeMove?.call(_rawT(d.localPosition.dx, w));
      case _Grab.edge:
        widget.onEdgeMove?.call(_rawT(d.localPosition.dx, w));
      case _Grab.scrub:
        widget.onScrubBy(w <= 0 ? 0 : d.delta.dx / w * widget.dur);
      case _Grab.none:
        break;
    }
  }

  void _dragEnd() {
    final g = _grab;
    _grab = _Grab.none;
    if (g == _Grab.edge) widget.onEdgeEnd?.call();
    if (g == _Grab.scrub) widget.onScrubEnd();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: GifTrimStrip.stripHeight,
      child: LayoutBuilder(
        builder: (context, cons) {
          final w = cons.maxWidth;
          final xs = _xOf(widget.start, w);
          final xe = _xOf(widget.end, w);
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
              if (widget.hint) Positioned.fill(child: _hint()),
              // 起訖各一條細線；範圍本身靠外側壓暗來看。畫在引導上面：
              // 引導叫人拖的就是它們
              _mark(xs),
              _mark(xe),
              // 播放頭：純白 2px 細線，長相跟影片編輯區時間軸的一致。
              // 畫在竿子「之後」＝壓在最上面：停在段落起點時它剛好
              // 疊在左竿子上，畫在底下就整根被蓋住（使用者回報：
              // 看不到指針、不知道播到哪）
              ValueListenableBuilder<double>(
                valueListenable: widget.pos,
                builder: (context, t, _) => Positioned(
                  left: _xOf(t.clamp(0.0, widget.dur), w) - 1,
                  top: -2,
                  bottom: -2,
                  width: 2,
                  child: const ColoredBox(color: kText),
                ),
              ),
              // 手勢層蓋在最上面：竿子附近＝拖竿子（有接的話），其他
              // 地方＝播放頭。按下去那一點就要知道落在哪，所以從
              // 按下的位置起算（down），不是過了拖曳門檻那一點
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onTapDown: (d) => widget.onTapAt(_tOf(d.localPosition.dx, w)),
                  onHorizontalDragStart: (d) => _dragStart(d, w),
                  onHorizontalDragUpdate: (d) => _dragUpdate(d, w),
                  onHorizontalDragEnd: (_) => _dragEnd(),
                  onHorizontalDragCancel: _dragEnd,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 引導：整條壓暗、兩頭箭頭指向竿子、中間一行字。字放不下就縮
  ///（窄螢幕、系統大字）
  Widget _hint() => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: kBg.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(Icons.chevron_left_rounded, size: 20, color: Colors.white),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  GifTrimStrip.hintText,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: Colors.white),
          ],
        ),
      ),
    ),
  );

  /// 縮圖帶的格子：抽到的畫自己，還沒到的先借最近一格（整條很快就有
  /// 輪廓，細節之後一格一格補上）；一格都沒有先用底色
  Widget _cellsRow() {
    final cells = widget.cells;
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
              height: GifTrimStrip.stripHeight,
              gaplessPlayback: true,
            ),
          ),
      ],
    );
  }

  /// 起訖標記：2px 琥珀細線，中心壓在那一秒的 x 上。觸控由手勢層判
  Widget _mark(double x) => Positioned(
    left: x - GifTrimStrip.barWidth / 2,
    top: 0,
    bottom: 0,
    width: GifTrimStrip.barWidth,
    child: const ColoredBox(color: kSelect),
  );
}
