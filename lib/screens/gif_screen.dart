import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/export_speed.dart' show fmtDuration;
import '../services/native_frames.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/gif_store.dart';
import '../services/video_engine.dart' as engine;
import 'crop_screen.dart';
import '../theme.dart';

/// 專屬的 GIF 製作頁：選一支影片進來，拉兩個把手決定要剪哪一段，
/// 挑尺寸跟順暢度，直接出 GIF。
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

  /// 播放速度倍率。GIF 常常要放慢看細節、或加快變成有梗的節奏
  double _speed = 1.0;

  /// 拖把手時的起手值與累計位移。
  ///
  /// 本來每一格都拿「上一格畫出來的 x」再加這一格的位移去算時間——
  /// 但那個 x 是上一次 build 的結果，而 setState 又會重新 build，
  /// 等於把自己的輸出接回輸入，指針就會來回抖。起手記一次、之後
  /// 只累加手指的位移，中間不看畫面
  double? _dragFrom;
  double _dragAcc = 0;

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

  /// 已經做過的預覽：設定指紋 → 檔案路徑。
  ///
  /// 每換一個尺寸／順暢度都要等 FFmpeg 跑一次，來回比較兩個值就得
  /// 等兩次。做過的留著，切回去是零等待——實際使用就是在幾個值之間
  /// 來回看，所以命中率很高
  final Map<String, String> _previewCache = {};

  /// 這一輪設定的指紋（[fps]/[size] 可以代入別的值：預先做隔壁選項用）
  String _keyFor({int? fps, int? size}) {
    final c = _crop;
    final cropKey = c == null
        ? 'full'
        : '${c.left.toStringAsFixed(3)},${c.top.toStringAsFixed(3)},'
              '${c.width.toStringAsFixed(3)},${c.height.toStringAsFixed(3)}';
    return '${_start.toStringAsFixed(2)}~${_end.toStringAsFixed(2)}'
        '@${fps ?? _fps}@${size ?? _size}@$cropKey@$_speed';
  }

  // ── GIF 成果播放器：把做好的 GIF 解成幀，用自己的時鐘播 ──
  //
  // 大預覽就是 GIF 本人（顏色/格數照實），但不交給元件自由輪播：
  // 時鐘在我們手上，才能（1）播放/暫停（2）把「現在放到段落哪裡」
  // 映射回修剪條上的指針（使用者：預覽一樣是 GIF，但要顯示指針
  // 位置，才知道自己放到哪）
  final List<ui.Image> _gifFrames = [];
  final List<int> _gifEndMs = [];
  int _gifLoopMs = 0;
  double _gifMs = 0;
  int _gifDecodeSeq = 0;
  final ValueNotifier<int> _gifFrameVN = ValueNotifier(0);
  Timer? _gifTick;

  bool get _gifMode => _gifFrames.isNotEmpty && _gifLoopMs > 0;
  double get _rangeLen => math.max(0.05, _end - _start);

  Future<void> _decodeGifFrames(String path) async {
    final seq = ++_gifDecodeSeq;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frames = <ui.Image>[];
      final ends = <int>[];
      var acc = 0;
      final n = math.min(codec.frameCount, 400);
      for (var i = 0; i < n; i++) {
        final f = await codec.getNextFrame();
        if (!mounted || seq != _gifDecodeSeq) {
          f.image.dispose();
          codec.dispose();
          for (final im in frames) {
            im.dispose();
          }
          return;
        }
        frames.add(f.image);
        final d = f.duration.inMilliseconds;
        acc += d < 10 ? 100 : d;
        ends.add(acc);
      }
      codec.dispose();
      if (!mounted || seq != _gifDecodeSeq) {
        for (final im in frames) {
          im.dispose();
        }
        return;
      }
      for (final im in _gifFrames) {
        im.dispose();
      }
      setState(() {
        _gifFrames
          ..clear()
          ..addAll(frames);
        _gifEndMs
          ..clear()
          ..addAll(ends);
        _gifLoopMs = acc;
        _gifMs = 0;
        _gifFrameVN.value = 0;
      });
      _pos.value = _start;
      _ensureGifTick();
    } catch (_) {}
  }

  void _ensureGifTick() {
    _gifTick ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted || !_gifMode || !_playing) return;
      _gifMs = (_gifMs + 33) % _gifLoopMs;
      _syncGifFrame();
    });
  }

  /// 由 _gifMs 更新目前幀與修剪條上的指針位置（比例對映回段落）
  void _syncGifFrame() {
    var lo = 0;
    var hi = _gifEndMs.length - 1;
    final ms = _gifMs.clamp(0, _gifLoopMs - 1);
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_gifEndMs[mid] > ms) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    _gifFrameVN.value = lo;
    _pos.value = _start + (_gifMs / _gifLoopMs) * _rangeLen;
  }

  /// 指針位置（來源秒）→ GIF 時鐘（比例對映）
  void _gifSeekToSrc(double t) {
    if (!_gifMode) return;
    final frac = ((t - _start) / _rangeLen).clamp(0.0, 0.999);
    _gifMs = frac * _gifLoopMs;
    _syncGifFrame();
  }

  void _schedulePreview() {
    final key = _keyFor();
    if (key == _previewKey) return;
    // 這組設定做過了：直接換上去，一格都不用等
    final hit = _previewCache[key];
    if (hit != null) {
      _previewTimer?.cancel();
      setState(() {
        _gifPreview = hit;
        _previewKey = key;
      });
      unawaited(_decodeGifFrames(hit));
      // 換上快取＝閒置：接著把這一組的隔壁選項也補起來
      unawaited(_prefetchSiblings());
      return;
    }
    _previewTimer?.cancel();
    // 250ms：手指離開就開始做。太長會像卡住，太短則拉把手時每動
    // 一格都在跑
    _previewTimer = Timer(const Duration(milliseconds: 250), _buildPreview);
  }

  Future<void> _buildPreview() async {
    if (_building || !mounted) return;
    final key = _keyFor();
    if (key == _previewKey) return;
    final hit = _previewCache[key];
    if (hit != null) {
      setState(() {
        _gifPreview = hit;
        _previewKey = key;
      });
      unawaited(_decodeGifFrames(hit));
      return;
    }
    setState(() => _building = true);
    final path = await engine.makeGifFile(
      inputPath: widget.path,
      start: _start,
      end: _end,
      fps: _fps,
      maxSide: _size,
      crop: _crop,
      speed: _speed,
    );
    if (!mounted) return;
    setState(() {
      _building = false;
      if (path != null) {
        _gifPreview = path;
        _previewKey = key;
        _previewCache[key] = path;
      }
    });
    if (path != null) unawaited(_decodeGifFrames(path));
    // 跑完的時候設定可能又被改過了（使用者連按了好幾個），
    // 那就接著做最新的那一組
    if (mounted && _keyFor() != _previewKey) _schedulePreview();
    _trimCache();
    // 目前這組做好了＝進入閒置：把隔壁選項在背景先做起來
    if (mounted && _keyFor() == _previewKey) unawaited(_prefetchSiblings());
  }

  /// 背景有沒有正在預先做的東西（一次只跑一個，不跟使用者搶）
  bool _prefetching = false;

  /// 把「其他尺寸 × 目前順暢度」「目前尺寸 × 其他順暢度」預先做起來。
  ///
  /// 使用者實際的用法就是在幾個選項之間來回點著比較——等他點的時候
  /// 才開始做，每一下都要等 FFmpeg 跑一輪。趁目前這組做完的閒置時間
  /// 先做，點過去就是快取直接換上，零等待。
  /// 一次只跑一支；使用者改了任何設定就立刻讓路
  Future<void> _prefetchSiblings() async {
    if (_prefetching || kIsWeb) return;
    _prefetching = true;
    try {
      final baseKey = _previewKey;
      final jobs = <(int fps, int size)>[
        for (final s in [320, 480, 640])
          if (s != _size) (_fps, s),
        for (final f in [10, 12, 15])
          if (f != _fps) (f, _size),
      ];
      for (final (fps, size) in jobs) {
        if (!mounted) return;
        // 設定變了或使用者的 build 正在跑：讓路，等下一次閒置再說
        if (_building || _keyFor() != baseKey) return;
        final key = _keyFor(fps: fps, size: size);
        if (_previewCache.containsKey(key)) continue;
        final path = await engine.makeGifFile(
          inputPath: widget.path,
          start: _start,
          end: _end,
          fps: fps,
          maxSide: size,
          crop: _crop,
          speed: _speed,
        );
        if (!mounted) return;
        if (path != null && !_previewCache.containsKey(key)) {
          _previewCache[key] = path;
          _trimCache();
        }
      }
    } finally {
      _prefetching = false;
    }
  }

  /// 快取只留最近 12 份，多的連檔案一起刪——一份 480p 的 GIF
  /// 幾百 KB，放著不管暫存會愈積愈大
  void _trimCache() {
    while (_previewCache.length > 12) {
      final k = _previewCache.keys.first;
      final p = _previewCache.remove(k);
      if (p == null || p == _gifPreview || GifStore.isAsset(p)) continue;
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = makeVideoController(widget.path, system: true);
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
      if (_gifMode) return; // 指針由 GIF 時鐘驅動
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
    _gifTick?.cancel();
    for (final im in _gifFrames) {
      im.dispose();
    }
    _gifFrameVN.dispose();
    _previewTimer?.cancel();
    for (final p in {..._previewCache.values, ?_gifPreview}) {
      if (GifStore.isAsset(p)) continue;
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    _player?.dispose();
    _pos.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    // GIF 模式：播的是成果本人，時鐘在 _gifTick 手上
    if (_gifMode) {
      setState(() => _playing = !_playing);
      _ensureGifTick();
      return;
    }
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

  /// 選取範圍的長度（原速）
  double get _len => math.max(0.1, _end - _start);

  /// 成品實際的長度：變速之後的秒數。
  /// 「建議 15 秒內」看的是成品，放慢兩倍就真的變兩倍長
  double get _outLen => _len / _speed.clamp(0.1, 8.0);

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
    if (!ok) {
      showHint(context, message, error: true);
      return;
    }
    // 成功統一走「輸出完成」對話框（跟影片/照片/批次同一顆），
    // 小 toast 太不明顯（實測回報）
    final act = await askAfterExport(context, message);
    if (act == 'home' && mounted) Navigator.of(context).pop();
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
    // 不放右滑返回：這頁滿是橫向手勢（預覽速覽、指針、修剪把手），
    // 跟返回判定天生打架（實測回報：一滑就滑到上一頁）。
    // canPop: false 同時把 iOS 系統的左緣右滑返回也關掉——自家的
    // SwipeBack 拿掉之後，拖到螢幕左緣還是會誤觸系統那條（實測回報）。
    // 返回走左上角的返回鍵：maybePop 被擋下後從回呼手動放行
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
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
                          _trimStrip(),
                          const SizedBox(height: 16),
                          _chipsRow('尺寸', [320, 480, 640], _size, (v) {
                            setState(() => _size = v);
                            _schedulePreview();
                          }, (v) => '${v}p'),
                          const SizedBox(height: 10),
                          _chipsRow('順暢度', [10, 12, 15], _fps, (v) {
                            setState(() => _fps = v);
                            _schedulePreview();
                          }, (v) => '$v fps'),
                          const SizedBox(height: 10),
                          _speedRow(),
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

  /// 疊在預覽右下角的裁切鈕。裁的是那張畫面，按鈕就長在那張畫面上
  Widget _cropButton() => Positioned(
    right: 12,
    bottom: 12,
    child: Row(
      children: [
        if (_crop != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  setState(() => _crop = null);
                  _schedulePreview();
                },
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.restart_alt, size: 16, color: kTextDim),
                ),
              ),
            ),
          ),
        Material(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: _openCrop,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.crop,
                    size: 15,
                    color: _crop == null ? kText : kSelect,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _crop == null ? '裁切' : '已裁切',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _crop == null ? kText : kSelect,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// 播放控制列：播放/暫停＋目前秒數。
  /// 位置選擇（滑動速覽）由修剪條上的白色播放頭負責（C 案：
  /// 不另外加一條，播放頭直接長在修剪條上、拖了即時換畫面）
  Widget _playbackRow() {
    return Padding(
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
  }

  // ── 播放頭速覽拖曳（修剪條上的白針）───────────────────────
  double? _scrubFrom;
  double _scrubAcc = 0;
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);

  void _scrubBegin() {
    _scrubFrom = _pos.value;
    _scrubAcc = 0;
    // 拖曳中不播：畫面完全跟著手指
    if (_playing) {
      _player?.pause();
      setState(() => _playing = false);
    }
  }

  void _scrubBy(double dx, double width) {
    final from = _scrubFrom;
    if (from == null) return;
    _scrubAcc += dx;
    // GIF 模式：指針只在段落內移動，直接撥 GIF 的時鐘
    if (_gifMode) {
      final t = (from + _scrubAcc / width * _dur).clamp(_start, _end);
      _gifSeekToSrc(t);
      return;
    }
    final t = (from + _scrubAcc / width * _dur).clamp(0.0, _dur);
    _pos.value = t;
    // seek 節流：60ms 一發（每個手指事件都 seek 會把解碼器打爆），
    // 放手在 _scrubEnd 補一發精準的
    final now = DateTime.now();
    if (now.difference(_lastScrubSeek).inMilliseconds >= 60) {
      _lastScrubSeek = now;
      _player?.seekTo(Duration(milliseconds: (t * 1000).round()));
    }
  }

  void _scrubEnd() {
    if (_scrubFrom == null) return;
    _scrubFrom = null;
    if (_gifMode) return; // GIF 時鐘已經在位置上了
    _player?.seekTo(Duration(milliseconds: (_pos.value * 1000).round()));
  }

  Widget _preview() {
    final p = _player!;
    final size = p.value.size;
    final aspect = (size.width > 0 && size.height > 0)
        ? size.width / size.height
        : 16 / 9;

    // 外層這個 Stack 撐滿整個預覽區，裁切鈕才釘得住。
    // 疊在「內容」上面的話，框會跟著影片的比例縮放——直式換橫式，
    // 按鈕就從一個位置跳到另一個位置
    return Stack(
      children: [
        Positioned.fill(
          // 在預覽畫面上左右滑＝快速預覽（跟拖修剪條上的白針同一套
          // scrub）：手指掃過整個預覽寬度＝掃過整支影片。挑段落時
          // 眼睛本來就盯著大畫面，不必特地移到下面的細針上瞄準
          child: LayoutBuilder(
            builder: (context, cons) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              onHorizontalDragStart: (_) => _scrubBegin(),
              onHorizontalDragUpdate: (d) =>
                  _scrubBy(d.delta.dx, math.max(1, cons.maxWidth)),
              onHorizontalDragEnd: (_) => _scrubEnd(),
              onHorizontalDragCancel: _scrubEnd,
              child: Container(
                // 跟影片編輯的預覽同一個底色：純黑會在預覽區與下面的
                // 控制區之間切出一條分界，整頁看起來像被切成兩塊
                color: kPreviewBg,
                alignment: Alignment.center,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: aspect,
                      // 成果做好後看的就是 GIF 本人（時鐘在我們手上，
                      // 指針才對得到位置）；還沒做好前先看影片
                      child: _gifMode
                          ? ValueListenableBuilder<int>(
                              valueListenable: _gifFrameVN,
                              builder: (context, i, _) => RawImage(
                                image:
                                    _gifFrames[i.clamp(
                                      0,
                                      _gifFrames.length - 1,
                                    )],
                                fit: BoxFit.contain,
                              ),
                            )
                          : p.view(),
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
                        child: const Icon(
                          Icons.play_arrow,
                          size: 34,
                          color: kText,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_building)
          const Positioned(
            right: 12,
            top: 12,
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        _cropButton(),
      ],
    );
  }

  Widget _rangeReadout() {
    final over = _outLen > 15;
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
              ? '長度 ${_outLen.toStringAsFixed(1)} 秒·建議 15 秒內'
              : '長度 ${_outLen.toStringAsFixed(1)} 秒',
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
              // 縮圖帶：點哪跳哪（跟播放頭拖曳互補）
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    final t = (d.localPosition.dx / w * _dur).clamp(0.0, _dur);
                    if (_gifMode) {
                      _gifSeekToSrc(t.clamp(_start, _end));
                      return;
                    }
                    _pos.value = t;
                    _player?.seekTo(Duration(milliseconds: (t * 1000).round()));
                  },
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
              _handle(x: xOf(_start), left: true, width: w),
              _handle(x: xOf(_end), left: false, width: w),
              // 播放頭：整根可拖＝滑動速覽（C 案）。長相跟影片編輯區
              // 時間軸的播放頭一致——純白 2px 細線；36pt 觸控區是
              // 隱形的，拖起來不用瞄準。
              // 畫在把手「之後」＝壓在最上面：停在段落起點時它剛好
              // 疊在左把手上，畫在底下就整根被蓋住（使用者回報：
              // 看不到指針、不知道播到哪）
              ValueListenableBuilder<double>(
                valueListenable: _pos,
                builder: (context, t, _) => Positioned(
                  left: xOf(t.clamp(0, _dur)) - 18,
                  top: -2,
                  bottom: -2,
                  width: 36,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => _scrubBegin(),
                    onHorizontalDragUpdate: (d) => _scrubBy(d.delta.dx, w),
                    onHorizontalDragEnd: (_) => _scrubEnd(),
                    onHorizontalDragCancel: _scrubEnd,
                    // height 一定要給滿：SizedBox 只給寬的話，
                    // 裡面的 ColoredBox 沒有子元件、鬆約束下高度
                    // 縮成 0——一條 2×0 的隱形線（實測回報：
                    // 一直說沒有指針，其實是從來沒畫出來過）
                    child: const Center(
                      child: SizedBox(
                        width: 2,
                        height: double.infinity,
                        child: ColoredBox(color: kText),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 一個把手：44pt 觸控區。長相跟影片編輯區時間軸的修剪把手
  /// 一致——13px 琥珀色直條＋拖曳點點，貼在選取範圍的內緣
  /// （使用者回報：修剪條要跟編輯器的軌道素材同一套長相，
  /// 不要兩頁兩種東西）
  Widget _handle({
    required double x,
    required bool left,
    required double width,
  }) {
    return Positioned(
      left: x - 22,
      top: 0,
      bottom: 0,
      width: 44,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          _dragFrom = left ? _start : _end;
          _dragAcc = 0;
        },
        onHorizontalDragEnd: (_) => _dragFrom = null,
        onHorizontalDragCancel: () => _dragFrom = null,
        onHorizontalDragUpdate: (d) {
          final from = _dragFrom ?? (left ? _start : _end);
          _dragAcc += d.delta.dx;
          final t = (from + _dragAcc / width * _dur).clamp(0.0, _dur);
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
        // 44 寬的熱區裡，13px 的視覺把手貼在範圍內緣：
        // 左把手佔 [x, x+13]、右把手佔 [x-13, x]，跟編輯器
        // 選取片段的內側雙把手同一個位置關係
        child: Container(
          margin: EdgeInsets.only(left: left ? 22 : 9, right: left ? 9 : 22),
          decoration: BoxDecoration(
            color: kSelect,
            borderRadius: BorderRadius.horizontal(
              left: left ? const Radius.circular(4) : Radius.zero,
              right: left ? Radius.zero : const Radius.circular(4),
            ),
          ),
          child: const Center(
            child: Icon(Icons.drag_indicator, size: 11, color: Colors.black87),
          ),
        ),
      ),
    );
  }

  /// 速度那一排。用 chips 跟尺寸／順暢度同型，不另外發明一種東西
  Widget _speedRow() => _chipsRow<double>(
    '速度',
    const [0.25, 0.5, 1.0, 1.5, 2.0],
    _speed,
    (v) {
      setState(() => _speed = v);
      _schedulePreview();
    },
    (v) => v == 1.0 ? '原速' : '${v % 1 == 0 ? v.toInt() : v}x',
  );

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
