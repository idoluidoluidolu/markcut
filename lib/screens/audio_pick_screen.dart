import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';

import '../services/gif_strip.dart';
import '../services/gif_trim_range.dart';
import '../services/native_frames.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../theme.dart';
import '../widgets/gif_trim_strip.dart';

/// 從影片挑一段聲音：邊看影片邊選（使用者指定「給可以看影片選音訊的
/// UI，不然純音訊用眼睛看不出要選的段落」）。
///
/// 選段落的手感跟 GIF 製作同一套（那幾條是使用者定的）：預覽點一下
/// 播放／暫停、左右滑速覽；縮圖帶上的白針點哪跳哪，起訖用「設起點」
/// 「設終點」按（把手只畫、不吃觸控）；播放一律播選的那一段，播到尾巴
/// 跳回起點。跟 GIF 不一樣的地方：聲音開著（挑的就是聲音）、預設整支、
/// 進來先不播（一進來就出聲會嚇人）。
///
/// 回傳選的範圍（秒）；返回＝不加（null）
class AudioPickScreen extends StatefulWidget {
  final String path;
  final String name;

  const AudioPickScreen({super.key, required this.path, required this.name});

  /// 測試用：換掉真的播放器
  @visibleForTesting
  static PlayerX Function(String path)? debugPlayer;

  @override
  State<AudioPickScreen> createState() => _AudioPickScreenState();
}

class _AudioPickScreenState extends State<AudioPickScreen> {
  PlayerX? _player;
  bool _ready = false;
  bool _playing = false;
  double _dur = 0;

  /// 選取範圍（秒）。預設整支：從影片拿聲音，通常就是要整段的
  double _start = 0;
  double _end = 0;

  /// 播放頭位置（秒），給縮圖帶上的白針用
  final ValueNotifier<double> _pos = ValueNotifier(0);

  /// 縮圖帶（漸進：抽到一格畫一格，見 GifStripLoader）
  static const int _stripCount = 10;
  final List<Uint8List?> _cells = List<Uint8List?>.filled(_stripCount, null);
  GifStripLoader? _strip;

