import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/export_speed.dart' show fmtDuration;
import '../services/native_frames.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/gif_store.dart';
import '../services/video_engine.dart' as engine;
import '../widgets/gif_image.dart';
import 'crop_screen.dart';
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

  /// 裁切框（0~1 的比例）。null＝整張。
  /// GIF 常常只要畫面裡的某一小塊（一個表情、一個動作），
  /// 整張出去檔案大又抓不到重點
  Rect? _crop;

  Timer? _tick;
  bool _exporting = false;

  /// 成品預覽：真的做一份 GIF 出來擺在大圖那裡。
  ///
  /// 用影片播放器當預覽會騙人——GIF 只有 10~15 格、顏色被壓成 256 色，
  /// 跟原片差很多。看到的就該是最後存下去的那個東西
  String? _gifPreview;
  bool _building = false;

  /// 設定停下來之後才重做預覽（拉把手時每動一下就做一次會卡死）
  Timer? _previewTimer;

  /// 這一份預覽是照哪組設定做的（設定沒變就不用重做）
  String _previewKey = '';

  void _schedulePreview() {
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 500), _buildPreview);
  }

  Future<void> _buildPreview() async {
    if (_building || !mounted) return;
    final c = _crop;
    final cropKey = c == null
        ? 'full'
        : '${c.left.toStringAsFixed(3)},${c.top.toStringAsFixed(3)},'
              '${c.width.toStringAsFixed(3)},${c.height.toStringAsFixed(3)}';
    final key =
        '${_start.toStringAsFixed(2)}~${_end.toStringAsFixed(2)}'
        '@$_fps@$_size@$cropKey';
    if (key == _previewKey) return;
    setState(() => _building = true);
    final path = await engine.makeGifFile(
      inputPath: widget.path,
      start: _start,
      end: _end,
      fps: _fps,
      maxSide: _size,
      crop: _crop,
    );
    if (!mounted) return;
    // 做好一份就把上一份刪掉，暫存不會愈積愈多
    final old = _gifPreview;
    setState(() {
      _building = false;
      if (path != null) {
        _gifPreview = path;
        _previewKey = key;
      }
    });
    if (old != null && old != path && !GifStore.isAsset(old)) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
  }

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
    _schedulePreview();
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
    _previewTimer?.cancel();
    final gif = _gifPreview;
    if (gif != null && !GifStore.isAsset(gif)) {
      try {
        File(gif).deleteSync();
      } catch (_) {}
    }
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
    try {
      if (kIsWeb) {
        // Web 沒有 FFmpeg：整套流程點得完，但不會真的產出檔案
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.pop(context);
        _exporting = false;
        await keepScreenAwake(false);
        if (mounted) showHint(context, '這是網頁展示模式，實機才會真的做出 GIF');
        return;
      }
      // 直接用預覽那一份：預覽看到什麼，存下去就是什麼。
      // 設定沒動過就不用再做一次（_buildPreview 有指紋擋著）
      await _buildPreview();
      progress.value = 0.8;
      final gif = _gifPreview;
      if (gif == null) {
        message = 'GIF 做不出來，換個範圍或尺寸試試';
      } else {
        final r = await engine.saveGifToGallery(gif);
        ok = r.ok;
        message = r.message;
      }
    } catch (e) {
      message = '製作失敗：$e';
    } finally {
      await keepScreenAwake(false);
      _exporting = false;
    }
    if (!mounted) return;
    Navigator.pop(context); // 關進度視窗
    showHint(context, message, error: !ok);
  }

  /// 裁切：底圖抓範圍開頭那一格，用的是影片裁切同一個畫面
  Future<void> _openCrop() async {
    final p = _player;
    if (p == null) return;
    if (_playing) {
      await p.pause();
      if (mounted) setState(() => _playing = false);
    }
    Uint8List? frame = await nativeFrameAt(widget.path, _start, maxH: 1280);
    if (frame == null) {
      try {
        final one = await engine.makeThumbnails(
          widget.path,
          0.001,
          1,
          height: 1280,
          longSide: true,
          startAt: _start,
        );
        frame = one.firstOrNull;
      } catch (_) {}
    }
    frame ??= _thumbs.firstOrNull;
    if (frame == null || !mounted) {
      if (mounted) showHint(context, '抓不到畫面，沒辦法裁切', error: true);
      return;
    }
    final picked = await pickCropRect(
      context,
      frame,
      initial: _crop ?? const Rect.fromLTWH(0, 0, 1, 1),
    );
    if (picked == null || !mounted) return;
    setState(() {
      // 整張＝視同沒裁（免得多一道無謂的 crop 濾鏡）
      _crop = (picked.width > 0.995 && picked.height > 0.995) ? null : picked;
    });
    _schedulePreview();
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
                          Row(
                            children: [
                              OutlinedButton.icon(
                                onPressed: _openCrop,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _crop == null
                                      ? kText
                                      : kSelect,
                                  side: BorderSide(
                                    color: _crop == null
                                        ? kClipBorder
                                        : kSelect,
                                  ),
                                ),
                                icon: const Icon(Icons.crop, size: 16),
                                label: Text(
                                  _crop == null ? '裁切' : '已裁切',
                                  style: const TextStyle(fontSize: 12.5),
                                ),
                              ),
                              if (_crop != null) ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: () {
                                    setState(() => _crop = null);
                                    _schedulePreview();
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: kTextDim,
                                  ),
                                  child: const Text(
                                    '還原',
                                    style: TextStyle(fontSize: 12.5),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 12),
                          _chipsRow('尺寸', [320, 480, 640], _size, (v) {
                            setState(() => _size = v);
                            _schedulePreview();
                          }, (v) => '${v}p'),
                          const SizedBox(height: 10),
                          _chipsRow('流暢度', [10, 12, 15], _fps, (v) {
                            setState(() => _fps = v);
                            _schedulePreview();
                          }, (v) => '$v fps'),
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
    final gif = _gifPreview;
    // 做好成品就直接看成品：GIF 只有 10~15 格、顏色壓成 256 色，
    // 拿影片播放器當預覽會讓人以為成品比實際好看
    if (gif != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 點一下回去看原片（要重新選範圍時比較好對位）
        onTap: () => setState(() => _gifPreview = null),
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AspectRatio(
                aspectRatio: aspect,
                child: GifImage(gif, fit: BoxFit.contain),
              ),
              if (_building)
                const Positioned(
                  right: 10,
                  top: 10,
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Positioned(
                left: 10,
                top: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(kTagRadius),
                  ),
                  child: const Text(
                    '成品預覽',
                    style: TextStyle(fontSize: 10.5, color: kText),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
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
            if (_building)
              const Positioned(
                right: 10,
                top: 10,
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
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
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.62)),
              ),
              Positioned(
                left: xOf(_end),
                top: 0,
                bottom: 0,
                right: 0,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.62)),
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
                      border: Border.symmetric(
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
                    child: SizedBox(width: 2, child: ColoredBox(color: kText)),
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
  Widget _handle({
    required double x,
    required bool left,
    required double width,
  }) {
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
          _schedulePreview();
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
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
                    fontWeight: o == selected
                        ? FontWeight.w700
                        : FontWeight.w500,
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
