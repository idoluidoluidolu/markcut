import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/waveform_cache.dart';
import '../theme.dart';

// 黑白暗版：片段配色全灰階（影片、音訊各一階）
const kVideoBorder = Color(0xFF6E6E78);
const kVideoFill = Color(0xFF2C2C33);
const kAudioFill = Color(0xFF25252C);
const kAudioBorder = Color(0xFF8A8A94);

/// 拖曳中的片段狀態：拿起來之後，資料完全不動，
/// 位置變化只發生在這個「幽靈」身上，放開才一次寫回。
typedef _Lift = ({
  int clipId,
  double startOffset,
  int startTrack,
  double dx, // 像素
  double dy,
});

/// 通用圖層時間軸：軌道不分影片或音訊，任何素材都能放在任何一軌。
/// track 0 是最上層——畫面以最上層的影片為準，聲音則是全部混音。
class TimelineEditor extends StatefulWidget {
  final TimelineModel timeline;
  final Map<int, List<Uint8List>> thumbs; // sourceIndex → filmstrip
  final int selectedId; // -1 = 沒選
  /// 播放頭位置（ValueNotifier 驅動：播放中只重繪播放頭那條線）
  final ValueListenable<double> playhead;
  final double pxPerSec;
  final double trackScale;
  final ScrollController scrollController;

  final ValueChanged<int> onSelect;
  final ValueChanged<double> onSeek;
  final void Function(int id, double deltaSec, bool fromLeft) onTrim;
  final VoidCallback? onTrimStart; // 修剪開始（拿來拍復原快照）

  /// 放開片段：一次帶回新位置與軌道。insert=true 代表插成新的一層。
  final void Function(int id, double newOffset, int track, bool insert) onDrop;
  final ValueChanged<int> onAddMedia; // 在這一軌加素材
  final void Function(int from, int to) onReorderTrack; // 整條軌道換順序
  final Set<int> mutedTracks; // 靜音的軌道
  final ValueChanged<int> onToggleMute; // 點標籤喇叭切換整軌靜音

  /// 預備好的旁白軌：這一軌的標籤變成紅色錄音鈕
  final int? voiceTrack;

  /// 正在錄旁白（鈕變成停止）
  final bool voiceRecording;

  /// 按下紅鈕：開始／停止錄旁白
  final VoidCallback? onVoiceRecordTap;

  /// 開始錄音的時間軸位置（錄音中的紅色波形從這裡往右長）
  final double voiceStart;

  /// 錄音中的即時音量取樣（0~1）
  final ValueListenable<List<double>>? voiceLevels;
  final void Function(int id, Offset globalPos) onLongPressClip; // 長按選單
  /// 點一下「已經選取」的片段（例如文字片段點兩下進編輯）
  final ValueChanged<int>? onTapSelectedClip;

  /// 長按軌道空白處（貼上用）：軌道、該處的時間、選單位置
  final void Function(int track, double timeSec, Offset globalPos)
  onLongPressEmpty;

  /// 片段拖曳開始/結束（拖曳期間父層要暫停「捲動＝移動播放頭」的同步）
  final ValueChanged<bool>? onLiftChanged;

  /// 外層偵測到的雙指縮放狀態：true 時鎖住橫向捲動
  final bool pinching;

  /// 雙指縮放時間軸：回傳新的 pxPerSec（父層負責 clamp 後重繪與對位）
  final ValueChanged<double>? onZoom;

  // 浮水印軌（有設定浮水印時才出現，固定在最上面）
  final ({double start, double end})? watermark;
  final String wmLabel; // 顯示在浮水印塊上的內容（例如浮水印文字）
  final bool wmSelected;

  /// 預覽時暫時藏起浮水印（只影響預覽，匯出照樣有）
  final bool wmHidden;
  final VoidCallback? onToggleWmVisible;
  final VoidCallback onSelectWm;
  final ValueChanged<double> onMoveWm; // 新的起點
  final void Function(double deltaSec, bool fromLeft) onTrimWm;

  const TimelineEditor({
    super.key,
    required this.timeline,
    required this.thumbs,
    required this.selectedId,
    required this.playhead,
    required this.pxPerSec,
    required this.scrollController,
    required this.onSelect,
    required this.onSeek,
    required this.onTrim,
    this.onTrimStart,
    required this.onDrop,
    required this.onAddMedia,
    required this.onReorderTrack,
    this.mutedTracks = const {},
    required this.onToggleMute,
    this.voiceTrack,
    this.voiceRecording = false,
    this.onVoiceRecordTap,
    this.voiceStart = 0,
    this.voiceLevels,
    required this.onLongPressClip,
    required this.onLongPressEmpty,
    this.onTapSelectedClip,
    this.onLiftChanged,
    this.pinching = false,
    this.onZoom,
    this.watermark,
    this.wmLabel = '浮水印',
    this.wmSelected = false,
    this.wmHidden = false,
    this.onToggleWmVisible,
    required this.onSelectWm,
    required this.onMoveWm,
    required this.onTrimWm,
    this.trackScale = 1.0,
  });

  static const double rulerH = 22;
  static const double labelW = 46;
  static const double gap = 4;
  static const double wmH = 24;

