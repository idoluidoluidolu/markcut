import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/export_speed.dart' show fmtDuration;
import '../services/native_frames.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../theme.dart';
import '../widgets/swipe_back.dart';

/// 專屬的 GIF 製作頁：選一支影片進來，拉兩個把手決定要剪哪一段，
/// 挑尺寸跟流暢度，直接出 GIF。
///
/// 不走影片編輯器——做 GIF 的人只想要「這幾秒變成 GIF」，
/// 不需要時間軸、多軌、浮水印那一整套。這一頁只有三件事：
/// 預覽、剪多長、出檔。
class GifScreen extends StatefulWidget {
  final String path;
  final String name;

  const GifScreen({super.key, required this.path, required this.name});

  @override
  State<GifScreen> createState() => _GifScreenState();
}

class _GifScreenState extends State<GifScreen> {
  PlayerX? _player;
  bool _ready = false;
  bool _playing = false;
  double _dur = 0;

  /// 選取範圍（秒）。進場預設整支，超過 15 秒先停在前 15 秒——
  /// GIF 的甜蜜點就是幾秒鐘，預設值該直接落在合理範圍
  double _start = 0;
  double _end = 0;

  /// 播放頭位置（秒），給進度細線用
  final ValueNotifier<double> _pos = ValueNotifier(0);

  List<Uint8List> _thumbs = const [];

  /// GIF 長邊上限與影格率
  int _size = 480;
  int _fps = 12;

