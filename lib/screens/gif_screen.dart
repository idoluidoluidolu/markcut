import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/export_speed.dart' show fmtDuration;
import '../services/gif_strip.dart';
import '../services/gif_trim_range.dart';
import '../services/native_frames.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/gif_store.dart';
import '../services/video_engine.dart' as engine;
import 'crop_screen.dart';
import '../theme.dart';
import '../widgets/gif_trim_strip.dart';

/// 專屬的 GIF 製作頁：選一支影片進來，拉兩個把手決定要剪哪一段，
/// 挑尺寸跟順暢度，直接出 GIF。
///
/// 不走影片編輯器——做 GIF 的人只想要「這幾秒變成 GIF」，
/// 不需要時間軸、多軌、浮水印那一整套。這一頁只有三件事：
/// 預覽、剪多長、出檔。
/// GIF 製作的草稿鍵（個人頁「未完成的 GIF」讀這裡）
const kGifDraftKey = 'gif_draft_v1';

class GifScreen extends StatefulWidget {
  final String path;
  final String name;

  /// 從草稿續作：剪選範圍與輸出設定（見 kGifDraftKey）
  final Map<String, dynamic>? restore;

  const GifScreen({
    super.key,
    required this.path,
    required this.name,
    this.restore,
  });

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

  /// 縮圖帶（漸進：抽到一格畫一格，見 GifStripLoader）
  static const int _stripCount = 10;
  final List<Uint8List?> _cells = List<Uint8List?>.filled(_stripCount, null);
  GifStripLoader? _strip;

  /// 縮圖帶還在抽（這段時間不預做隔壁選項，解碼器留給它跟拖曳）
  bool _stripLoading = true;

  /// GIF 長邊上限與影格率
  int _size = 480;
  int _fps = 12;

  /// 裁切框（0~1 的比例）。null＝整張。
  /// GIF 常常只要畫面裡的某一小塊（一個表情、一個動作），
  /// 整張出去檔案大又抓不到重點
  Rect? _crop;

  /// 播放速度倍率。GIF 常常要放慢看細節、或加快變成有梗的節奏
  double _speed = 1.0;

  /// 「有沒有改過」基準：進場（含草稿還原）後拍一次，
  /// 匯出成功後重拍——跟批次/照片同一套離開保護
  String _baseline = '';

  String _stateJson() => jsonEncode({
    'path': widget.path,
    'name': widget.name,
    'start': double.parse(_start.toStringAsFixed(2)),
    'end': double.parse(_end.toStringAsFixed(2)),
    'size': _size,
    'fps': _fps,
    'speed': _speed,
    if (_crop != null)
      'crop': [_crop!.left, _crop!.top, _crop!.width, _crop!.height],
    'savedAt': DateTime.now().toIso8601String(),
  });

  /// savedAt 每次都不一樣，比對前拿掉
  String _dirtyKey() {
    final j = jsonDecode(_stateJson()) as Map<String, dynamic>;
    j.remove('savedAt');
    return jsonEncode(j);
  }

  bool get _dirty => _baseline.isNotEmpty && _dirtyKey() != _baseline;