  /// 播放頭跟「播到段尾跳回起點」共用一條 timer（跟 GIF 製作同一套）
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p =
        AudioPickScreen.debugPlayer?.call(widget.path) ??
        makeVideoController(widget.path, system: true);
    _player = p;
    try {
      await p.initialize();
    } catch (_) {
      _leaveWithHint('影片打不開，請換一支試試');
      return;
    }
    if (!mounted) return;
    await p.setLooping(false);
    _dur = p.value.duration.inMilliseconds / 1000.0;
    if (_dur <= 0) {
      _leaveWithHint('讀不到這支影片的長度，換一支試試');
      return;
    }
    _start = 0;
    _end = _dur;
    setState(() => _ready = true);
    _tick = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      final pl = _player;
      if (pl == null || !mounted || _gesturing) return;
      final now = await pl.positionNow();
      // 拖曳中指針跟手指走，不看播放器：它還在追 seek，拿它的位置
      // 蓋回去指針就來回抖
      if (now == null || !mounted || _gesturing) return;
      final t = now.inMilliseconds / 1000.0;
      _pos.value = t;
      if (_playing && t >= _end - 0.05) {
        await pl.seekTo(Duration(milliseconds: (_start * 1000).round()));
      }
    });
    // 縮圖帶：系統硬體解碼、漸進上畫面，抽不到再退 FFmpeg。不等它：
    // 指針跟預覽從第一秒就要能拉
    unawaited(_loadStrip());
  }

  void _leaveWithHint(String msg) {
    if (!mounted) return;
    showHint(context, msg, error: true);
    Navigator.pop(context);
  }

  Future<void> _loadStrip() async {
    if (!mounted) return;
    // 解析度夾在縮圖帶實際畫出來的高度（56pt × 螢幕倍率）
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3.0;
    final maxH = math.min(168, (56 * dpr).round());
    final loader = GifStripLoader(
      duration: _dur,
      count: _stripCount,
      // Android 的抽幀器只拿關鍵幀、容忍值沒作用，細抽等於白跑
      refine: !kIsWeb && Platform.isIOS,
      fetch: (t, {required tolMs}) =>
          nativeFrameAt(widget.path, t, maxH: maxH, tolMs: tolMs),
      isBusy: () => _gesturing,
      onFrame: (i, bytes) {
        if (mounted) setState(() => _cells[i] = bytes);
      },
    );
    _strip = loader;
    await loader.run();
    if (!mounted || loader.cancelled) return;
    if (_cells.every((c) => c == null)) {
      // 系統解碼器吃不下這支：退 FFmpeg，只解關鍵幀
      final thumbs = await engine.makeThumbnails(
        widget.path,
        _dur,
        _stripCount,
        height: maxH,
        fastDecode: true,
      );
      if (!mounted || thumbs.isEmpty) return;
      setState(() {
        for (var i = 0; i < _cells.length && i < thumbs.length; i++) {
          _cells[i] = thumbs[i];
        }
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _strip?.cancel();
    _player?.dispose();
    _pos.dispose();
    super.dispose();
  }

  // ── 播放 ────────────────────────────────────────────────

  bool get _posOutsideRange {
    final t = _pos.value;
    return t < _start - 0.05 || t > _end - 0.1;
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null || !_ready) return;
    if (_playing) {
      await p.pause();
    } else {
      // 播的一律是選的那一段：指針在範圍外就從起點播
      if (_posOutsideRange) {
        _pos.value = _start;
        await p.seekTo(Duration(milliseconds: (_start * 1000).round()));
      }
      await p.play();
    }
    if (mounted) setState(() => _playing = !_playing);
  }

  /// 從起點重播：調完起訖點想「再聽一次這一段」是最高頻的動作
  Future<void> _replayFromStart() async {
    final p = _player;
    if (p == null || !_ready) return;
    _pos.value = _start;
    await p.seekTo(Duration(milliseconds: (_start * 1000).round()));
    if (!_playing) {
      await p.play();
      if (mounted) setState(() => _playing = true);
    }
  }

  void _pauseForDrag() {
    if (!_playing) return;
    _player?.pause();
    setState(() => _playing = false);
  }

  // ── 拖曳中的 seek：一次只讓一發在路上（跟 GIF 製作同一套；理由見
  // GifScreen._seekDuringDrag）────────────────────────────────
  double? _seekWanted;
  bool _seekBusy = false;
  DateTime _seekIssuedAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _seekDuringDrag(double t) {
    _pos.value = t;
    final p = _player;
    if (p == null) return;
    if (_seekBusy) {
      _seekWanted = t;
      return;
    }
    _seekBusy = true;
    unawaited(_seekChain(p, t));
  }

  Future<void> _seekChain(PlayerX p, double first) async {
    var t = first;
    try {
      while (true) {
        final since = DateTime.now().difference(_seekIssuedAt);
        if (since < const Duration(milliseconds: 40)) {
          await Future<void>.delayed(const Duration(milliseconds: 40) - since);
        }
        _seekIssuedAt = DateTime.now();
        try {
          await p.seekTo(Duration(milliseconds: (t * 1000).round()));
        } catch (_) {}
        if (!mounted) return;
        final next = _seekWanted;
        _seekWanted = null;
        if (next == null || (next - t).abs() < 0.0005) return;
        t = next;
      }
    } finally {
      _seekBusy = false;
    }
  }

  // ── 速覽：預覽上左右滑、縮圖帶上拖白針 ───────────────────────
  double? _scrubFrom;
  double _scrubAcc = 0;

  bool get _gesturing => _scrubFrom != null;

  void _scrubBegin() {
    _scrubFrom = _pos.value;
    _scrubAcc = 0;
    _pauseForDrag();
  }

  void _scrubBySeconds(double dt) {
    final from = _scrubFrom;
    if (from == null) return;
    _scrubAcc += dt;
    _seekDuringDrag((from + _scrubAcc).clamp(0.0, _dur));
  }

  void _scrubEnd() {
    if (_scrubFrom == null) return;
    _scrubFrom = null;
    _seekDuringDrag(_pos.value);
  }

  void _stripTap(double t) {
    _pauseForDrag();
    _pos.value = t;
    _player?.seekTo(Duration(milliseconds: (t * 1000).round()));
  }

  void _stripDragStart(double t) {
    _scrubBegin();
    _scrubFrom = t;
    _scrubBySeconds(0);
  }

  /// 把指針現在的位置設成起點／終點。規則跟 GIF 製作同一份（見
  /// gif_trim_range.dart）：按下去永遠算數，跑到另一端外側就整段平移
  void _setEdgeHere({required bool start}) {
    final t = _pos.value.clamp(0.0, _dur);
    final r = start
        ? trimSetStart(t, _start, _end, _dur)
        : trimSetEnd(t, _start, _end, _dur);
    setState(() {
      _start = r.start;
      _end = r.end;
    });
  }

  void _done() {
    _player?.pause();
    Navigator.pop<TrimRange>(context, (start: _start, end: _end));
  }

  // ── 畫面 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(backgroundColor: kBg),
    body: SafeArea(
      child: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(child: _preview()),
                _playbackRow(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _rangeReadout(),
                      const SizedBox(height: 8),
                      GifTrimStrip(
                        dur: _dur,
                        start: _start,
                        end: _end,
                        pos: _pos,
                        cells: _cells,
                        onTapAt: _stripTap,
                        onScrubStart: _stripDragStart,
                        onScrubBy: _scrubBySeconds,
                        onScrubEnd: _scrubEnd,
                      ),
                      const SizedBox(height: 16),
                      primaryAction(
                        label: '加入音訊',
                        icon: Icons.graphic_eq,
                        onPressed: _done,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );

  Widget _preview() {
    final p = _player!;
    final size = p.value.size;
    final aspect = (size.width > 0 && size.height > 0)
        ? size.width / size.height
        : 16 / 9;
    return LayoutBuilder(
      builder: (context, cons) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _togglePlay,
        // 在預覽上左右滑＝速覽（「拖底片」語意：手指往左＝時間往前，
        // 跟 GIF 製作、捲時間軸同一個手感）
        onHorizontalDragStart: (_) => _scrubBegin(),
        onHorizontalDragUpdate: (d) => _scrubBySeconds(
          -d.delta.dx / math.max(1, cons.maxWidth) * _dur,
        ),
        onHorizontalDragEnd: (_) => _scrubEnd(),
        onHorizontalDragCancel: _scrubEnd,
        child: Container(
          color: kPreviewBg,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AspectRatio(aspectRatio: aspect, child: p.view()),
              // 暫停時給一顆播放鈕；播放中畫面乾淨
              if (!_playing)
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow, size: 34, color: kText),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playbackRow() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 16, 0),
    child: Row(
      children: [
        IconButton(
          icon: Icon(
            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 26,
            color: kText,
          ),
          visualDensity: VisualDensity.compact,
          onPressed: _togglePlay,
        ),
        IconButton(
          icon: const Icon(Icons.replay_rounded, size: 21, color: kTextDim),
          visualDensity: VisualDensity.compact,
          tooltip: '從起點重播',
          onPressed: _replayFromStart,
        ),
        const Spacer(),
        ValueListenableBuilder<double>(
          valueListenable: _pos,
          builder: (context, t, _) => Text(
            '${t.toStringAsFixed(1)}s',
            style: const TextStyle(
              fontSize: 11.5,
              color: kTextDim,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _edgeBtn(String label, bool start) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _setEdgeHere(start: start),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: kClipBorder),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11, color: kText)),
      ),
    ),
  );

  /// 兩顆設定鈕＋右邊的長度（不顯示起訖秒數：範圍看縮圖帶本身就夠，
  /// 跟 GIF 製作同一個決定）
  Widget _rangeReadout() => Row(
    children: [
      _edgeBtn('設起點', true),
      _edgeBtn('設終點', false),
      const Spacer(),
      Text(
        '長度 ${(_end - _start).toStringAsFixed(1)} 秒',
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: kText,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}