  @override
  State<TimelineEditor> createState() => _TimelineEditorState();
}

class _TimelineEditorState extends State<TimelineEditor> {
  _Lift? _lift; // 拿起來的片段
  int? _dragTrack; // 正在拖曳的軌道（標籤）
  double _dragDy = 0;

  Timer? _autoScrollTimer;
  double _autoScrollSpeed = 0;

  // 雙指捏合縮放由外層（編輯器分頁）偵測，範圍才能涵蓋整個分頁的空白處；
  // 這裡只需要知道「正在捏合」好鎖住捲動
  bool get _pinching => widget.pinching;

  // 長按偵測：按住不動 0.45 秒 → 取消拖曳、打開選單
  Timer? _pressTimer;
  Offset _pressPos = Offset.zero;
  bool _liftWasSelected = false; // 按下時片段是否本來就選取（點兩下編輯用）

  TimelineModel get timeline => widget.timeline;
  double get pxPerSec => widget.pxPerSec;
  double get trackH => 54 * widget.trackScale;
  double get rowStride => trackH + TimelineEditor.gap;

  /// 畫出來的軌數：有內容的 + 一條永遠留著的空軌
  // 永遠多一列空軌可放東西；預備中的旁白軌也要有位置顯示
  int get _rows =>
      math.max(timeline.usedTracks + 1, (widget.voiceTrack ?? -1) + 1);

  /// 浮水印軌佔掉的高度（含間距）
  double get _wmExtra =>
      widget.watermark == null ? 0 : TimelineEditor.wmH + TimelineEditor.gap;

  /// 刻度尺和軌道之間的間距（比一般 gap 大，讓版面透氣）
  static const double _rulerGap = 10;

