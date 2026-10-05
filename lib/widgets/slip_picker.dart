import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';

import '../services/video_controller.dart';
import '../theme.dart';
import 'slip_film.dart';
import 'slip_strip.dart';

/// 換段：片段長度不變，換成原片的另一段。
///
/// 使用者從畫布上三個方向挑了「放大膠卷」：
/// - 大預覽循環播「這一段」，聲音開著——看得到也聽得到選的是什麼
/// - 下面的放大膠卷：琥珀框固定在中間，左右拖膠卷＝細調（片段越短放得
///   越大，長片也調得準）
/// - 上面那條細的整支縮圖：點一下或拖它＝一次跳很遠
/// - 放手才套用（要重組合成），套用後從新的開頭自動播
///
/// 播放器開不起來（或測試沒給）時退回只看開頭畫面：按來源時間抽一張，
/// 一樣能換段
class SlipPicker extends StatefulWidget {
  const SlipPicker({
    super.key,
    required this.duration,
    required this.start,
    required this.length,
    required this.loadFrame,
    required this.onCommit,
    this.loadThumbnail,
    this.playPath,
    this.volume = 1,
    this.aspect = 1,
  });

  /// 原片長度（秒）
  final double duration;

  /// 片段目前的起點（原片秒）
  final double start;

  /// 片段長度（秒），換段不會改它
  final double length;

  /// 沒有播放器時的大預覽：抽 [seconds] 那一格
  final Future<Uint8List?> Function(double seconds) loadFrame;

  /// 膠卷與整支縮圖用的小圖；null＝跟大預覽同一支
  final Future<Uint8List?> Function(double seconds)? loadThumbnail;

  /// 放手時回報新的起點
  final ValueChanged<double> onCommit;

  /// 大預覽要播的檔案；null＝只看開頭畫面
  final String? playPath;

  /// 大預覽的音量（照片段自己的音量）
  final double volume;

  /// 原片長寬比（寬÷高），縮圖照這個比例排
  final double aspect;

  /// 測試換掉播放器（測試主機沒有原生播放器）
  @visibleForTesting
  static PlayerX Function(String path)? debugPlayer;

  @override
  State<SlipPicker> createState() => _SlipPickerState();
}

class _SlipPickerState extends State<SlipPicker> {
  late double _start = widget.start;
  final _frames = <({int at, bool preview}), Uint8List?>{};
  List<({int at, bool preview})> _wanted = [];
  bool _loading = false;

  PlayerX? _player;

  /// 播放器開好了：大預覽是活的
  bool _ready = false;

  /// 播放器開不起來：只看開頭畫面，播放鈕收起來
  bool _noPlayer = false;
  bool _playing = false;

  /// 正在拖膠卷／整支縮圖
  bool _gesturing = false;

  /// 播放位置（原片秒）：膠卷框裡的白線
  late final ValueNotifier<double> _pos = ValueNotifier(widget.start);
  Timer? _tick;

  double get _end => _start + widget.length;

  static Duration _ms(double s) => Duration(milliseconds: (s * 1000).round());

  @override
  void initState() {
    super.initState();
    final path = widget.playPath;
    if (path == null) {
      _noPlayer = true;
    } else {
      unawaited(_openPlayer(path));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _player?.dispose();
    _pos.dispose();
    super.dispose();
  }

  Future<void> _openPlayer(String path) async {
    PlayerX? p;
    try {
      p =
          SlipPicker.debugPlayer?.call(path) ??
          makeVideoController(path, system: true);
      await p.initialize();
      if (mounted) {
        await p.setLooping(false);
        await p.setVolume(widget.volume.clamp(0.0, 1.0));
        await p.seekTo(_ms(_start));
      }
    } catch (_) {
      // 開不起來：留在只看開頭畫面（拖膠卷照樣能換段）
      p?.dispose();
      if (mounted) setState(() => _noPlayer = true);
      return;
    }
    if (!mounted) {
      p.dispose();
      return;
    }
    setState(() {
      _player = p;
      _ready = true;
    });
    // 播到段尾跳回段頭（循環播這一段）；白線也靠它走
    _tick = Timer.periodic(const Duration(milliseconds: 60), (_) => _onTick());
  }

  Future<void> _onTick() async {
    final p = _player;
    if (p == null || !_playing || _gesturing) return;
    try {
      final now = await p.positionNow();
      if (now == null || !mounted || !_playing || _gesturing) return;
      final t = now.inMilliseconds / 1000.0;
      if (t >= _end - 0.05) {
        _pos.value = _start;
        await p.seekTo(_ms(_start));
      } else {
        _pos.value = t;
      }
    } catch (_) {
      // 表收起來、播放器剛釋放：這一下作罷
    }
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null) return;
    try {
      if (_playing) {
        setState(() => _playing = false);
        await p.pause();
        return;
      }
      // 停在段外（或段尾）：從段頭播
      final t = _pos.value;
      if (t < _start - 0.05 || t > _end - 0.1) {
        _pos.value = _start;
        await p.seekTo(_ms(_start));
      }
      if (!mounted) return;
      setState(() => _playing = true);
      await p.play();
    } catch (_) {}
  }

