import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

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
/// 時間軸上「沒有縮圖可看」的片段共用的底色。
///
/// 影片的縮圖還沒抽出來、文字、浮水印、馬賽克全部同一個中性灰——
/// 以前四種各有各的底色（馬賽克還帶藍），時間軸看起來像調色盤。
/// 種類靠前面那顆小圖示分就夠了
const kClipFill = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF232328), Color(0xFF141416)],
);

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

  /// 修剪結束（自動整理要等手指放開才收空隙）
  final VoidCallback? onTrimEnd;

  /// 放開片段：一次帶回新位置與軌道。insert=true 代表插成新的一層。
  final void Function(int id, double newOffset, int track, bool insert) onDrop;
  final ValueChanged<int> onAddMedia; // 在這一軌加素材
  final void Function(int from, int to) onReorderTrack; // 整條軌道換順序
  final Set<int> mutedTracks; // 靜音的軌道
  final ValueChanged<int> onToggleMute; // 點標籤喇叭切換整軌靜音
  final Set<int> hiddenTracks; // 關閉顯示的軌道
  final ValueChanged<int>? onToggleHidden; // 點標籤眼睛切換整軌顯示

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

  /// 點到一個「窄到擺不下修剪把手」的片段。父層負責放大時間軸到看得
  /// 清楚為止——不然使用者只會看到把手憑空消失，不知道要先放大

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

  /// 拖曳浮水印列開始時的「安靜選取」：只選取、不切分頁。
  /// 沒給就退回 onSelectWm。雙指縮放時手指落在浮水印列上
  /// 不該直接跳去編輯模式
  final VoidCallback? onSelectWmDrag;
  final ValueChanged<double> onMoveWm; // 新的起點
  final void Function(double deltaSec, bool fromLeft) onTrimWm;

  /// 浮水印修剪手勢開始（重置吸附用的原始邊緣、拍復原快照）
  final VoidCallback? onTrimWmStart;

  /// 點軌道空白處＝選取整條軌道（貼上的目標）
  final ValueChanged<int>? onTapTrack;

  /// 長按左側標籤＝刪掉整條軌道
  final ValueChanged<int>? onDeleteTrack;

  /// 目前被選取的軌道（-1＝沒有）；該軌會亮框提示
  final int selectedTrack;

  /// 磁吸開關：關掉之後拖曳完全照手指走、也不震動
  final bool snapEnabled;

  /// 額外的空白軌道數（「加入空白軌道」加出來的，
  /// 在預設那條常駐空軌之外再多畫幾條）
  final int extraTracks;

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
    this.onTrimEnd,
    required this.onDrop,
    required this.onAddMedia,
    required this.onReorderTrack,
    this.mutedTracks = const {},
    required this.onToggleMute,
    this.hiddenTracks = const {},
    this.onToggleHidden,
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
    this.onSelectWmDrag,
    required this.onMoveWm,
    required this.onTrimWm,
    this.onTrimWmStart,
    this.onTapTrack,
    this.onDeleteTrack,
    this.selectedTrack = -1,
    this.snapEnabled = true,
    this.extraTracks = 0,
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

  /// 浮水印列這次手勢的累計移動量（放開時 <6px＝點擊）
  double _wmDragDist = 0;

  /// 拖曳片段時上一刻有沒有吸住（吸住的瞬間震一下）
  bool _dragSnapped = false;

  /// 拖曳已「武裝」（移動超過門檻）。沒武裝前幽靈不顯示、放開不算拖曳
  bool _liftArmed = false;

  // 長按偵測：按住不動 0.45 秒 → 取消拖曳、打開選單
  Timer? _pressTimer;
  Offset _pressPos = Offset.zero;
  bool _liftWasSelected = false; // 按下時片段是否本來就選取（點兩下編輯用）

  TimelineModel get timeline => widget.timeline;
  double get pxPerSec => widget.pxPerSec;
  double get trackH => 54 * widget.trackScale;
  double get rowStride => trackH + TimelineEditor.gap;

  /// 畫出來的軌數：有內容的 + 一條永遠留著的空軌 + 手動加的空白軌
  // 永遠多一列空軌可放東西；預備中的旁白軌也要有位置顯示
  int get _rows => math.max(
    timeline.usedTracks + 1 + widget.extraTracks,
    (widget.voiceTrack ?? -1) + 1,
  );

  /// 拖曳／插入允許到達的最上層軌（含手動加的空白軌）
  int get _maxTrack => timeline.usedTracks + widget.extraTracks;

  /// 軌道編號 → 畫面上由上往下數的第幾列。
  ///
  /// 編號大的疊在畫面上層，所以它在時間軸上也要畫在上面——剪映、
  /// Premiere 都是這樣：主軌在最下面，疊加的往上長。反過來排的話，
  /// 新加的素材明明蓋在最上面，看起來卻掉到時間軸最底下
  int _rowOf(int track) => _rows - 1 - track;

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
    if (_pinching) return; // 雙指縮放時間軸中：不要把素材拿起來
    _liftArmed = false; // 移動超過門檻才算真的在拖（見 _liftUpdate）
    _liftWasSelected = widget.selectedId == c.id;
    // 這裡「不」選取：第一指按在素材上、第二指跟著落下變成縮放時，
    // 按下就選會讓縮放的手勢順便誤選素材（使用者實測回報）。
    // 選取延到三個確定不是縮放的時刻：真的拖起來（armed）、
    // 放開當一次點擊、或長按開選單
    // onLiftChanged 留到「真的拖起來」（armed）才通知父層——
    // 一按下就說在拖的話，第二根手指落下時父層會以為使用者正在
    // 搬素材而不轉成縮放，結果整條被拖走
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
        widget.onSelect(c.id); // 延後的選取（見 _liftStart）
        HapticFeedback.mediumImpact(); // 長按成立的觸覺回饋
        widget.onLongPressClip(c.id, _pressPos);
      }
    });
  }

  void _liftUpdate(double ddx, double ddy, Offset globalPos) {
    // 拖到一半第二指下來（變成縮放）：整個放棄這次拖曳，
    // 素材留在原地，不然縮放的同時素材會被拖走
    if (_pinching) {
      if (_lift != null) {
        _pressTimer?.cancel();
        setState(() => _lift = null);
        _stopAutoScroll();
        widget.onLiftChanged?.call(false);
      }
      return;
    }
    final l = _lift;
    if (l == null) return;
    if ((l.dx + ddx).abs() > 6 || (l.dy + ddy).abs() > 6) {
      _pressTimer?.cancel();
    }
    // 抬手那一下的小位移不在這裡濾：事件進到手勢辨識之前就擋掉了
    //（見 SteadyPointerBinding）
    // 畫面上越上面＝編號越大（見 _rowOf）：往下拖是往編號小的走
    final minDy = -(_maxTrack - l.startTrack + 0.45) * rowStride;
    final maxDy = (l.startTrack + 0.45) * rowStride;
    setState(() {
      _lift = (
        clipId: l.clipId,
        startOffset: l.startOffset,
        startTrack: l.startTrack,
        dx: l.dx + ddx,
        dy: (l.dy + ddy).clamp(minDy, maxDy),
      );
      // 移動超過 8px 才「武裝」：捏合的第一指落在素材上時，
      // 第二指還沒到的那幾十毫秒不會看到素材被拖走
      if (!_liftArmed && (_lift!.dx.abs() > 8 || _lift!.dy.abs() > 8)) {
        _liftArmed = true;
        widget.onSelect(l.clipId); // 延後的選取（見 _liftStart）
        // 到這裡才算真的在搬素材，父層現在才需要讓開
        widget.onLiftChanged?.call(true);
      }
    });
    // 吸附到別的片段邊緣的那一下震動一次，手指才感覺得到「黏住」
    final spec = _liftSpec();
    if (spec != null) {
      final want = l.startOffset + (l.dx + ddx) / pxPerSec;
      final on = (spec.offset - math.max(0.0, want)).abs() > 0.0005;
      if (on != _dragSnapped) {
        _dragSnapped = on;
        if (on) HapticFeedback.selectionClick();
      }
    }
    _updateAutoScroll(globalPos);
  }

  void _liftEnd() {
    _pressTimer?.cancel();
    final spec = _liftSpec();
    final l = _lift;
    final armed = _liftArmed;
    _liftArmed = false;
    if (l == null) return; // 長按選單已經接手
    setState(() => _lift = null);
    _stopAutoScroll();
    widget.onLiftChanged?.call(false);
    // 沒有武裝（幾乎沒動）= 點擊：現在才選取（見 _liftStart）；
    // 點已選取的片段 → 交給編輯回呼
    if (!armed) {
      widget.onSelect(l.clipId);
      if (_liftWasSelected && l.dx.abs() < 6 && l.dy.abs() < 6) {
        widget.onTapSelectedClip?.call(l.clipId);
      }
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
    final offset = widget.snapEnabled
        ? timeline.snapOffset(clip, want, pxPerSec)
        : math.max(0.0, want);
    final len = clip.length;

    bool collide(int track) => timeline.clips.any(
      (c) =>
          c.id != clip.id &&
          c.track == track &&
          c.offset < offset + len &&
          c.end > offset,
    );

    final maxTrack = _maxTrack; // 最底下的空軌（含手動加的空白軌）
    // 垂直沒怎麼動 → 留在原軌，只移位置
    if (l.dy.abs() < rowStride * 0.4) {
      return (
        offset: offset,
        track: l.startTrack,
        insert: false,
        insertLine: null,
      );
    }
    // 往下拖 dy 是正的，但那是往編號小的方向
    final raw = (l.startTrack * rowStride - l.dy) / rowStride;
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
    return (_dragTrack! - steps).clamp(0, math.max(0, timeline.usedTracks - 1));
  }

  double _rowShiftFor(int t) {
    // 片段插入的預覽：插入點以下全部讓位
    final spec = _liftSpec();
    if (spec?.insertLine != null) {
      // 插入點「以上」（編號比它大的）整批往上讓一格
      return t >= spec!.insertLine! ? -rowStride : 0;
    }
    // 軌道標籤拖曳
    final from = _dragTrack;
    if (from == null) return 0;
    if (t == from) return _dragDy;
    final to = _trackDropTarget;
    if (from < to && t > from && t <= to) return rowStride;
    if (to < from && t >= to && t < from) return -rowStride;
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
                // 由上往下畫，編號由大到小：時間軸上面的那一列，在畫面
                // 上也是疊在上面的那一層（跟剪映／Premiere 一致）
                for (var t = _rows - 1; t >= 0; t--) ...[
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
                _leadPad = leadPad;
                _viewWidth = cons.maxWidth;
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
                                      // 只畫看得見的一段刻度：長片放大後整條
                                      // 可以到十幾萬 px，全畫的話雙指縮放
                                      // 每一幀都要排幾千個刻度＝掉幀。
                                      // 自己包一層 RepaintBoundary，捲動時
                                      // 只重畫這條薄薄的刻度尺，不拖累縮圖/波形
                                      child: RepaintBoundary(
                                        child: ListenableBuilder(
                                          listenable: widget.scrollController,
                                          builder: (context, _) {
                                            final off =
                                                widget
                                                    .scrollController
                                                    .hasClients
                                                ? widget.scrollController.offset
                                                : 0.0;
                                            return CustomPaint(
                                              size: Size(totalW, rulerH),
                                              painter: _RulerPainter(
                                                pxPerSec: pxPerSec,
                                                color: kTextDim.withValues(
                                                  alpha: 0.7,
                                                ),
                                                viewL: off - leadPad,
                                                viewW: cons.maxWidth,
                                              ),
                                            );
                                          },
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
                                    for (var t = _rows - 1; t >= 0; t--) ...[
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
                                      (_rows - spec!.insertLine!) * rowStride -
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
                              //（武裝後才顯示，避免捏合誤觸時閃一下）
                              if (_lift != null && _liftArmed && spec != null)
                                _ghost(spec),
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

  /// 版面尺寸（給修剪把手貼邊用），build 時由 LayoutBuilder 存起來
  double _leadPad = 0;
  double _viewWidth = 0;

  Widget _trackRow(
    int track,
    ({double offset, int track, bool insert, int? insertLine})? spec,
  ) {
    final isEmptyRow = track >= timeline.usedTracks;
    final clips = timeline.onTrack(track);
    final isDropTarget = spec != null && !spec.insert && spec.track == track;

    /// 這條是不是那條「還沒用到的第一軌」——也就是會寫著
    /// 「點我加入…」的那條。它整條就是一顆加素材按鈕
    final isInviteRow =
        isEmptyRow &&
        track == timeline.usedTracks &&
        !isDropTarget &&
        clips.isEmpty;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 點空白處＝取消片段選取、改成選取這條軌道
            //（貼上就會貼進被選的軌）。
            // 但那條寫著「點我加入…」的空軌例外：它整條就是加素材，
            // 不然使用者照著字點下去只會看到一個框亮起來，什麼也沒發生。
            // 那一軌還是可以當貼上目標——長按空白處的選單裡有「貼上」
            onTap: () {
              if (isInviteRow) {
                widget.onAddMedia(track);
                return;
              }
              widget.onSelect(-1);
              widget.onTapTrack?.call(track);
            },
            onLongPressStart: (d) {
              HapticFeedback.mediumImpact(); // 長按成立的觸覺回饋
              widget.onLongPressEmpty(
                track,
                (d.localPosition.dx / pxPerSec).clamp(0.0, 1e6),
                d.globalPosition,
              );
            },
            // CapCut 式：整條灰底橫帶，不描邊；拖放目標才亮框
            child: Container(
              decoration: BoxDecoration(
                color: isDropTarget
                    ? kSelect.withValues(alpha: 0.10)
                    : kPanelHi.withValues(alpha: isEmptyRow ? 0.4 : 0.8),
                borderRadius: BorderRadius.circular(3),
                border: isDropTarget
                    ? Border.all(color: kSelect, width: 2)
                    : (widget.selectedTrack == track
                          ? Border.all(color: kSelect.withValues(alpha: 0.6))
                          : null),
              ),
              // 空狀態引導：只在「第一條空軌」淡淡提示一句，
              // 新手才知道多軌可以放什麼（有拖放目標時讓位）
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 12),
              child: isInviteRow
                  ? Text(
                      '點我加入文字、圖片、馬賽克',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: kTextDim.withValues(alpha: 0.55),
                      ),
                    )
                  : null,
            ),
          ),
        ),
        // 被選取的畫最後：把手熱區會伸出片段邊界一點，
        // 排在前面的話那一截會被相鄰片段蓋住，等於白做
        for (final c
            in [...clips]..sort(
              (a, b) => (a.id == widget.selectedId ? 1 : 0).compareTo(
                b.id == widget.selectedId ? 1 : 0,
              ),
            ))
          _ClipBlock(
            key: ValueKey('clip${c.id}'),
            clip: c,
            source: timeline.sourceOf(c),
            filmstrip: widget.thumbs[c.sourceIndex] ?? const [],
            isSelected: c.id == widget.selectedId,
            lifted: _liftArmed && _lift?.clipId == c.id,
            pxPerSec: pxPerSec,
            height: trackH,
            onSelect: widget.onSelect,
            onTrim: widget.onTrim,
            onTrimStart: widget.onTrimStart,
            onTrimEnd: widget.onTrimEnd,
            onLiftStart: (pos) => _liftStart(c, pos),
            onLiftUpdate: _liftUpdate,
            onLiftEnd: _liftEnd,
            scrollController: widget.scrollController,
            leadPad: _leadPad,
            viewWidth: _viewWidth,
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
          border: Border.all(color: kBorder, width: 1),
        ),
        // 選取框畫在前景：換邊框寬度會讓裡面的圖示位移
        foregroundDecoration: widget.wmSelected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: kSelect, width: 1.5),
              )
            : null,
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
    // 真正的寬度。以前底線是 72px：範圍再短、時間軸再縮，這條都還是
    // 畫 72px 寬——看起來就是「浮水印縮不下去」，而且右邊那顆修剪把手
    // 早就不在真正的結尾上，越拖越對不上。
    //
    // 改成照實畫，只留 12px 不讓它消失（跟片段一樣，太窄時把手與
    // 文字自己收起來，中間讓出來給拖曳）
    final rawW0 = (wm.end - wm.start) * pxPerSec;
    // 選取中至少撐到煞車寬，跟片段同一套（把手永遠有得拉）
    final rawW = widget.wmSelected ? math.max(rawW0, kTrimStopWidth) : rawW0;
    final w = rawW.clamp(2.0, double.infinity);
    // 擺得下圖示＋文字才畫標示；窄於煞車寬就不畫把手（跟片段
    // 同一套：這個縮放下修剪煞車不會放行，整條讓給拖曳移動）
    final showLabel = rawW >= 56;
    final showHandles = rawW >= kTrimStopWidth;
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
            // 浮水印帶預設橫跨整條時間軸——沒選取也用 eager pan 搶的
            // 話，手指落在最上排就永遠在「搬浮水印」，時間軸捲不動
            //（實測回報：切回來滑動鎖死）。沒選取＝不搶，讓捲動贏；
            // 點一下選取，選取後才能拖
            gestures: !widget.wmSelected
                ? const <Type, GestureRecognizerFactory>{}
                : {
                    _EagerPanRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _EagerPanRecognizer
                        >(
                          () => _EagerPanRecognizer(),
                          (r) => r
                            // 按下＝「安靜選取」不切分頁。跳分頁放在放開時
                            // 用移動距離判斷（幾乎沒動＝點擊）：
                            // 拖曳調範圍不能中途被拉去浮水印分頁，
                            // 雙指縮放誤觸也不能跳
                            ..onStart = ((_) {
                              if (_pinching) return;
                              _wmDragDist = 0;
                              (widget.onSelectWmDrag ?? widget.onSelectWm)();
                            })
                            ..onUpdate = ((d) {
                              if (_pinching) return;
                              _wmDragDist +=
                                  d.delta.dx.abs() + d.delta.dy.abs();
                              widget.onMoveWm(wm.start + d.delta.dx / pxPerSec);
                            })
                            ..onEnd = ((_) {
                              if (_pinching || _wmDragDist >= 6) return;
                              widget.onSelectWm(); // 點擊＝進浮水印分頁
                            }),
                        ),
                  },
            child: GestureDetector(
              onTap: () {
                if (_pinching) return;
                widget.onSelectWm();
              },
              child: Container(
                width: w.toDouble(),
                // 灰階退場：琥珀只留給「選取」一個意義。
                // 選中這條軌時才亮起來
                decoration: BoxDecoration(
                  color: widget.wmSelected
                      ? kSelect.withValues(alpha: 0.22)
                      : kPanelHi,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF3A3A42), width: 1),
                ),
                // 選取框畫在前景，內容不位移
                foregroundDecoration: widget.wmSelected
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: kSelect, width: 1.5),
                      )
                    : null,
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 標示：圖示＋內容。本來只有 9px 的字、左右又各留
                    // 14px 給修剪把手，窄的時候整條看起來是空白的，
                    // 根本認不出這是浮水印
                    if (showLabel)
                      Padding(
                        padding: EdgeInsets.only(
                          left: widget.wmSelected && showHandles ? 15 : 6,
                          right: widget.wmSelected && showHandles ? 15 : 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 平常不放圖示（文字本身就認得出是浮水印）；
                            // 隱藏中的閉眼是狀態提示，留著
                            if (widget.wmHidden) ...[
                              const Icon(
                                Icons.visibility_off_outlined,
                                size: 11,
                                color: kTextDim,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                widget.wmLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: widget.wmSelected ? kSelect : kIcon,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (widget.wmSelected && showHandles) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _TrimHandle(
                          isLeft: true,
                          onDrag: (dxSec) => widget.onTrimWm(dxSec, true),
                          onStart: widget.onTrimWmStart,
                          pxPerSec: pxPerSec,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _TrimHandle(
                          isLeft: false,
                          onDrag: (dxSec) => widget.onTrimWm(dxSec, false),
                          onStart: widget.onTrimWmStart,
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
          _rowOf(l.startTrack) * rowStride +
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
      hidden: widget.hiddenTracks.contains(t),
      // 眼睛只給有內容的一般軌（空軌沒東西可藏、旁白軌是錄音鈕）
      onToggleHidden: (isEmptyRow || isVoice || widget.onToggleHidden == null)
          ? null
          : () => widget.onToggleHidden!(t),
      isVoice: isVoice,
      isRecording: isVoice && widget.voiceRecording,
      // 選中的片段在這一軌 → 標籤跟著亮，指出選取落在哪一層。
      // 「整條軌被選為貼上目標」不算：點標籤是靜音不是選取，
      // 那個狀態讓標籤亮起來只會讓人以為自己選了整條軌。
      // 用「第一個命中的片段」的軌來比：就算資料裡有撞號的 id，
      // 也永遠只亮一條（兩軌同時亮燈是使用者實際回報過的症狀）
      hasSelection:
          timeline.clips
              .where((c) => c.id == widget.selectedId)
              .firstOrNull
              ?.track ==
          t,
      isDragging: _dragTrack == t,
      dragDy: _dragTrack == t ? _dragDy : 0,
      maxTrack: timeline.usedTracks - 1,
      // 旁白軌＝錄音鈕；空軌點了加素材；有內容的軌切換整軌靜音
      onTap: () => isVoice
          ? widget.onVoiceRecordTap?.call()
          : (isEmptyRow ? widget.onAddMedia(t) : widget.onToggleMute(t)),
      // 長按左邊的圖示＝刪掉整條軌道（空軌沒東西可刪）
      onLongPress: isEmptyRow || isVoice
          ? null
          : () => widget.onDeleteTrack?.call(t),
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
  // 文字/浮水印/馬賽克：底色跟影片片段統一，前面小圖示分種類、
  // 文字樣式完全統一（同字級同色同字重）
  Widget overlayLabel(IconData icon, String text) => Container(
    // 不畫底：底由外層的圓角容器統一畫（見 _ClipBox 的 decoration）。
    // 這裡再鋪一層方形漸層的話，圓角處兩個形狀對不齊會露出縫，
    // 看起來就是四角各缺一塊（實測回報）
    padding: const EdgeInsets.symmetric(horizontal: 8),
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: Colors.white54),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 9,
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
  if (src.kind == ClipKind.text) {
    return overlayLabel(Icons.text_fields, src.name);
  }
  if (src.kind == ClipKind.mosaic) {
    return overlayLabel(Icons.blur_on, '馬賽克');
  }
  if (src.kind == ClipKind.wm) {
    return overlayLabel(
      src.isSticker ? Icons.emoji_emotions_outlined : Icons.branding_watermark,
      src.name,
    );
  }
  if (strip.isEmpty) {
    // 縮圖還沒抽出來時：底同樣交給外層畫，這裡只放圖示
    return const Center(
      child: Icon(Icons.movie, size: 18, color: Color(0xFF6E6E78)),
    );
  }
  // duration 讀不到（=0）時除法會變 NaN，floor() 直接炸——退回單張縮圖
  if (src.duration <= 0) {
    return Image.memory(strip[0], fit: BoxFit.cover, gaplessPlayback: true);
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

/// 修剪把手的熱區往片段外多伸出去多少（見 _TrimHandle.overhang）
const double _kHandleOverhang = 14;

/// 修剪的「畫面煞車」寬度：把手拖到片段在目前縮放下只剩這麼寬
/// 就停（兩顆 13px 把手＋中間一絲縫，再窄就抓不住了）。
///
/// 重點：煞車做在「修剪」而不是「畫面」。片段永遠照時間軸的
/// 相對比例畫，絕不畫得比實際長——之前反過來做（模型隨便剪、
/// 畫面卡住 56px 不動）的結果是：看起來正常的片段其實已經被剪到
/// 0.05 秒，總長歸零、播放鍵看似卡死。想剪得比煞車短就放大，
/// 放大後同樣的 56px 對應更短的秒數，煞車自然跟著鬆開
const double kTrimStopWidth = 32;

/// 畫修剪把手的最小片段寬。窄於這個寬度只給「拖曳移動」：
/// 兩顆把手一畫上去中間只剩一絲縫，想移動短片段永遠被判成修剪
/// （使用者回報：要移動小片段一直被以為要縮放）。要修剪就先放大，
/// 跟煞車同一套邏輯
const double kHandleMinWidth = 48;

/// 時間軸的最大縮放（每秒幾 px）。跟 [kTrimStopWidth] 一起決定
/// 修剪的絕對極限：1200px/秒 時煞車在 32/1200 ≈ 0.027 秒
const double kMaxPxPerSec = 1200;

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
  final VoidCallback? onTrimEnd;
  final ValueChanged<Offset> onLiftStart;
  final void Function(double ddx, double ddy, Offset globalPos) onLiftUpdate;
  final VoidCallback onLiftEnd;

  /// 可視範圍：把手要貼在可視邊緣，不然片段比畫面長時它會跑到畫面外碰不到。
  /// 傳控制器而不是算好的數字——只有把手需要跟著捲動重畫，
  /// 整條時間軸重建太貴
  final ScrollController scrollController;
  final double leadPad;
  final double viewWidth;

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
    this.onTrimEnd,
    required this.onLiftStart,
    required this.onLiftUpdate,
    required this.onLiftEnd,
    required this.scrollController,
    required this.leadPad,
    required this.viewWidth,
  });

  @override
  Widget build(BuildContext context) {
    final (fill, borderColor) = switch (source.kind) {
      ClipKind.video => (kVideoFill, kVideoBorder),
      ClipKind.audio => (kAudioFill, kAudioBorder),
      ClipKind.image => (kVideoFill, kVideoBorder),
      ClipKind.text => (const Color(0xFF2E2A38), const Color(0xFF8A7BB8)),
      // 浮水印片段：灰階（琥珀留給選取）
      ClipKind.wm => (const Color(0xFF2E2E35), const Color(0xFF8A8A94)),
      // 馬賽克：帶點藍紫，跟文字/浮水印區分
      ClipKind.mosaic => (const Color(0xFF2A3038), const Color(0xFF7B8A9E)),
    };
    // 有縮圖（影片／圖片抽到了幀）才用純色底；其餘一律漸層底
    final hasStrip = filmstrip.isNotEmpty;
    // 照時間軸的相對比例畫，最窄留 16px：一小截素材（縮圖）
    // 還看得見，認得出這一格是什麼。
    //
    // 「選取中」再放寬到煞車寬（32px）：不撐的話，縮小時間軸後
    // 點選一個短片段會完全沒有把手——想拉長都沒得拉。撐這 16px
    // 只是互動狀態的視覺，其他片段照比例不動；在這個縮放下往
    // 更短修剪一樣被煞車擋（會跳提示），拉長則隨時可以
    final wTrue = (clip.length * pxPerSec).clamp(16.0, double.infinity);
    final w = (isSelected && !lifted ? math.max(wTrue, kTrimStopWidth) : wTrue)
        .toDouble();

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
            // 外層不裁切：修剪把手的熱區要能伸出片段邊界一點
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.passthrough,
              children: [
                Container(
                  width: w,
                  decoration: BoxDecoration(
                    // 有縮圖的片段用純色當底（縮圖會蓋滿）；沒有縮圖的
                    // 用漸層——底只在這裡畫一次，圓角就不會有接縫
                    color: hasStrip ? fill : null,
                    gradient: hasStrip ? null : kClipFill,
                    borderRadius: BorderRadius.circular(5),
                    // 底層永遠是同一條 1px 邊：邊框寬度會被算進內距，
                    // 選取時從 1 換成 2 的話裡面的縮圖就整個位移 1px，
                    // 取消選取又移回去——那正是「選取時素材會抖一下」
                    border: Border.all(color: borderColor, width: 1),
                  ),
                  // 選取的琥珀框畫在「前景」：疊在內容上面，不參與版面
                  foregroundDecoration: isSelected
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: kSelect, width: 2),
                        )
                      : null,
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _clipFill(clip, source, filmstrip),
                      // 倒轉片段掛個標，不然跟正播的長得一模一樣
                      //（旗標模式或已轉成倒轉檔都算）
                      if (clip.reverse || source.revOf != null)
                        Positioned(
                          left: 5,
                          top: 3,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: kSelect,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '倒轉',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.black,
                              ),
                            ),
                          ),
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
                    ],
                  ),
                ),
                // 原本的雙把手，貼在片段內側兩緣。窄於 kHandleMinWidth
                // 改成「貼在片段外側」：以前直接不畫（怕把手吃光中間、
                // 短片段永遠被判成修剪），但實測回報「小到一定程度沒有
                // 拉桿」——外掛式把手中間整條留給移動，兩全
                if (isSelected && !lifted)
                  // 熱區跟著片段長度給，短片段不會被兩個把手佔滿；
                  // 位置夾在可視範圍內，片段拉得比畫面長時
                  // 把手會貼在邊緣而不是跑到畫面外
                  Positioned.fill(
                    child: ListenableBuilder(
                      listenable: scrollController,
                      builder: (context, _) {
                        // 兩顆把手吃掉的內寬至多 w-12：中間永遠留
                        // 12px 抓著移動。縮到煞車寬（32px）時把手內寬
                        // 各 10px，「有時抓不到、拉不動」就是中間只剩
                        // 一絲縫被把手吃光的時候
                        final hw = math.min(
                          (w - 12) / 2,
                          (w * 0.28).clamp(13.0, 40.0),
                        );
                        const over = _kHandleOverhang;
                        final off = scrollController.hasClients
                            ? scrollController.offset
                            : 0.0;
                        // 換算成「相對這個片段左緣」的可視範圍
                        final left = clip.offset * pxPerSec;
                        final vL = off - leadPad - left;
                        final vR = vL + viewWidth;
                        // 那一側的邊被螢幕切掉就不畫那顆把手：
                        // 拉一個看不到的邊等於盲剪，畫在螢幕邊上
                        // 又跟片段內容疊在一起、更常被誤按
                        // （使用者回報：尾巴不在畫面裡不要顯示右拉桿）。
                        // 捲到邊出現，把手就回來
                        final headVisible = vL <= 0.5;
                        final tailVisible = w <= vR + 0.5;
                        // 窄片段：把手整支移到片段「外側」，中間整條
                        // 留給拖曳移動（實測回報：小到一定程度沒有拉桿）。
                        // 外側把手「不加」向外熱區：加了會蓋到隔壁的
                        // 時間軸，往左滑動被它吃掉（實測回報：滑動鎖死）
                        final outside = w < kHandleMinWidth;
                        final oOver = outside ? 0.0 : over;
                        return Stack(
                          children: [
                            if (headVisible)
                              Positioned(
                                left: outside ? -13.0 : -_kHandleOverhang,
                                top: 0,
                                bottom: 0,
                                child: _TrimHandle(
                                  isLeft: true,
                                  width: outside ? 13 : hw,
                                  overhang: oOver,
                                  onStart: onTrimStart,
                                  onEnd: onTrimEnd,
                                  onDrag: (d) => onTrim(clip.id, d, true),
                                  pxPerSec: pxPerSec,
                                ),
                              ),
                            if (tailVisible)
                              Positioned(
                                left: outside ? w : w - hw,
                                // 右把手的熱區往右長，位置不用退
                                top: 0,
                                bottom: 0,
                                child: _TrimHandle(
                                  isLeft: false,
                                  width: outside ? 13 : hw,
                                  overhang: oOver,
                                  onStart: onTrimStart,
                                  onEnd: onTrimEnd,
                                  onDrag: (d) => onTrim(clip.id, d, false),
                                  pxPerSec: pxPerSec,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
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

  /// 這一軌關閉顯示中（眼睛按鈕亮琥珀）
  final bool hidden;

  /// 點下半的眼睛＝切換整軌顯示（null＝這一軌不提供，標籤只有喇叭）
  final VoidCallback? onToggleHidden;
  final bool isVoice; // 旁白軌：標籤變紅色錄音鈕
  final bool isRecording;

  /// 選中的片段在這一軌：標籤跟著亮，指出選取落在哪一層。
  /// 注意這裡「不」包含「整條軌被選為貼上目標」——
  /// 那個狀態顯示在那一列本身（見 _trackRow），標籤跟著亮的話
  /// 會讓人以為自己把整條軌選起來了，但點標籤其實是靜音
  final bool hasSelection;
  final bool isDragging;
  final double dragDy;
  final int maxTrack;
  final VoidCallback onTap;

  /// 長按＝刪掉整條軌道（沒給就不支援）
  final VoidCallback? onLongPress;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  const _TrackLabel({
    required this.index,
    required this.height,
    required this.rowStride,
    required this.canDrag,
    required this.isEmptyRow,
    this.muted = false,
    this.hidden = false,
    this.onToggleHidden,
    this.isVoice = false,
    this.isRecording = false,
    this.hasSelection = false,
    required this.isDragging,
    required this.dragDy,
    required this.maxTrack,
    required this.onTap,
    this.onLongPress,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_TrackLabel> createState() => _TrackLabelState();
}

class _TrackLabelState extends State<_TrackLabel> {
  double _dy = 0;
  bool _moved = false;

  void _fireTap() {
    // 一般軌整格＝隱藏切換（靜音鈕已拿掉）；空軌/旁白走 onTap
    if (widget.onToggleHidden != null) {
      widget.onToggleHidden!();
    } else {
      widget.onTap();
    }
  }

  /// 長按偵測（拖曳辨識器會吃掉手勢，長按得自己算）
  Timer? _pressTimer;
  bool _longFired = false;

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amber = widget.isDragging || widget.hasSelection;
    final label = Container(
      height: widget.height,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: widget.isRecording ? kRecord.withValues(alpha: 0.2) : kPanel,
        borderRadius: BorderRadius.circular(4),
        // 旁白軌的紅框是常駐的（不會切換，不位移）；琥珀的選取框
        // 畫在下面的前景，寬度切換不影響版面
        border: Border.all(
          color: widget.isVoice ? kRecord : kBorder,
          width: widget.isVoice ? 2 : 1,
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
      foregroundDecoration: (amber && !widget.isVoice)
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: kSelect, width: 2),
            )
          : null,
      // 只放一顆「隱藏」鈕（使用者指定：靜音鈕拿掉，隱藏本來就
      // 連聲音一起關）。空軌＝加號、旁白軌＝錄音鈕照舊
      child: Center(
        child: widget.isVoice
            // 旁白軌：紅色圓鈕，錄音中變成方形停止
            ? Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: kRecord,
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
                    : (widget.hidden
                          ? Icons.visibility_off
                          : Icons.visibility_outlined),
                size: 15,
                color: (widget.hidden || amber) ? kSelect : kTextDim,
              ),
      ),
    );

    if (!widget.canDrag) {
      return SizedBox(
        height: widget.height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _fireTap,
          onLongPress: widget.onLongPress,
          child: label,
        ),
      );
    }

    return SizedBox(
      height: widget.height,
      child: RawGestureDetector(
        // 整格都能點，含標籤右邊那 6px 邊距。
        // 預設是 deferToChild＝只有畫得出東西的地方吃得到手勢，
        // 喇叭圖示那一格本來就不大，再少掉邊距更容易點空
        behavior: HitTestBehavior.opaque,
        gestures: {
          _EagerPanRecognizer:
              GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                () => _EagerPanRecognizer(),
                (r) => r
                  ..onStart = (_) {
                    _dy = 0;
                    _moved = false;
                    // 拖曳辨識器會直接吃掉手勢，長按只能自己算：
                    // 按住不動 0.5 秒就當長按（刪整軌）
                    _pressTimer?.cancel();
                    if (widget.onLongPress != null) {
                      _pressTimer = Timer(
                        const Duration(milliseconds: 500),
                        () {
                          if (!_moved && mounted) {
                            _longFired = true;
                            HapticFeedback.mediumImpact(); // 長按觸覺回饋
                            widget.onDragUpdate(0);
                            widget.onDragEnd();
                            widget.onLongPress!();
                          }
                        },
                      );
                    }
                  }
                  ..onUpdate = (d) {
                    if (_longFired) return;
                    // 往下拖是往編號小的走（時間軸上面＝編號大）
                    _dy = (_dy + d.delta.dy).clamp(
                      -(widget.maxTrack - widget.index) * widget.rowStride,
                      widget.index * widget.rowStride,
                    );
                    if (_dy.abs() > 4) {
                      _moved = true;
                      _pressTimer?.cancel();
                    }
                    widget.onDragUpdate(_dy);
                  }
                  ..onEnd = (_) {
                    _pressTimer?.cancel();
                    if (_longFired) {
                      _longFired = false;
                      _dy = 0;
                      _moved = false;
                      return;
                    }
                    if (_moved) {
                      widget.onDragEnd();
                    } else {
                      widget.onDragUpdate(0);
                      widget.onDragEnd();
                      _fireTap();
                    }
                    _dy = 0;
                    _moved = false;
                  }
                  ..onCancel = () {
                    _pressTimer?.cancel();
                    if (_longFired) {
                      _longFired = false;
                      _dy = 0;
                      _moved = false;
                      return;
                    }
                    // 手勢被中途取消（父層重建、外層捲動搶走、系統插斷）
                    // 而手指幾乎沒動＝使用者的本意就是點一下。
                    // 這裡原本直接吞掉，症狀就是「點了沒反應、要點第二次」
                    final wasTap = !_moved;
                    widget.onDragUpdate(0);
                    widget.onDragEnd();
                    if (wasTap) _fireTap();
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
  final double width;
  final ValueChanged<double> onDrag;
  final VoidCallback? onStart;

  /// 手指放開（或手勢被取消）。自動整理要等這一刻才收空隙——
  /// 拖到一半就收，剩下的片段會在手指底下一直跳
  final VoidCallback? onEnd;

  /// 熱區往片段外面多伸出去的寬度。手指瞄準的是邊緣那條把手，
  /// 接觸面有一半會落在片段外——熱區只到邊界為止的話，那一半會
  /// 打到底下的軌道背景，變成捲動時間軸
  final double overhang;

  const _TrimHandle({
    required this.isLeft,
    required this.pxPerSec,
    required this.onDrag,
    this.width = 26,
    this.overhang = 0,
    this.onStart,
    this.onEnd,
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
                ..onUpdate = ((d) => onDrag(d.delta.dx / pxPerSec))
                ..onEnd = ((_) => onEnd?.call())
                ..onCancel = (() => onEnd?.call()),
            ),
      },
      // 觸控熱區由呼叫端依片段長度給（22～40）＋往外的 overhang，
      // 視覺維持 13px 細把手——手指粗一點也按得到，畫面不變胖。
      // padding 把視覺把手推回片段邊界上：熱區往外長，圖案不動
      child: Container(
        width: width + overhang,
        color: Colors.transparent,
        padding: EdgeInsets.only(
          left: isLeft ? overhang : 0,
          right: isLeft ? 0 : overhang,
        ),
        alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
        child: Container(
          width: math.min(13, width),
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
        final h = (m * size.height * 0.86).clamp(
          1.5,
          math.max(1.5, size.height - 2),
        );
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
      final h = (m * size.height * 0.86).clamp(
        1.5,
        math.max(1.5, size.height - 2),
      );
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

/// 時間刻度尺。
/// 只畫 [viewL, viewL+viewW] 這段看得見的範圍：整條的寬度是
/// 「片長 × 縮放」，長片放大後可到十幾萬 px，全畫的話每個主刻度
/// 都要排一次文字，雙指縮放時每一幀都付這個代價
class _RulerPainter extends CustomPainter {
  final double pxPerSec;
  final Color color;
  final double viewL;
  final double viewW;

  _RulerPainter({
    required this.pxPerSec,
    required this.color,
    required this.viewL,
    required this.viewW,
  });

  /// 文字排版是刻度尺最貴的部分，而同一批標籤在縮放的每一幀
  /// 都長一樣——排好的留著重複用
  static final Map<String, TextPainter> _labelCache = {};

  TextPainter _label(String text) {
    final key = '$text|${color.toARGB32()}';
    final hit = _labelCache[key];
    if (hit != null) return hit;
    if (_labelCache.length > 300) _labelCache.clear();
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 9, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _labelCache[key] = tp;
    return tp;
  }

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

    final sub = step / 4;
    // 從可視左緣往前對齊到刻度格線，多留一格避免標籤被切半
    final left = math.max(0.0, viewL - step * pxPerSec);
    final right = math.min(size.width, viewL + viewW + 8);
    var t = (left / pxPerSec / sub).floor() * sub;
    if (t < 0) t = 0;
    for (; t * pxPerSec < right; t += sub) {
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
        _label('$m:$s').paint(canvas, Offset(x + 3, 0));
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.pxPerSec != pxPerSec ||
      old.color != color ||
      old.viewL != viewL ||
      old.viewW != viewW;
}