  double get totalHeight =>
      TimelineEditor.rulerH + _rulerGap + _wmExtra + _rows * rowStride + 4;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _pressTimer?.cancel();
    super.dispose();
  }

  TimelineClip? _clipById(int id) {
    for (final c in timeline.clips) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ===== 拿起 / 移動 / 放下 =====

  void _liftStart(TimelineClip c, Offset globalPos) {
    _liftWasSelected = widget.selectedId == c.id;
    widget.onSelect(c.id);
    widget.onLiftChanged?.call(true);
    setState(() {
      _lift = (
        clipId: c.id,
        startOffset: c.offset,
        startTrack: c.track,
        dx: 0,
        dy: 0,
      );
    });
    // 按住不動一小段時間 → 開長按選單（取消拖曳）
    _pressPos = globalPos;
    _pressTimer?.cancel();
    _pressTimer = Timer(const Duration(milliseconds: 450), () {
      final l = _lift;
      if (l != null && l.dx.abs() < 6 && l.dy.abs() < 6) {
        setState(() => _lift = null);
        _stopAutoScroll();
        widget.onLiftChanged?.call(false);
        widget.onLongPressClip(c.id, _pressPos);
      }
    });
  }

  void _liftUpdate(double ddx, double ddy, Offset globalPos) {
    final l = _lift;
    if (l == null) return;
    if ((l.dx + ddx).abs() > 6 || (l.dy + ddy).abs() > 6) {
      _pressTimer?.cancel();
    }
    final minDy = -(l.startTrack + 0.45) * rowStride;
    final maxDy = (timeline.usedTracks - l.startTrack + 0.45) * rowStride;
    setState(() {
      _lift = (
        clipId: l.clipId,
        startOffset: l.startOffset,
        startTrack: l.startTrack,
        dx: l.dx + ddx,
        dy: (l.dy + ddy).clamp(minDy, maxDy),
      );
    });
    _updateAutoScroll(globalPos);
  }

  void _liftEnd() {
    _pressTimer?.cancel();
    final spec = _liftSpec();
    final l = _lift;
    if (l == null) return; // 長按選單已經接手
    setState(() => _lift = null);
    _stopAutoScroll();
    widget.onLiftChanged?.call(false);
    // 幾乎沒動 = 點擊；點已選取的片段 → 交給編輯回呼
    if (l.dx.abs() < 6 && l.dy.abs() < 6) {
      if (_liftWasSelected) widget.onTapSelectedClip?.call(l.clipId);
      return;
    }
    if (spec == null) return;
    widget.onDrop(l.clipId, spec.offset, spec.track, spec.insert);
  }

  /// 幽靈目前的落點：位置（含吸附）、軌道、是否插新層。
  /// 判定原則：壓到別的片段才疊，貼近交界且會撞才變成插入。
  ({double offset, int track, bool insert, int? insertLine})? _liftSpec() {
    final l = _lift;
    if (l == null) return null;
    final clip = _clipById(l.clipId);
    if (clip == null) return null;

    final want = l.startOffset + l.dx / pxPerSec;
    final offset = timeline.snapOffset(
      clip,
      want,
      widget.playhead.value,
      pxPerSec,
    );
    final len = clip.length;

    bool collide(int track) => timeline.clips.any(
      (c) =>
          c.id != clip.id &&
          c.track == track &&
          c.offset < offset + len &&
          c.end > offset,
    );

    final maxTrack = timeline.usedTracks; // 最底下的空軌
    // 垂直沒怎麼動 → 留在原軌，只移位置
    if (l.dy.abs() < rowStride * 0.4) {
      return (
        offset: offset,
        track: l.startTrack,
        insert: false,
        insertLine: null,
      );
    }
    final raw = (l.startTrack * rowStride + l.dy) / rowStride;
    final nearest = raw.round().clamp(0, maxTrack);
    final frac = raw - raw.round();
    // 大部分範圍都是「放進這一層」；貼近交界且會撞到才是插入
    if (frac.abs() <= 0.42 || !collide(nearest)) {
      return (offset: offset, track: nearest, insert: false, insertLine: null);
    }
    final at = (frac < 0 ? raw.round() : raw.round() + 1).clamp(0, maxTrack);
    return (offset: offset, track: at, insert: true, insertLine: at);
  }

  // ===== 邊緣自動捲動 =====

  void _updateAutoScroll(Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPos);
    const edge = 48.0;
    final leftBound = TimelineEditor.labelW + edge;
    final rightBound = box.size.width - edge;
    var speed = 0.0;
    if (local.dx < leftBound) {
      speed = -((leftBound - local.dx) / edge).clamp(0.0, 1.0) * 14;
    } else if (local.dx > rightBound) {
      speed = ((local.dx - rightBound) / edge).clamp(0.0, 1.0) * 14;
    }
    _autoScrollSpeed = speed;
    if (speed == 0) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
    } else {
      _autoScrollTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _stepAutoScroll(),
      );
    }
  }

  void _stepAutoScroll() {
    final sc = widget.scrollController;
    final l = _lift;
    if (!sc.hasClients || _autoScrollSpeed == 0 || l == null) return;
    final pos = sc.position;
    final next = (pos.pixels + _autoScrollSpeed).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    var moved = next - pos.pixels;
    if (moved != 0) sc.jumpTo(next);
    // 往右捲到底時幽靈還是要前進（內容會加寬，下一幀就捲得動）
    if (moved == 0 && _autoScrollSpeed > 0) moved = _autoScrollSpeed;
    if (moved == 0) return;
    setState(() {
      _lift = (
        clipId: l.clipId,
        startOffset: l.startOffset,
        startTrack: l.startTrack,
        dx: l.dx + moved,
        dy: l.dy,
      );
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollSpeed = 0;
  }

  // ===== 軌道整條換順序（左側標籤拖曳）=====

  int get _trackDropTarget {
    if (_dragTrack == null) return -1;
    final steps = (_dragDy / rowStride).round();
    return (_dragTrack! + steps).clamp(0, timeline.usedTracks - 1);
  }

  double _rowShiftFor(int t) {
    // 片段插入的預覽：插入點以下全部讓位
    final spec = _liftSpec();
    if (spec?.insertLine != null) {
      return t >= spec!.insertLine! ? rowStride : 0;
    }
    // 軌道標籤拖曳
    final from = _dragTrack;
    if (from == null) return 0;
    if (t == from) return _dragDy;
    final to = _trackDropTarget;
    if (from < to && t > from && t <= to) return -rowStride;
    if (to < from && t >= to && t < from) return rowStride;
    return 0;
  }

  Widget _shifted(int t, Widget child) {
    final dy = _rowShiftFor(t);
    if (_dragTrack == t) {
      return Transform.translate(offset: Offset(0, dy), child: child);
    }
    return AnimatedSlide(
      offset: Offset(0, dy / trackH),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: child,
    );
  }

  // ===== 畫面 =====

  @override
  Widget build(BuildContext context) {
    const gap = TimelineEditor.gap;
    const rulerH = TimelineEditor.rulerH;
    final spec = _liftSpec();

    return SizedBox(
      height: totalHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左側軌道標籤（固定不捲動；可上下拖曳換整條軌道的順序）
          SizedBox(
            width: TimelineEditor.labelW,
            child: Column(
              children: [
                const SizedBox(height: rulerH + _rulerGap),
                if (widget.watermark != null) ...[
                  _wmLabel(),
                  const SizedBox(height: gap),
                ],
                for (var t = 0; t < _rows; t++) ...[
                  _shifted(t, _trackLabel(t)),
                  const SizedBox(height: gap),
                ],
              ],
            ),
          ),
          // 可捲動的軌道區。播放頭固定在畫面上，捲動內容＝移動播放位置，
          // 所以內容前面要留「前導空白」讓時間 0 能對齊播放頭。
          Expanded(
            child: LayoutBuilder(
              builder: (context, cons) {
                final leadPad = cons.maxWidth * 0.35;
                final totalW =
                    timeline.duration * pxPerSec + cons.maxWidth * 0.7;
                return SingleChildScrollView(
                  controller: widget.scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: _pinching
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  // 桌面：滾輪＝縮放時間軸（在內層搶先註冊，蓋掉捲動的滾輪行為）
                  child: Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent && widget.onZoom != null) {
                        GestureBinding.instance.pointerSignalResolver.register(
                          e,
                          (event) {
                            final dy =
                                (event as PointerScrollEvent).scrollDelta.dy;
                            widget.onZoom!(pxPerSec * math.exp(-dy * 0.002));
                          },
                        );
                      }
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: leadPad),
                        SizedBox(
                          width: totalW,
                          child: Stack(
                            children: [
                              // RepaintBoundary：縮圖/波形/刻度是重內容，
                              // 隔進自己的圖層——播放頭線每格重繪時
                              // 才不會拖著整條時間軸一起重新光柵化（手機卡爆主因）
                              RepaintBoundary(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // 時間刻度尺（可點、可拖播放頭）
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTapDown: (d) => widget.onSeek(
                                        d.localPosition.dx / pxPerSec,
                                      ),
                                      onHorizontalDragUpdate: (d) =>
                                          widget.onSeek(
                                            d.localPosition.dx / pxPerSec,
                                          ),
                                      child: CustomPaint(
                                        size: Size(totalW, rulerH),
                                        painter: _RulerPainter(
                                          pxPerSec: pxPerSec,
                                          color: kTextDim.withValues(
                                            alpha: 0.7,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // 刻度尺和軌道之間留口氣（CapCut 版型）
                                    const SizedBox(height: _rulerGap),
                                    if (widget.watermark != null) ...[
                                      SizedBox(
                                        height: TimelineEditor.wmH,
                                        width: totalW,
                                        child: _wmRow(),
                                      ),
                                      const SizedBox(height: gap),
                                    ],
                                    for (var t = 0; t < _rows; t++) ...[
                                      _shifted(
                                        t,
                                        SizedBox(
                                          height: trackH,
                                          width: totalW,
                                          child: _trackRow(t, spec),
                                        ),
                                      ),
                                      const SizedBox(height: gap),
                                    ],
                                  ],
                                ),
                              ),
                              // 插入線
                              if (spec?.insertLine != null)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top:
                                      rulerH +
                                      _rulerGap +
                                      _wmExtra +
                                      spec!.insertLine! * rowStride -
                                      gap / 2 -
                                      1.5,
                                  child: IgnorePointer(
                                    child: Container(
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color: kSelect,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              // 幽靈：拖曳中的片段，自由跟著手指
                              if (_lift != null && spec != null) _ghost(spec),
                              // 拖曳浮水印範圍時的即時外框由 _wmRow 自己畫
                              // 播放頭：一條直線（只有它隨播放位置重繪）
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: ValueListenableBuilder<double>(
                                    valueListenable: widget.playhead,
                                    builder: (context, pos, _) => Stack(
                                      children: [
                                        Positioned(
                                          left: pos * pxPerSec - 1,
                                          top: 0,
                                          bottom: 0,
                                          child: Container(
                                            width: 2,
                                            color: kText,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _trackRow(
    int track,
    ({double offset, int track, bool insert, int? insertLine})? spec,
  ) {
    final isEmptyRow = track >= timeline.usedTracks;
    final clips = timeline.onTrack(track);
    final isDropTarget = spec != null && !spec.insert && spec.track == track;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 點空白處＝取消所有選取
            onTap: () => widget.onSelect(-1),
            onLongPressStart: (d) => widget.onLongPressEmpty(
              track,
              (d.localPosition.dx / pxPerSec).clamp(0.0, 1e6),
              d.globalPosition,
            ),
            // CapCut 式：整條灰底橫帶，不描邊；拖放目標才亮框
            child: Container(
              decoration: BoxDecoration(
                color: isDropTarget
                    ? kSelect.withValues(alpha: 0.10)
                    : kPanelHi.withValues(alpha: isEmptyRow ? 0.4 : 0.8),
                borderRadius: BorderRadius.circular(3),
                border: isDropTarget
                    ? Border.all(color: kSelect, width: 2)
                    : null,
              ),
            ),
          ),
        ),
        for (final c in clips)
          _ClipBlock(
            key: ValueKey('clip${c.id}'),
            clip: c,
            source: timeline.sourceOf(c),
            filmstrip: widget.thumbs[c.sourceIndex] ?? const [],
            isSelected: c.id == widget.selectedId,
            lifted: _lift?.clipId == c.id,
            pxPerSec: pxPerSec,
            height: trackH,
            onSelect: widget.onSelect,
            onTrim: widget.onTrim,
            onTrimStart: widget.onTrimStart,
            onLiftStart: (pos) => _liftStart(c, pos),
            onLiftUpdate: _liftUpdate,
            onLiftEnd: _liftEnd,
          ),
        // 錄音中：從起錄點往右長的紅色即時波形，長度跟著播放頭
        if (widget.voiceRecording && widget.voiceTrack == track)
          Positioned(
            left: widget.voiceStart * pxPerSec,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: ValueListenableBuilder<double>(
                valueListenable: widget.playhead,
                builder: (context, pos, child) => SizedBox(
                  width: ((pos - widget.voiceStart) * pxPerSec).clamp(3.0, 1e6),
                  child: child,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kRecord.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: kRecord, width: 1.5),
                  ),
                  child: ValueListenableBuilder<List<double>>(
                    valueListenable: widget.voiceLevels ?? _emptyLevels,
                    builder: (context, levels, _) => CustomPaint(
                      size: Size.infinite,
                      painter: _WavePainter(
                        peaks: levels,
                        color: kRecord,
                        live: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 浮水印軌的左側標籤：點一下切換預覽時要不要顯示浮水印
  Widget _wmLabel() {
    final hidden = widget.wmHidden;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleWmVisible,
      child: Container(
        height: TimelineEditor.wmH,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: widget.wmSelected ? kSelect : kBorder,
            width: widget.wmSelected ? 1.5 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          hidden ? Icons.visibility_off_outlined : Icons.branding_watermark,
          size: 11,
          color: hidden ? kTextDim : (widget.wmSelected ? kSelect : kTextDim),
        ),
      ),
    );
  }

  /// 浮水印軌：整塊可左右拖曳、可修剪範圍的琥珀色塊
  Widget _wmRow() {
    final wm = widget.watermark!;
    final w = ((wm.end - wm.start) * pxPerSec).clamp(20.0, double.infinity);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: kPanelHi.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        Positioned(
          left: wm.start * pxPerSec,
          top: 0,
          bottom: 0,
          child: RawGestureDetector(
            gestures: {
              _EagerPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                    () => _EagerPanRecognizer(),
                    (r) => r
                      ..onStart = ((_) => widget.onSelectWm())
                      ..onUpdate = ((d) =>
                          widget.onMoveWm(wm.start + d.delta.dx / pxPerSec)),
                  ),
            },
            child: GestureDetector(
              onTap: widget.onSelectWm,
              child: Container(
                width: w.toDouble(),
                // 灰階退場：琥珀只留給「選取」一個意義。
                // 選中這條軌時才亮起來
                decoration: BoxDecoration(
                  color: widget.wmSelected
                      ? kSelect.withValues(alpha: 0.22)
                      : kPanelHi,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: widget.wmSelected ? kSelect : Color(0xFF3A3A42),
                    width: widget.wmSelected ? 1.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.branding_watermark,
                            size: 10,
                            color: widget.wmSelected ? kSelect : kIcon,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              widget.wmLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                color: widget.wmSelected ? kSelect : kIcon,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.wmSelected) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _TrimHandle(
                          isLeft: true,
                          onDrag: (dxSec) => widget.onTrimWm(dxSec, true),
                          pxPerSec: pxPerSec,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _TrimHandle(
                          isLeft: false,
                          onDrag: (dxSec) => widget.onTrimWm(dxSec, false),
                          pxPerSec: pxPerSec,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 拖曳中的幽靈片段
  Widget _ghost(
    ({double offset, int track, bool insert, int? insertLine}) spec,
  ) {
    final l = _lift!;
    final clip = _clipById(l.clipId);
    if (clip == null) return const SizedBox.shrink();
    final src = timeline.sourceOf(clip);
    final w = (clip.length * pxPerSec).clamp(22.0, double.infinity).toDouble();
    return Positioned(
      left: spec.offset * pxPerSec,
      top:
          TimelineEditor.rulerH +
          _rulerGap +
          _wmExtra +
          l.startTrack * rowStride +
          l.dy,
      child: IgnorePointer(
        child: Container(
          width: w,
          height: trackH,
          decoration: BoxDecoration(
            color: (src.isVideo ? kVideoFill : kAudioFill).withValues(
              alpha: 0.92,
            ),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: kSelect, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _clipFill(clip, src, widget.thumbs[clip.sourceIndex] ?? const []),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    spec.insert ? '插入成新的一層' : '第 ${spec.track + 1} 層',
                    style: const TextStyle(
                      fontSize: 10,
                      color: kSelect,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trackLabel(int t) {
    final isEmptyRow = t >= timeline.usedTracks;
    final isVoice = widget.voiceTrack == t;
    return _TrackLabel(
      index: t,
      height: trackH,
      rowStride: rowStride,
      canDrag: !isEmptyRow && timeline.usedTracks > 1 && !isVoice,
      isEmptyRow: isEmptyRow,
      muted: widget.mutedTracks.contains(t),
      isVoice: isVoice,
      isRecording: isVoice && widget.voiceRecording,
      // 選中的片段在這一軌 → 左邊標籤亮起來
      hasSelection: timeline.clips.any(
        (c) => c.id == widget.selectedId && c.track == t,
      ),
      isDragging: _dragTrack == t,
      dragDy: _dragTrack == t ? _dragDy : 0,
      maxTrack: timeline.usedTracks - 1,
      // 旁白軌＝錄音鈕；空軌點了加素材；有內容的軌切換整軌靜音
      onTap: () => isVoice
          ? widget.onVoiceRecordTap?.call()
          : (isEmptyRow ? widget.onAddMedia(t) : widget.onToggleMute(t)),
      onDragUpdate: (dy) => setState(() {
        _dragTrack = t;
        _dragDy = dy;
      }),
      onDragEnd: () {
        final to = _trackDropTarget;
        final from = _dragTrack;
        setState(() {
          _dragTrack = null;
          _dragDy = 0;
        });
        if (from != null && to >= 0 && to != from) {
          widget.onReorderTrack(from, to);
        }
      },
    );
  }
}

/// voiceLevels 沒給時的替身，省去到處判空
final _emptyLevels = ValueNotifier<List<double>>(const []);

/// 片段內容：影片/圖片是 filmstrip、音訊是波形、文字是字卡
Widget _clipFill(TimelineClip clip, MediaSource src, List<Uint8List> strip) {
  if (src.kind == ClipKind.audio) {
    // 真實波形：解碼完成前先畫示意波形，好了自動換
    return AnimatedBuilder(
      animation: WaveformCache.instance,
      builder: (context, _) => CustomPaint(
        painter: _WavePainter(
          peaks: WaveformCache.instance.of(src.path),
          start: src.duration <= 0
              ? 0
              : (clip.trimStart / src.duration).clamp(0.0, 1.0),
          end: src.duration <= 0
              ? 1
              : (clip.trimEnd / src.duration).clamp(0.0, 1.0),
        ),
      ),
    );
  }
  if (src.kind == ClipKind.text) {
    return Container(
      color: const Color(0xFF4A4A52),
      alignment: Alignment.center,
      child: const Icon(Icons.title, size: 14, color: Colors.white70),
    );
  }
  if (src.kind == ClipKind.wm) {
    // 浮水印片段：跟最上面那條全域浮水印軌同一個樣式
    // ——圖示＋名稱靠左，灰階（琥珀留給選取）
    return Container(
      color: kPanelHi,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.branding_watermark, size: 10, color: kIcon),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              src.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9,
                color: kIcon,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
  if (src.kind == ClipKind.image && strip.isNotEmpty) {
    return Image.memory(strip[0], fit: BoxFit.cover, gaplessPlayback: true);
  }
  if (strip.isEmpty) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blueGrey.shade700, Colors.blueGrey.shade900],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie, size: 18, color: Colors.white38),
      ),
    );
  }
  // 縮圖磚固定尺寸（不隨縮放拉伸變形），縮放只改變「放幾塊磚」
  final n = strip.length;
  final i0 = (clip.trimStart / src.duration * n).floor().clamp(0, n - 1);
  final i1 = (clip.trimEnd / src.duration * n).ceil().clamp(i0 + 1, n);
  final span = i1 - i0;
  return LayoutBuilder(
    builder: (context, cons) {
      final tileW = cons.maxHeight; // 磚寬＝軌高（近方形）
      final count = (cons.maxWidth / tileW).ceil().clamp(1, 400);
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (var k = 0; k < count; k++)
            Positioned(
              left: k * tileW,
              top: 0,
              bottom: 0,
              width: tileW,
              child: Image.memory(
                strip[(i0 + (k * span ~/ count)).clamp(0, n - 1)],
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
        ],
      );
    },
  );
}

/// 一按下就立刻贏得競技場的 pan，
/// 避免拖曳被外層的捲動列表搶走。
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// 時間軸上的片段。拖曳時本體留在原地變淡，移動的是父層的幽靈。
class _ClipBlock extends StatelessWidget {
  final TimelineClip clip;
  final MediaSource source;
  final List<Uint8List> filmstrip;
  final bool isSelected;
  final bool lifted;
  final double pxPerSec;
  final double height;
  final ValueChanged<int> onSelect;
  final void Function(int id, double deltaSec, bool fromLeft) onTrim;
  final VoidCallback? onTrimStart;
  final ValueChanged<Offset> onLiftStart;
  final void Function(double ddx, double ddy, Offset globalPos) onLiftUpdate;
  final VoidCallback onLiftEnd;

  const _ClipBlock({
    super.key,
    required this.clip,
    required this.source,
    required this.filmstrip,
    required this.isSelected,
    required this.lifted,
    required this.pxPerSec,
    required this.height,
    required this.onSelect,
    required this.onTrim,
    this.onTrimStart,
    required this.onLiftStart,
    required this.onLiftUpdate,
    required this.onLiftEnd,
  });

  @override
  Widget build(BuildContext context) {
    final (fill, borderColor, icon) = switch (source.kind) {
      ClipKind.video => (kVideoFill, kVideoBorder, Icons.movie_outlined),
      ClipKind.audio => (kAudioFill, kAudioBorder, Icons.music_note),
      ClipKind.image => (kVideoFill, kVideoBorder, Icons.image_outlined),
      ClipKind.text => (
        const Color(0xFF2E2A38),
        const Color(0xFF8A7BB8),
        Icons.title,
      ),
      // 浮水印片段：灰階（琥珀留給選取），
      // 用圖示跟其他素材區分就夠了
      ClipKind.wm => (
        const Color(0xFF2E2E35),
        const Color(0xFF8A8A94),
        Icons.branding_watermark,
      ),
    };
    final w = (clip.length * pxPerSec).clamp(22.0, double.infinity).toDouble();

    return Positioned(
      left: clip.offset * pxPerSec,
      top: 0,
      bottom: 0,
      child: Opacity(
        opacity: lifted ? 0.25 : 1.0,
        child: RawGestureDetector(
          gestures: {
            _EagerPanRecognizer:
                GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                  () => _EagerPanRecognizer(),
                  (r) => r
                    ..onStart = ((d) => onLiftStart(d.globalPosition))
                    ..onUpdate = ((d) =>
                        onLiftUpdate(d.delta.dx, d.delta.dy, d.globalPosition))
                    ..onEnd = ((_) => onLiftEnd())
                    ..onCancel = onLiftEnd,
                ),
          },
          child: GestureDetector(
            onTap: () => onSelect(clip.id),
            child: Container(
              width: w,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: isSelected ? kSelect : borderColor,
                  width: isSelected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _clipFill(clip, source, filmstrip),
                  // 檔名不顯示，畫面乾淨；只留左上角小圖示表明素材種類
                  // （浮水印片段內容本身就是圖示＋名稱，不再疊一顆）
                  if (source.kind != ClipKind.wm)
                    Positioned(
                      left: 5,
                      top: 4,
                      child: Icon(icon, size: 10, color: Colors.white70),
                    ),
                  // 變速片段掛倍速小標
                  if ((clip.speed - 1.0).abs() > 0.01)
                    Positioned(
                      right: 5,
                      top: 3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${clip.speed % 1 == 0 ? clip.speed.toInt() : clip.speed}x',
                          style: const TextStyle(
                            fontSize: 8.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (isSelected && !lifted) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _TrimHandle(
                        isLeft: true,
                        onStart: onTrimStart,
                        onDrag: (dxSec) => onTrim(clip.id, dxSec, true),
                        pxPerSec: pxPerSec,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _TrimHandle(
                        isLeft: false,
                        onStart: onTrimStart,
                        onDrag: (dxSec) => onTrim(clip.id, dxSec, false),
                        pxPerSec: pxPerSec,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 軌道標籤：點一下加素材，按住上下拖曳可以整條換順序
class _TrackLabel extends StatefulWidget {
  final int index;
  final double height;
  final double rowStride;
  final bool canDrag;
  final bool isEmptyRow;
  final bool muted;
  final bool isVoice; // 旁白軌：標籤變紅色錄音鈕
  final bool isRecording;

  /// 選中的片段在這一軌：標籤亮起來，暗示選取落在哪一層
  final bool hasSelection;
  final bool isDragging;
  final double dragDy;
  final int maxTrack;
  final VoidCallback onTap;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  const _TrackLabel({
    required this.index,
    required this.height,
    required this.rowStride,
    required this.canDrag,
    required this.isEmptyRow,
    this.muted = false,
    this.isVoice = false,
    this.isRecording = false,
    this.hasSelection = false,
    required this.isDragging,
    required this.dragDy,
    required this.maxTrack,
    required this.onTap,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_TrackLabel> createState() => _TrackLabelState();
}

class _TrackLabelState extends State<_TrackLabel> {
  double _dy = 0;
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    final amber = widget.isDragging || widget.hasSelection;
    final label = Container(
      height: widget.height,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: widget.isRecording ? const Color(0x33FF3B30) : kPanel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: widget.isVoice
              ? const Color(0xFFFF3B30)
              : (widget.isDragging || widget.hasSelection ? kSelect : kBorder),
          width: (widget.isDragging || widget.isVoice || widget.hasSelection)
              ? 2
              : 1,
        ),
        boxShadow: widget.isDragging
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      // 只放一個圖示，乾淨就好（整條軌道仍可上下拖曳換順序）
      child: Center(
        child: widget.isVoice
            // 旁白軌：紅色圓鈕，錄音中變成方形停止
            ? Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Color(0xFFFF3B30),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.isRecording ? Icons.stop_rounded : Icons.mic,
                  size: 14,
                  color: Colors.white,
                ),
              )
            : Icon(
                widget.isEmptyRow
                    ? Icons.add
                    : (widget.muted ? Icons.volume_off : Icons.volume_up),
                size: 15,
                color: widget.muted ? kSelect : (amber ? kSelect : kTextDim),
              ),
      ),
    );

    if (!widget.canDrag) {
      return SizedBox(
        height: widget.height,
        child: InkWell(onTap: widget.onTap, child: label),
      );
    }

    return SizedBox(
      height: widget.height,
      child: RawGestureDetector(
        gestures: {
          _EagerPanRecognizer:
              GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                () => _EagerPanRecognizer(),
                (r) => r
                  ..onStart = (_) {
                    _dy = 0;
                    _moved = false;
                  }
                  ..onUpdate = (d) {
                    _dy = (_dy + d.delta.dy).clamp(
                      -widget.index * widget.rowStride,
                      (widget.maxTrack - widget.index) * widget.rowStride,
                    );
                    if (_dy.abs() > 4) _moved = true;
                    widget.onDragUpdate(_dy);
                  }
                  ..onEnd = (_) {
                    if (_moved) {
                      widget.onDragEnd();
                    } else {
                      widget.onDragUpdate(0);
                      widget.onDragEnd();
                      widget.onTap();
                    }
                    _dy = 0;
                    _moved = false;
                  }
                  ..onCancel = () {
                    widget.onDragUpdate(0);
                    widget.onDragEnd();
                    _dy = 0;
                    _moved = false;
                  },
              ),
        },
        child: Transform.translate(
          offset: Offset(0, widget.dragDy),
          child: label,
        ),
      ),
    );
  }
}

/// 片段左右邊緣的修剪把手
class _TrimHandle extends StatelessWidget {
  final bool isLeft;
  final double pxPerSec;
  final ValueChanged<double> onDrag;
  final VoidCallback? onStart;

  const _TrimHandle({
    required this.isLeft,
    required this.pxPerSec,
    required this.onDrag,
    this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    // 把手比片段本體更早用 eager pan 直接贏得手勢競技場，
    // 所以拖把手＝修剪、拖本體＝移動。
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _EagerPanRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
              () => _EagerPanRecognizer(),
              (r) => r
                ..onStart = ((_) => onStart?.call())
                ..onUpdate = ((d) => onDrag(d.delta.dx / pxPerSec)),
            ),
      },
      child: Container(
        width: 13,
        decoration: BoxDecoration(
          color: kSelect,
          borderRadius: BorderRadius.horizontal(
            left: isLeft ? const Radius.circular(4) : Radius.zero,
            right: isLeft ? Radius.zero : const Radius.circular(4),
          ),
        ),
        child: const Center(
          child: Icon(Icons.drag_indicator, size: 11, color: Colors.black87),
        ),
      ),
    );
  }
}

/// 音訊片段內的波形。有真實峰值就畫真的（只畫 trim 範圍那段），
/// 還在解碼時退回穩定的示意波形。
class _WavePainter extends CustomPainter {
  final List<double>? peaks;
  final double start; // trim 範圍（0~1，相對整個音檔）
  final double end;
  final Color? color;

  /// 錄音中的即時波形：沒有取樣時畫平線（而不是示意波形），
  /// 不然一開錄就滿滿假波形，反而看不出有沒有收到聲音
  final bool live;

  _WavePainter({
    this.peaks,
    this.start = 0,
    this.end = 1,
    this.color,
    this.live = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (color ?? kAudioBorder).withValues(
        alpha: color != null ? 0.9 : 0.55,
      )
      ..strokeWidth = 1.5;
    const step = 3.0;
    final mid = size.height / 2;
    final p = peaks;

    if (live) {
      if (p == null || p.isEmpty) {
        canvas.drawLine(Offset(2, mid), Offset(size.width - 2, mid), paint);
        return;
      }
      // 取樣是等時間間隔累積的，寬度也隨播放頭等速長，所以平均鋪滿即可
      final cols = ((size.width - 4) / step).floor().clamp(1, 100000);
      for (var c = 0; c < cols; c++) {
        final a = c * p.length ~/ cols;
        final b = ((c + 1) * p.length ~/ cols).clamp(a + 1, p.length);
        var m = 0.0;
        for (var i = a; i < b; i++) {
          if (p[i] > m) m = p[i];
        }
        final h = (m * size.height * 0.86).clamp(1.5, size.height - 2);
        final x = 2.0 + c * step;
        canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
      }
      return;
    }

    if (p == null || p.isEmpty || end <= start) {
      // 示意波形：用位置產生穩定的偽隨機高度（不能用 Random，保持重繪一致）
      for (var x = 2.0; x < size.width - 2; x += step) {
        final h = (((x * 7919).toInt() % 17) / 17) * (size.height * 0.55) + 2;
        canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
      }
      return;
    }

    // 真實波形：每條直線取自己覆蓋的峰值區間的最大值
    final i0 = (start * p.length).floor().clamp(0, p.length - 1);
    final i1 = (end * p.length).ceil().clamp(i0 + 1, p.length);
    final range = i1 - i0;
    final cols = ((size.width - 4) / step).floor().clamp(1, 100000);
    for (var c = 0; c < cols; c++) {
      final a = i0 + (c * range ~/ cols);
      final b = i0 + ((c + 1) * range ~/ cols).clamp(1, range);
      var m = 0.0;
      for (var i = a; i < (b > a ? b : a + 1) && i < p.length; i++) {
        if (p[i] > m) m = p[i];
      }
      final h = (m * size.height * 0.86).clamp(1.5, size.height - 2);
      final x = 2.0 + c * step;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peaks != peaks ||
      old.start != start ||
      old.end != end ||
      old.color != color;
}

/// 時間刻度尺
class _RulerPainter extends CustomPainter {
  final double pxPerSec;
  final Color color;

  _RulerPainter({required this.pxPerSec, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const steps = [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0];
    final step = steps.firstWhere(
      (s) => s * pxPerSec >= 56,
      orElse: () => steps.last,
    );

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    for (var t = 0.0; t * pxPerSec < size.width; t += step / 4) {
      final x = t * pxPerSec;
      final isMajor = (t / step - (t / step).round()).abs() < 1e-6;
      canvas.drawLine(
        Offset(x, isMajor ? size.height * 0.35 : size.height * 0.65),
        Offset(x, size.height),
        paint,
      );
      if (isMajor) {
        final m = (t ~/ 60).toString().padLeft(2, '0');
        final s = (t % 60).toStringAsFixed(step < 1 ? 1 : 0).padLeft(2, '0');
        final tp = TextPainter(
          text: TextSpan(
            text: '$m:$s',
            style: TextStyle(fontSize: 9, color: color),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 3, 0));
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.pxPerSec != pxPerSec || old.color != color;
}