  Future<void> _playFromStart() async {
    final p = _player;
    if (p == null) return;
    _pos.value = _start;
    setState(() => _playing = true);
    try {
      await p.seekTo(_ms(_start));
      if (!mounted || !_playing) return;
      await p.play();
    } catch (_) {}
  }

  /// 拖膠卷／整支縮圖的每一下：先停播，畫面跟著跳到新的開頭
  void _moveTo(double s) {
    if (!_gesturing) {
      _gesturing = true;
      if (_playing) {
        _playing = false;
        unawaited(_player?.pause());
      }
    }
    setState(() => _start = s);
    _pos.value = s;
    _seekDuringDrag(s);
  }

  /// 放手：套用，從新的開頭播
  void _release() {
    _gesturing = false;
    _seekWanted = null;
    widget.onCommit(_start);
    unawaited(_playFromStart());
  }

  // 拖曳中的 seek：同一時間只發一個，最多每 40ms 一次；中間的位置只留
  // 最新那個（跟挑音訊那頁同一套）
  double? _seekWanted;
  bool _seekBusy = false;
  DateTime _seekAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _seekDuringDrag(double t) {
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
        final since = DateTime.now().difference(_seekAt);
        if (since < const Duration(milliseconds: 40)) {
          await Future<void>.delayed(const Duration(milliseconds: 40) - since);
        }
        if (!mounted) return;
        _seekAt = DateTime.now();
        try {
          await p.seekTo(_ms(t));
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

  int _key(double seconds) => (seconds * 1000).round().clamp(
    0,
    math.max(0, (widget.duration * 1000).ceil() - 1),
  );

  /// 一次只解一張。手指移動時替換待抽清單：沒有播放器時開頭大圖最先，
  /// 再來是膠卷上離框最近的格子，最後才是整支縮圖。快取依實際要求的
  /// 時間查找，晚到的舊畫面不會貼到新的時間標籤下
  void _requestFrames(SlipFilmGeometry film, int overview) {
    final center = _start + widget.length / 2;
    final filmTimes = [
      for (final k in film.visibleTiles(_start)) film.tileTime(k),
    ]..sort((a, b) => (a - center).abs().compareTo((b - center).abs()));
    final wanted = {
      if (!_ready) (at: _key(_start), preview: true),
      for (final t in filmTimes) (at: _key(t), preview: false),
      for (var i = 0; i < overview; i++)
        (
          at: _key(SlipStrip.tileTime(i, overview, widget.duration)),
          preview: false,
        ),
    }.toList();
    if (listEquals(wanted, _wanted)) return;
    _wanted = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadFrames());
    });
  }

  Future<void> _loadFrames() async {
    if (_loading) return;
    _loading = true;
    try {
      while (mounted) {
        final pending = _wanted.where((t) => !_frames.containsKey(t));
        if (pending.isEmpty) break;
        final at = pending.first;
        Uint8List? frame;
        try {
          final load = at.preview
              ? widget.loadFrame
              : (widget.loadThumbnail ?? widget.loadFrame);
          frame = await load(at.at / 1000);
        } catch (_) {
          // 壞檔／離開畫面：顯示無法預覽，不以舊圖冒充。
        }
        if (!mounted) return;
        setState(() {
          _frames[at] = frame;
          // 大圖只保留最近幾個開頭；縮圖用另一組小圖，不隨手指累積大圖。
          _evict((k) => k.preview, 8);
          _evict((k) => true, 160);
        });
      }
    } finally {
      _loading = false;
    }
  }

  /// 符合 [test] 的快取超過 [max] 張：從最舊、而且現在用不到的丟起
  void _evict(bool Function(({int at, bool preview})) test, int max) {
    while (_frames.keys.where(test).length > max) {
      final old = _frames.keys.where(
        (k) => test(k) && !_wanted.contains(k),
      );
      if (old.isEmpty) return;
      _frames.remove(old.first);
    }
  }

  Uint8List? _thumb(double t) => _frames[(at: _key(t), preview: false)];

  static String _time(double seconds) {
    final cs = (seconds * 100).round();
    final minutes = (cs ~/ 6000).toString().padLeft(2, '0');
    final secs = (cs ~/ 100 % 60).toString().padLeft(2, '0');
    return '$minutes:$secs.${(cs % 100).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: LayoutBuilder(
        builder: (context, box) {
          final film = SlipFilmGeometry(
            width: box.maxWidth,
            height: SlipFilm.height,
            duration: widget.duration,
            length: widget.length,
            aspect: widget.aspect,
          );
          final overview = SlipStrip.tileCount(
            box.maxWidth,
            aspect: widget.aspect,
          );
          _requestFrames(film, overview);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    '換段',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                ],
              ),
              Expanded(child: _preview()),
              const SizedBox(height: 6),
              _playbackRow(),
              const SizedBox(height: 6),
              SlipStrip(
                key: const ValueKey('slip-strip'),
                frames: const [],
                duration: widget.duration,
                start: _start,
                length: widget.length,
                aspect: widget.aspect,
                frameAt: _thumb,
                onChanged: _moveTo,
                onEnd: _release,
              ),
              const SizedBox(height: 12),
              SlipFilm(
                key: const ValueKey('slip-film'),
                geometry: film,
                start: _start,
                frameAt: _thumb,
                onChanged: _moveTo,
                onEnd: _release,
                playhead: _pos,
                showPlayhead: _playing,
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _playbackRow() => Row(
    children: [
      if (!_noPlayer) ...[
        IconButton(
          key: const ValueKey('slip-play'),
          icon: Icon(
            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 26,
            color: kText,
          ),
          visualDensity: VisualDensity.compact,
          onPressed: _ready ? _togglePlay : null,
        ),
        IconButton(
          key: const ValueKey('slip-replay'),
          icon: const Icon(Icons.replay_rounded, size: 21, color: kTextDim),
          visualDensity: VisualDensity.compact,
          tooltip: '從這段開頭重播',
          onPressed: _ready ? _playFromStart : null,
        ),
      ],
      // 只寫起訖，不另加說明字；大字放不下就縮小，不換行也不溢位
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              '${_time(_start)} – ${_time(_end)}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: kText,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    ],
  );

  /// 大預覽：點一下播／停。播放器還沒好（或開不起來）時是開頭那一格
  Widget _preview() {
    final p = _ready ? _player : null;
    final size = p?.value.size ?? Size.zero;
    final aspect = size.width > 0 && size.height > 0
        ? size.width / size.height
        : (widget.aspect > 0 ? widget.aspect : 1.0);
    return Semantics(
      label: '這一段 ${_time(_start)}',
      button: p != null,
      child: GestureDetector(
        key: const ValueKey('slip-preview'),
        behavior: HitTestBehavior.opaque,
        onTap: p == null ? null : _togglePlay,
        child: Center(
          child: AspectRatio(
            aspectRatio: aspect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kTagRadius),
              child: ColoredBox(
                color: Colors.black,
                child: p == null ? _still() : _live(p),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _live(PlayerX p) => Stack(
    fit: StackFit.expand,
    children: [
      p.view(),
      // 暫停時給一顆播放鈕；播放中畫面乾淨
      if (!_playing)
        Center(
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow, size: 34, color: kText),
          ),
        ),
    ],
  );

  Widget _still() {
    final key = (at: _key(_start), preview: true);
    final bytes = _frames[key];
    final pending = !_frames.containsKey(key);
    return bytes != null
        ? Image.memory(
            bytes,
            key: ValueKey(key),
            fit: BoxFit.contain,
            gaplessPlayback: true,
          )
        : Center(
            child: Text(
              pending ? '載入中…' : '無法預覽',
              style: const TextStyle(fontSize: 12, color: kTextDim),
            ),
          );
  }
}