  Future<void> _saveGifDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kGifDraftKey, _stateJson());
    } catch (_) {}
  }

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

  /// 指針落在「已做好的 GIF 那一段」外面時，暫時改看影片本人——
  /// 那裡沒有 GIF 幀可看，凍在端點幀等於什麼都看不到（實測回報）。
  /// 指針現在可以自由跑到選取範圍外（使用者指定），所以這條路變成
  /// 常態。新的預覽做好就關
  bool _gifPeek = false;
  double get _rangeLen => math.max(0.05, _end - _start);

  /// 這一份 GIF 的幀有沒有涵蓋 [t] 這一秒
  bool _gifCovers(double t) =>
      _gifBuiltEnd - _gifBuiltStart > 0.01 &&
      t >= _gifBuiltStart - 0.01 &&
      t <= _gifBuiltEnd + 0.01;

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
        _gifPeek = false; // 新成果上檔，回到看 GIF 本人
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

  /// [ms] 落在第幾幀
  int _gifFrameAt(double ms) {
    var lo = 0;
    var hi = _gifEndMs.length - 1;
    final v = ms.clamp(0, _gifLoopMs - 1);
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_gifEndMs[mid] > v) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// 播放中：由 _gifMs 更新目前幀與修剪條上的指針位置
  /// （比例對映回段落——播的就是選取的那一段）
  void _syncGifFrame() {
    _gifFrameVN.value = _gifFrameAt(_gifMs);
    _pos.value = _start + (_gifMs / _gifLoopMs) * _rangeLen;
  }

  /// 指針被拖／點到 [t] 這一秒：那裡該看到什麼。
  ///
  /// 指針不再被關在起訖點內（使用者指定：整條都要可以自由移動），
  /// 所以有兩種情況：
  /// - 落在這份 GIF 做出來的那一段裡：撥 GIF 的時鐘，看成品本人那一幀
  /// - 落在外面：沒有對應的 GIF 幀，改看影片本人那一格（_gifPeek），
  ///   指針回到範圍內會自己切回成品
  void _gifSeekToSrc(double t) {
    if (!_gifMode) return;
    if (!_gifCovers(t)) {
      // 看影片本人就要讓畫面停在那一格：GIF 的循環繼續跑會對不上
      _pauseForDrag();
      if (!_gifPeek) setState(() => _gifPeek = true);
      _seekDuringDrag(t);
      return;
    }
    if (_gifPeek) setState(() => _gifPeek = false);
    final len = _gifBuiltEnd - _gifBuiltStart;
    final frac = ((t - _gifBuiltStart) / len).clamp(0.0, 0.999);
    _gifMs = frac * _gifLoopMs;
    _gifFrameVN.value = _gifFrameAt(_gifMs);
    _pos.value = t;
  }

  /// 目前這份 GIF 的幀是照哪一段時間做的。指針落在這一段裡就把它
  /// 映射成對應的幀（連續跟手），落在外面就沒有幀可看（見 _gifCovers、
  /// _gifSeekToSrc）——起訖點剛按過、新的預覽還沒做好時，這一段跟
  /// 目前的選取範圍會有一小段時間對不上
  double _gifBuiltStart = 0;
  double _gifBuiltEnd = 0;

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
        _gifPeek = false;
      });
      _gifBuiltStart = _start;
      _gifBuiltEnd = _end;
      unawaited(_decodeGifFrames(hit));
      // 換上快取＝閒置：接著把這一組的隔壁選項也補起來
      _schedulePrefetch();
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
      _gifBuiltStart = _start;
      _gifBuiltEnd = _end;
      unawaited(_decodeGifFrames(hit));
      return;
    }
    setState(() => _building = true);
    // 做的當下的剪點（做完手可能又在拉了，不能拿最新值當這份的範圍）
    final builtStart = _start;
    final builtEnd = _end;
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
    if (path != null) {
      _gifBuiltStart = builtStart;
      _gifBuiltEnd = builtEnd;
      unawaited(_decodeGifFrames(path));
    }
    // 跑完的時候設定可能又被改過了（使用者連按了好幾個），
    // 那就接著做最新的那一組
    if (mounted && _keyFor() != _previewKey) _schedulePreview();
    _trimCache();
    // 目前這組做好了＝進入閒置：把隔壁選項在背景先做起來
    if (mounted && _keyFor() == _previewKey) _schedulePrefetch();
  }

  /// 背景有沒有正在預先做的東西（一次只跑一個，不跟使用者搶）
  bool _prefetching = false;
  Timer? _prefetchTimer;

  /// 隔壁選項的預做要等真的閒下來：剛做完預覽的當下使用者多半還在
  /// 調，這時在背景一口氣跑四支 FFmpeg 只會搶走拖曳要用的 CPU
  /// （拉把手卡就是這樣來的）。1.2 秒沒再動才開始
  void _schedulePrefetch() {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) unawaited(_prefetchSiblings());
    });
  }

  /// 把「其他尺寸 × 目前順暢度」「目前尺寸 × 其他順暢度」預先做起來。
  ///
  /// 使用者實際的用法就是在幾個選項之間來回點著比較——等他點的時候
  /// 才開始做，每一下都要等 FFmpeg 跑一輪。趁目前這組做完的閒置時間
  /// 先做，點過去就是快取直接換上，零等待。
  /// 一次只跑一支；使用者改了任何設定就立刻讓路
  Future<void> _prefetchSiblings() async {
    // 縮圖帶還在抽、手還在拉、使用者自己的預覽在做：都不算閒置
    if (_prefetching || kIsWeb || _stripLoading || _gesturing || _building) {
      return;
    }
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
        // 設定變了、手又在拉、或使用者的 build 正在跑：讓路，等下一次閒置
        if (_building || _gesturing || _keyFor() != baseKey) return;
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
    // GIF 沒有聲音這回事：預覽播放器全程靜音（實測回報：
    // 挑段落時一直有原片的聲音，跟成品對不上）
    await p.setVolume(0);
    _dur = p.value.duration.inMilliseconds / 1000.0;
    _start = 0;
    _end = math.min(_dur, 15);
    // 草稿續作：把上次的剪選範圍與設定套回來（夾在有效範圍內）
    final r = widget.restore;
    if (r != null) {
      try {
        _start = ((r['start'] as num?)?.toDouble() ?? 0).clamp(0.0, _dur);
        _end = ((r['end'] as num?)?.toDouble() ?? _end).clamp(
          math.min(_start + kTrimMinGap, _dur),
          _dur,
        );
        final sz = (r['size'] as num?)?.toInt();
        if (sz != null && sz > 0) _size = sz;
        final f = (r['fps'] as num?)?.toInt();
        if (f != null && f > 0) _fps = f;
        final sp = (r['speed'] as num?)?.toDouble();
        if (sp != null && sp > 0) _speed = sp;
        final c = (r['crop'] as List?)?.cast<num>();
        if (c != null && c.length >= 4 && c[2] > 0.01 && c[3] > 0.01) {
          _crop = Rect.fromLTWH(
            c[0].toDouble(),
            c[1].toDouble(),
            c[2].toDouble(),
            c[3].toDouble(),
          );
        }
      } catch (_) {}
    }
    _baseline = _dirtyKey();
    _schedulePreview();
    // 一進來就用影片循環播選取段落（_tick 播到段尾會跳回起點，
    // 就是 GIF 的循環感；聲音已靜音）——真的 GIF 預覽生成好會
    // 無縫換上。使用者指定：不要等生成完才能預覽循環的樣子
    unawaited(p.play());
    if (mounted) {
      setState(() {
        _ready = true;
        _playing = true;
      });
    }
    // 播放頭跟出界檢查共用一條 timer：拉把手時即時看到位置，
    // 播放時碰到迄點就跳回起點循環——預覽跟成品的循環感一致。
    // 先開 timer 再抽縮圖帶：之前是抽完才開，縮圖帶沒好前指針不動
    _tick = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (_gifMode) return; // 指針由 GIF 時鐘驅動
      final pl = _player;
      if (pl == null || !mounted || _gesturing) return;
      final now = await pl.positionNow();
      // 拖曳中指針跟手指走，不看播放器：它還在追 seek，
      // 拿它的位置蓋回去指針就來回抖
      if (now == null || !mounted || _gesturing) return;
      final t = now.inMilliseconds / 1000.0;
      _pos.value = t;
      if (_playing && t >= _end - 0.05) {
        await pl.seekTo(Duration(milliseconds: (_start * 1000).round()));
      }
    });
    // 縮圖帶：系統硬體解碼、漸進上畫面（先粗後細），抽不到再退 FFmpeg。
    // 不等它：把手跟預覽從第一秒就要能拉
    unawaited(_loadStrip());
  }

  Future<void> _loadStrip() async {
    if (!mounted) return;
    // 解析度夾在縮圖帶實際畫出來的高度（56pt × 螢幕倍率）：
    // 一格才三十幾 pt 寬，解到 1080p 是白花的
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
      // 系統解碼器吃不下這支（少見的封裝／編碼）：退 FFmpeg，只解
      // 關鍵幀——軟解整支 4K 只為了十張縮圖會把 CPU 吃滿好幾分鐘
      final thumbs = await engine.makeThumbnails(
        widget.path,
        _dur,
        _stripCount,
        height: maxH,
        fastDecode: true,
      );
      if (!mounted) return;
      if (thumbs.isNotEmpty) {
        setState(() {
          for (var i = 0; i < _cells.length && i < thumbs.length; i++) {
            _cells[i] = thumbs[i];
          }
        });
      }
    }
    setState(() => _stripLoading = false);
    // 縮圖帶抽完＝解碼器閒下來，隔壁選項的預覽這時才開始預做
    _schedulePrefetch();
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
    _prefetchTimer?.cancel();
    _strip?.cancel();
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

  /// 指針停在選取範圍外（指針可以自由移動，所以這是常態）：
  /// 按播放＝從段落起點重新播那一段
  bool get _posOutsideRange {
    final t = _pos.value;
    return t < _start - 0.05 || t > _end - 0.1;
  }

  Future<void> _togglePlay() async {
    // GIF 模式：播的是成果本人，時鐘在 _gifTick 手上
    if (_gifMode) {
      final resume = !_playing;
      setState(() {
        // 播放一律播選取的那一段：指針被拖到範圍外（或正在看影片本人）
        // 就把循環撥回段落開頭，跟影片模式同一個規矩
        if (resume && (_gifPeek || _posOutsideRange)) {
          _gifPeek = false;
          _gifMs = 0;
        }
        _playing = resume;
      });
      if (resume) _syncGifFrame();
      _ensureGifTick();
      return;
    }
    final p = _player;
    if (p == null || !_ready) return;
    if (_playing) {
      await p.pause();
    } else {
      // 從起點播：預覽的就是將來 GIF 會循環的那一段
      if (_posOutsideRange) {
        await p.seekTo(Duration(milliseconds: (_start * 1000).round()));
      }
      await p.play();
    }
    setState(() => _playing = !_playing);
  }

  // ── 拖曳中的 seek：一次只讓一發在路上 ─────────────────────
  //
  // 之前是每 60ms 射後不理：AVPlayer 收到新的 seek 會把還沒完成的
  // 那發取消，手指一直動就一直取消、畫面反而不更新，停下來才跳一格
  //（「拉起來跟不上」）。改成路上有一發就先記住最新目標、完成再補發
  // ——每一發都跑得完，畫面就以解碼器的節奏一路跟著手指。
  // iOS 的播放外掛在暫停中走「寬容 seek → 停手 250ms 才精準」那條
  //（見 packages/video_player_avfoundation），所以拖曳前一定先暫停
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
        // 有些平台的 seekTo 立刻就回（不等真的 seek 完）：至少隔 40ms
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

  /// 拖曳前先暫停：iOS 外掛只在暫停中走寬容 seek 的快路，播放中的
  /// seek 一律逐格精準（慢）；之前是先 seek 才暫停，第一發就慢
  void _pauseForDrag() {
    if (!_playing) return;
    _player?.pause();
    setState(() => _playing = false);
  }

  /// [t] 秒落在縮圖帶的第幾格
  int _cellIndexAt(double t) => _dur <= 0
      ? 0
      : ((t / _dur) * _stripCount).floor().clamp(0, _stripCount - 1);

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
    // 匯出成功＝基準重拍、草稿清掉：之後離開不再問保留
    _baseline = _dirtyKey();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kGifDraftKey);
    } catch (_) {}
    if (!mounted) return;
    // 成功統一走「匯出完成」對話框（跟影片/照片/批次同一顆），
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
    frame ??= nearestLoaded(_cells, _cellIndexAt(_start));
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

  /// 離開保護：調過還沒匯出就問一下（跟影片/照片/批次同一套）
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final act = await showLeaveChoice(
      context,
      title: '這個 GIF 還沒匯出',
      // 全 App 統一的說法（使用者指定）
      message: '可以在個人頁面的「草稿」繼續未完成的編輯',
      keepLabel: '保留草稿',
    );
    if (!mounted) return;
    if (act == 'keep') {
      await _saveGifDraft();
      if (mounted) Navigator.of(context).pop();
    } else if (act == 'discard') {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(kGifDraftKey);
      } catch (_) {}
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    // 這一頁完全不收「右滑＝上一頁」（使用者指定：關掉右滑上一頁的
    // 監聽，不然常會誤觸）。整頁滿滿都是橫向手勢——預覽速覽、修剪條
    // 上的指針——跟返回判定天生打架：
    // - canPop: false 擋掉 iOS 系統的左緣右滑返回與 Android 的返回鍵，
    //   maybePop 被攔下後改走 _confirmLeave（離開保護照樣會問）
    // - 自家的 EdgeBack（整頁甩動＝返回）也拿掉了：它只排除預覽與
    //   修剪條兩個方框，手指落在旁邊的留白、播放列、設定列往右一甩
    //   就跳回上一頁（實測回報：常誤觸）。collage 頁基於同一個理由
    //   本來就沒包
    // 返回只剩左上角的返回鍵
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) unawaited(_confirmLeave());
      },
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg),
        body: SafeArea(
          child: !_ready
              ? const Center(child: CircularProgressIndicator())
              // 整頁左右滑＝速覽（使用者指定：這一頁任何地方橫滑都是
              // 滑指針）。修剪把手、指針、縮圖帶自己的橫向手勢在
              // 競技場裡比這層深、照樣先贏，這裡只接住其他空白處。
              // 方向跟預覽區一致：「拖底片」語意，手指往左＝時間往前
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) => _scrubBegin(),
                  onHorizontalDragUpdate: (d) => _scrubBy(
                    -d.delta.dx,
                    math.max(1, MediaQuery.of(context).size.width),
                  ),
                  onHorizontalDragEnd: (_) => _scrubEnd(),
                  onHorizontalDragCancel: _scrubEnd,
                  child: Column(
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
  /// 跳回選取範圍的起點並開始播。GIF 成果模式＝把循環撥回 0；
  /// 影片模式＝seek 到起點再播
  Future<void> _replayFromStart() async {
    if (_gifMode) {
      _gifMs = 0;
      _syncGifFrame();
      if (!_playing) setState(() => _playing = true);
      _ensureGifTick();
      return;
    }
    final p = _player;
    if (p == null || !_ready) return;
    _pos.value = _start;
    await p.seekTo(Duration(milliseconds: (_start * 1000).round()));
    if (!_playing) {
      await p.play();
      if (mounted) setState(() => _playing = true);
    }
  }

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
          // 從起點重播：調完起訖點想「再看一次這一段」是最高頻的
          // 動作，不該要先拖指針回去再按播放
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
  }

  // ── 播放頭速覽拖曳（預覽區、整頁空白、修剪條共用）──────────────
  //
  // 指針走遍整條、不受起訖點限制（使用者指定：指針不要被限制在
  // 起點終點內，整個都要可以自由移動）。唯一的邊界是影片本身
  double? _scrubFrom;
  double _scrubAcc = 0;

  void _scrubBegin() {
    _scrubFrom = _pos.value;
    _scrubAcc = 0;
    // 拖曳中不播：畫面完全跟著手指
    _pauseForDrag();
  }

  /// 手指在 [width] px 寬的東西上移動了 [dx] px：整個寬度＝整支影片
  void _scrubBy(double dx, double width) =>
      _scrubBySeconds(width <= 0 ? 0 : dx / width * _dur);

  void _scrubBySeconds(double dt) {
    final from = _scrubFrom;
    if (from == null) return;
    _scrubAcc += dt;
    final t = (from + _scrubAcc).clamp(0.0, _dur);
    // GIF 模式：畫面走 GIF 的時鐘（拖到段落外會自動改看影片本人）
    if (_gifMode) {
      _gifSeekToSrc(t);
      return;
    }
    // 一次一發、最新目標優先（見 _seekDuringDrag），放手在 _scrubEnd
    // 補最後一發
    _seekDuringDrag(t);
  }

  void _scrubEnd() {
    if (_scrubFrom == null) return;
    _scrubFrom = null;
    // GIF 模式的時鐘已經在位置上了；看影片本人（段落外）時照樣補一發
    if (_gifMode && !_gifPeek) return;
    _seekDuringDrag(_pos.value);
  }

  Widget _preview() {
    final p = _player!;
    final size = p.value.size;
    final fullAspect = (size.width > 0 && size.height > 0)
        ? size.width / size.height
        : 16 / 9;
    // 裁切後預覽就用裁切後的比例，畫面最適化貼滿畫布——
    // 不然裁完還是原比例的框，成果小小一塊躺在中間（實測回報）。
    // GIF 成果已經是裁好的尺寸，直接用它的幀比例
    final crop = _crop;
    final showGif = _gifMode && !_gifPeek && _gifFrames.isNotEmpty;
    final aspect = showGif
        ? _gifFrames.first.width / _gifFrames.first.height
        : (crop == null ? fullAspect : fullAspect * crop.width / crop.height);
    // 影片模式＋裁切：外框是裁切比例，內容把整支影片放大平移到
    // 只露出裁切區（跟成品同一塊畫面）
    Widget clipped(Widget child) {
      if (crop == null) return child;
      return LayoutBuilder(
        builder: (context, cons) {
          final w = cons.maxWidth;
          final h = cons.maxHeight;
          final vw = w / crop.width;
          final vh = h / crop.height;
          double ax(double lo, double frac) =>
              frac >= 0.999 ? 0 : (2 * lo / (1 - frac) - 1);
          return ClipRect(
            child: OverflowBox(
              minWidth: vw,
              maxWidth: vw,
              minHeight: vh,
              maxHeight: vh,
              alignment: Alignment(
                ax(crop.left, crop.width),
                ax(crop.top, crop.height),
              ),
              child: SizedBox(width: vw, height: vh, child: child),
            ),
          );
        },
      );
    }

    // 外層這個 Stack 撐滿整個預覽區，裁切鈕才釘得住。
    // 疊在「內容」上面的話，框會跟著影片的比例縮放——直式換橫式，
    // 按鈕就從一個位置跳到另一個位置
    return Stack(
      children: [
        Positioned.fill(
          // 在預覽畫面上左右滑＝快速預覽（跟拖修剪條上的白針同一套
          // scrub）：手指掃過整個預覽寬度＝掃過整支影片。挑段落時
          // 眼睛本來就盯著大畫面，不必特地移到下面的細針上瞄準。
          // 方向是「拖動底片」語意：手指往左＝時間往前（使用者指定；
          // 跟捲時間軸同一個手感）。直接拖白針仍是跟手的
          child: LayoutBuilder(
            builder: (context, cons) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              onHorizontalDragStart: (_) => _scrubBegin(),
              onHorizontalDragUpdate: (d) =>
                  _scrubBy(-d.delta.dx, math.max(1, cons.maxWidth)),
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
                      //（裁切時只露出裁切區，跟成品同一塊畫面）
                      child: showGif
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
                          : clipped(p.view()),
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
          Positioned(
            right: 12,
            top: 12,
            // 第一份還沒好：講清楚現在看的是影片、GIF 在路上
            //（做好會無縫換成真的 GIF 幀）。之後的重做只給小圈
            child: _gifMode
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(strokeWidth: 1.6),
                        ),
                        SizedBox(width: 7),
                        Text(
                          'GIF 預覽生成中',
                          style: TextStyle(fontSize: 11, color: kText),
                        ),
                      ],
                    ),
                  ),
          ),
        _cropButton(),
      ],
    );
  }

  /// 把指針現在的位置設成起點／終點（使用者指定：滑到哪、按一下
  /// 就從哪開始/結束——把手不吃觸控之後，這是唯一的入口）。
  ///
  /// 指針跑到另一端的另一邊、或近到範圍會短於 [kTrimMinGap]：
  /// 不動、出提示說清楚。不偷偷夾回去——按了鈕卻換來一個自己沒選
  /// 的位置，看起來就像按鈕壞了
  void _setEdgeHere({required bool start}) {
    final t = _pos.value.clamp(0.0, _dur);
    final v = start ? trimStartAt(t, _end) : trimEndAt(t, _start, _dur);
    if (v == null) {
      final gap = kTrimMinGap.toStringAsFixed(1);
      showHint(
        context,
        start ? '起點要在終點前至少 $gap 秒，指針再往左一點' : '終點要在起點後至少 $gap 秒，指針再往右一點',
        error: true,
      );
      return;
    }
    setState(() {
      if (start) {
        _start = v;
      } else {
        _end = v;
      }
    });
    _schedulePreview();
  }

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

  Widget _rangeReadout() {
    final over = _outLen > 15;
    // 不顯示起訖秒數（使用者指定）：範圍看修剪條本身就夠，
    // 這一列只放兩顆設定鈕＋右邊的長度
    return Row(
      children: [
        _edgeBtn('設起點', true),
        _edgeBtn('設終點', false),
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

  // ── 修剪條的手勢：整條只有一件事，就是移動指針 ──────────────────
  //
  // 把手不再吃觸控（使用者指定：拉桿改成無法靠觸控拖曳，頭尾一律靠
  // 自己按起點終點）。之前起點把手／終點把手／播放頭三個熱區疊在
  // Stack 裡互搶手勢，範圍縮到零點幾秒時整個重疊，就是使用者回報的
  // 「拉近就再也拉不開」。現在沒有東西要搶：整條上的每一次觸碰都是
  // 播放頭，而且不受起訖點限制

  /// 修剪條或速覽手勢進行中（縮圖帶抽幀、指針對時都要讓路）
  bool get _gesturing => _scrubFrom != null;

  /// 點一下：點哪跳哪（整條都可以，包括選取範圍外面）
  void _stripTap(double t) {
    if (_gifMode) {
      _gifSeekToSrc(t);
      return;
    }
    _pauseForDrag();
    _pos.value = t;
    _player?.seekTo(Duration(milliseconds: (t * 1000).round()));
  }

  /// 拖曳起手：指針先跳到手指下面，之後跟著走（跟點一下同一套）
  void _stripDragStart(double t) {
    _scrubBegin();
    _scrubFrom = t;
    _scrubBySeconds(0);
  }

  /// 縮圖帶＋兩個把手＋播放頭。把手蓋在縮圖上，看得到自己剪掉了哪些
  /// 畫面——但只是畫的，觸控一律是指針（見 GifTrimStrip）
  Widget _trimStrip() => GifTrimStrip(
    dur: _dur,
    start: _start,
    end: _end,
    pos: _pos,
    cells: _cells,
    onTapAt: _stripTap,
    onScrubStart: _stripDragStart,
    onScrubBy: _scrubBySeconds,
    onScrubEnd: _scrubEnd,
  );

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