  Timer? _tick;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = makeVideoController(widget.path);
    _player = p;
    try {
      await p.initialize();
    } catch (_) {
      if (mounted) {
        showHint(context, '影片打不開，請換一支試試', error: true);
        Navigator.pop(context);
      }
      return;
    }
    await p.setLooping(false);
    _dur = p.value.duration.inMilliseconds / 1000.0;
    _start = 0;
    _end = math.min(_dur, 15);
    if (mounted) setState(() => _ready = true);
    // 縮圖帶：先走系統硬體解碼，抽不到再退 FFmpeg
    var thumbs = await nativeStrip(widget.path, _dur, 10, maxH: 120);
    if (thumbs.isEmpty) {
      thumbs = await engine.makeThumbnails(widget.path, _dur, 10, height: 120);
    }
    if (mounted) setState(() => _thumbs = thumbs);
    // 播放頭跟出界檢查共用一條 timer：拉把手時即時看到位置，
    // 播放時碰到迄點就跳回起點循環——預覽跟成品的循環感一致
    _tick = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      final pl = _player;
      if (pl == null || !mounted) return;
      final now = await pl.positionNow();
      if (now == null || !mounted) return;
      final t = now.inMilliseconds / 1000.0;
      _pos.value = t;
      if (_playing && t >= _end - 0.05) {
        await pl.seekTo(Duration(milliseconds: (_start * 1000).round()));
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _player?.dispose();
    _pos.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null || !_ready) return;
    if (_playing) {
      await p.pause();
    } else {
      // 從起點播：預覽的就是將來 GIF 會循環的那一段
      final t = _pos.value;
      if (t < _start - 0.05 || t > _end - 0.1) {
        await p.seekTo(Duration(milliseconds: (_start * 1000).round()));
      }
      await p.play();
    }
    setState(() => _playing = !_playing);
  }

  Future<void> _seek(double t) async {
    final p = _player;
    if (p == null) return;
    _pos.value = t;
    await p.seekTo(Duration(milliseconds: (t * 1000).round()));
  }

  double get _len => math.max(0.1, _end - _start);

  /// 中繼影片的輸出尺寸：素材原比例、長邊不超過選的 GIF 尺寸。
  /// 先做大再縮小是白編碼一趟，中繼檔直接做到剛好
  (int, int) _outSize() {
    final s = _player?.value.size ?? Size.zero;
    var vw = s.width, vh = s.height;
    if (vw < 2 || vh < 2) (vw, vh) = (480, 480);
    var k = _size / math.max(vw, vh);
    if (k > 1) k = 1;
    int ev(double v) => math.max(2, (v * k / 2).round() * 2);
    return (ev(vw), ev(vh));
  }

  Future<void> _export() async {
    if (_exporting) return;
    _exporting = true;
    final p = _player;
    if (p != null && _playing) {
      await p.pause();
      setState(() => _playing = false);
    }
    if (!mounted) {
      _exporting = false;
      return;
    }

    final progress = ValueNotifier<double>(0);
    final startedAt = DateTime.now();
    var cancelRequested = false;

    String etaText(double v) {
      final gone = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
      if (v < 0.02 || gone < 3) return '估算中…';
      return '剩下約 ${fmtDuration(gone / v - gone)}';
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (context, setDialog) => AlertDialog(
            title: const Text('製作 GIF 中…'),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: v > 0 ? v : null),
                  const SizedBox(height: 12),
                  Text('${(v * 100).toStringAsFixed(0)} %'),
                  const SizedBox(height: 4),
                  Text(
                    etaText(v),
                    style: const TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: cancelRequested
                    ? null
                    : () {
                        setDialog(() => cancelRequested = true);
                        engine.cancelExport();
                      },
                child: Text(cancelRequested ? '取消中…' : '取消'),
              ),
            ],
          ),
        ),
      ),
    );
    await keepScreenAwake(true);

    String message;
    var ok = false;
    var cancelled = false;
    try {
      final s = _player?.value.size ?? Size.zero;
      final (outW, outH) = _outSize();
      final src = MediaSource(
        path: widget.path,
        name: widget.name,
        kind: ClipKind.video,
        duration: _dur,
        w: s.width.round(),
        h: s.height.round(),
      );
      final result = await engine.exportVideoToGallery(
        ExportSpec(
          sources: [src],
          clips: [
            TimelineClip(
              id: 1,
              sourceIndex: 0,
              trimStart: _start,
              trimEnd: _end,
              offset: 0,
              track: 0,
            ),
          ],
          timelineDuration: _len,
          speed: 1.0,
          watermarkPng: null,
          outW: outW,
          outH: outH,
          gif: true,
          gifFps: _fps,
          gifMaxSide: _size,
        ),
        onProgress: (v) => progress.value = v,
      );
      ok = result.ok;
      message = result.message;
      cancelled = result.cancelled;
    } catch (e) {
      message = '製作失敗：$e';
    } finally {
      await keepScreenAwake(false);
      _exporting = false;
    }
    if (!mounted) return;
    Navigator.pop(context); // 關進度視窗
    if (cancelled) return;
    showHint(context, message, error: !ok);
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg,
          title: const Text(
            '製作 GIF',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: !_ready
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(child: _preview()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _rangeReadout(),
                          const SizedBox(height: 8),
                          _trimStrip(),
                          const SizedBox(height: 16),
                          _chipsRow(
                            '尺寸',
                            [320, 480, 640],
                            _size,
                            (v) => setState(() => _size = v),
                            (v) => '${v}p',
                          ),
                          const SizedBox(height: 10),
                          _chipsRow(
                            '流暢度',
                            [10, 12, 15],
                            _fps,
                            (v) => setState(() => _fps = v),
                            (v) => '$v fps',
                          ),
                          const SizedBox(height: 16),
                          primaryAction(
                            label: '做成 GIF',
                            icon: Icons.gif_box_outlined,
                            onPressed: _exporting ? null : _export,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _preview() {
    final p = _player!;
    final size = p.value.size;
    final aspect = (size.width > 0 && size.height > 0)
        ? size.width / size.height
        : 16 / 9;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlay,
      child: Container(
        color: Colors.black,
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
    );
  }

  Widget _rangeReadout() {
    final over = _len > 15;
    return Row(
      children: [
        Text(
          '${_start.toStringAsFixed(1)} s — ${_end.toStringAsFixed(1)} s',
          style: const TextStyle(
            fontSize: 12.5,
            color: kTextDim,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        Text(
          over
              ? '長度 ${_len.toStringAsFixed(1)} 秒·建議 15 秒內'
              : '長度 ${_len.toStringAsFixed(1)} 秒',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: over ? kSelect : kText,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// 縮圖帶＋兩個把手。把手蓋在縮圖上，看得到自己剪掉了哪些畫面
  Widget _trimStrip() {
    return SizedBox(
      height: 56,
      child: LayoutBuilder(
        builder: (context, cons) {
          final w = cons.maxWidth;
          double xOf(double t) => _dur <= 0 ? 0 : w * (t / _dur);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // 縮圖帶
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _thumbs.isEmpty
                      ? const ColoredBox(color: kPanelHi)
                      : Row(
                          children: [
                            for (final b in _thumbs)
                              Expanded(
                                child: Image.memory(
                                  b,
                                  fit: BoxFit.cover,
                                  height: 56,
                                  gaplessPlayback: true,
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              // 範圍外壓暗
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: xOf(_start),
                child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.62)),
              ),
              Positioned(
                left: xOf(_end),
                top: 0,
                bottom: 0,
                right: 0,
                child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.62)),
              ),
              // 選取範圍的上下框線
              Positioned(
                left: xOf(_start),
                width: math.max(0, xOf(_end) - xOf(_start)),
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border:
                          Border.symmetric(
                            horizontal: BorderSide(color: kSelect, width: 2),
                          ),
                    ),
                  ),
                ),
              ),
              // 播放頭細線
              ValueListenableBuilder<double>(
                valueListenable: _pos,
                builder: (context, t, _) => Positioned(
                  left: xOf(t.clamp(0, _dur)) - 1,
                  top: -2,
                  bottom: -2,
                  child: const IgnorePointer(
                    child: SizedBox(
                      width: 2,
                      child: ColoredBox(color: kText),
                    ),
                  ),
                ),
              ),
              _handle(x: xOf(_start), left: true, width: w),
              _handle(x: xOf(_end), left: false, width: w),
            ],
          );
        },
      ),
    );
  }

  /// 一個把手：44pt 觸控區、視覺上是一根圓頭短棒
  Widget _handle({required double x, required bool left, required double width}) {
    return Positioned(
      left: x - 22,
      top: -6,
      bottom: -6,
      width: 44,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          final t = ((x + d.delta.dx) / width * _dur).clamp(0.0, _dur);
          setState(() {
            if (left) {
              _start = math.min(t, _end - 0.2);
            } else {
              _end = math.max(t, _start + 0.2);
            }
          });
          // 拉哪個把手，畫面就停在哪個把手的位置——邊拉邊看剪在哪
          _seek(left ? _start : _end);
          final p = _player;
          if (_playing && p != null) {
            p.pause();
            _playing = false;
          }
        },
        child: Center(
          child: Container(
            width: 5,
            height: 40,
            decoration: BoxDecoration(
              color: kSelect,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chipsRow<T>(
    String label,
    List<T> options,
    T selected,
    void Function(T) onPick,
    String Function(T) fmt,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: kText,
            ),
          ),
        ),
        for (final o in options) ...[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => onPick(o),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: o == selected ? kPanelHi : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: o == selected ? kSelect : kClipBorder,
                  ),
                ),
                child: Text(
                  fmt(o),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        o == selected ? FontWeight.w700 : FontWeight.w500,
                    color: o == selected ? kText : kTextDim,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
