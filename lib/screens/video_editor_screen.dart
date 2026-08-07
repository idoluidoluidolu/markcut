import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import '../services/audio_picker.dart';
import '../services/file_reader.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../services/watermark_renderer.dart';
import '../theme.dart';
import '../widgets/timeline_editor.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

const kSpeedOptions = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];

/// 草稿存放鍵
const kDraftKey = 'project_draft_v1';

class VideoEditorScreen extends StatefulWidget {
  final String? videoPath;
  final WatermarkSettings? initialWatermark; // 從範本卡片開新專案時帶入
  final Map<String, dynamic>? draft; // 從草稿還原

  const VideoEditorScreen(
      {super.key, this.videoPath, this.initialWatermark, this.draft})
      : assert(videoPath != null || draft != null);

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends State<VideoEditorScreen>
    with TickerProviderStateMixin {
  late final TabController _tabs;
  late final Ticker _ticker;
  late final WatermarkSettings _settings =
      widget.initialWatermark?.copy() ?? WatermarkSettings();

  final _tl = TimelineModel();
  final Map<int, PlayerX> _ctrls = {}; // clipId → controller
  final Map<int, List<Uint8List>> _thumbs = {}; // sourceIndex → filmstrip

  int _sel = -1; // 選取的片段 id
  // 播放頭（時間軸秒，原速）。用 ValueNotifier 驅動，
  // 播放每一格只重繪時間碼／播放頭／預覽圖層，不整頁 setState
  final ValueNotifier<double> _posVN = ValueNotifier(0);

  /// 預覽圖層專用的粗粒度位置：最多 30fps 重建。
  /// 影片畫面走原生 texture 本來就每格都在動，
  /// widget 樹（圖層框、淡入淡出、浮水印動畫）30fps 就夠順，
  /// 在手機上把每秒 60~120 次的整疊重建砍半以上。
  final ValueNotifier<double> _frameVN = ValueNotifier(0);
  DateTime _lastFramePush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _frameSettle;

  double get _position => _posVN.value;
  set _position(double v) {
    _posVN.value = v; // 播放頭線與時間碼照舊即時（很便宜）
    final now = DateTime.now();
    // 播放中 30fps 就夠（影片畫面走原生 texture 本來就滿速）；
    // 拖曳（暫停）時提高到 60fps，快取幀跟手感明顯變好
    final interval = _playing ? 33 : 16;
    if (now.difference(_lastFramePush).inMilliseconds >= interval) {
      _lastFramePush = now;
      _frameVN.value = v;
    } else {
      // 尾巴補一發，停下來時畫面一定對齊最終位置
      _frameSettle?.cancel();
      _frameSettle = Timer(const Duration(milliseconds: 40), () {
        _lastFramePush = DateTime.now();
        _frameVN.value = _posVN.value;
      });
    }
  }

  bool _playing = false;
  Duration _lastTick = Duration.zero;

  double _speed = 1.0;
  ExportResolution _resolution = ExportResolution.original;
  ExportQuality _quality = ExportQuality.standard;
  CanvasRatio _canvasRatio = CanvasRatio.original;
  double _pxPerSec = 0;
  final _tlScroll = ScrollController();

  // 浮水印顯示範圍（時間軸秒）；_wmEnd null = 跟到結尾
  double _wmStart = 0;
  double? _wmEnd;
  bool _wmSel = false;

  double get _wmEndEff =>
      (_wmEnd ?? _tl.duration).clamp(0.0, _tl.duration);
  bool get _wmVisibleNow =>
      _settings.hasAnyMark &&
      _position >= _wmStart &&
      _position <= _wmEndEff + 0.001;

  bool _ready = false;
  bool _exporting = false;

  TimelineClip? _clipboard; // 複製的片段（貼上時以播放頭為起點）
  // 時間軸雙指縮放：在整個分頁層級偵測，空白處一樣能捏
  bool _tlPinching = false;
  final Map<int, Offset> _pinchPts = {};
  double? _pinchBaseDist;
  double _pinchBasePx = 0;

  void _pinchDown(PointerDownEvent e) {
    _pinchPts[e.pointer] = e.position;
    if (_pinchPts.length == 2 && !_lifting) {
      final p = _pinchPts.values.toList();
      final d = (p[0] - p[1]).distance;
      if (d > 20) {
        _pinchBaseDist = d;
        _pinchBasePx = _pxPerSec;
        setState(() => _tlPinching = true);
      }
    }
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pinchPts.containsKey(e.pointer)) return;
    _pinchPts[e.pointer] = e.position;
    if (_tlPinching && _pinchPts.length >= 2) {
      final p = _pinchPts.values.toList();
      final d = (p[0] - p[1]).distance;
      setState(() =>
          _pxPerSec = (_pinchBasePx * d / _pinchBaseDist!).clamp(1.0, 200.0));
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _syncScrollToPosition());
    }
  }

  void _pinchUp(int pointer) {
    _pinchPts.remove(pointer);
    if (_tlPinching && _pinchPts.length < 2) {
      _pinchBaseDist = null;
      setState(() => _tlPinching = false);
    }
  }

  /// 桌面滾輪縮放時間軸（時間軸分頁內任何位置都有效）
  void _wheelZoom(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final dy = (event as PointerScrollEvent).scrollDelta.dy;
      setState(() => _pxPerSec =
          (_pxPerSec * math.exp(-dy * 0.002)).clamp(1.0, 200.0));
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _syncScrollToPosition());
    });
  }

  /// 靜音的軌道（點軌道標籤的喇叭切換）
  final Set<int> _mutedTracks = {};

  // ===== 復原 / 重做 =====
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  String _snapshot() => jsonEncode({
        'clips': [for (final c in _tl.clips) c.toJson()],
        'wmStart': _wmStart,
        'wmEnd': _wmEnd,
        'wm': _settings.toJson(),
      });

  /// 浮水印修改的快照：連續調整（拖滑桿、打字）0.7 秒內併成一步
  DateTime _lastWmPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _wmSync = 0; // 復原後通知浮水印面板同步內部狀態

  void _pushWmUndo() {
    final now = DateTime.now();
    if (now.difference(_lastWmPush).inMilliseconds < 700) return;
    _lastWmPush = now;
    _pushUndo();
  }

  /// 每個破壞性操作前呼叫：拍快照＋順便存草稿
  void _pushUndo() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    _redoStack.clear();
    _saveDraft();
  }

  void _restoreSnapshot(String snap) {
    final j = jsonDecode(snap) as Map<String, dynamic>;
    setState(() {
      _tl.clips
        ..clear()
        ..addAll([
          for (final c in (j['clips'] as List))
            TimelineClip.fromJson(Map<String, dynamic>.from(c as Map))
        ]);
      var maxId = -1;
      for (final c in _tl.clips) {
        if (c.id > maxId) maxId = c.id;
      }
      _tl.ensureIdAbove(maxId);
      _wmStart = (j['wmStart'] ?? 0).toDouble();
      _wmEnd = j['wmEnd'] == null ? null : (j['wmEnd'] as num).toDouble();
      if (j['wm'] != null) {
        final wm = WatermarkSettings.fromJson(
            Map<String, dynamic>.from(j['wm'] as Map));
        _settings.text = wm.text;
        _settings.logo = wm.logo;
        _settings.animation = wm.animation;
        _settings.animSpeed = wm.animSpeed;
        _settings.animRange = wm.animRange;
        _wmSync++;
      }
      _sel = -1;
      _position = _position.clamp(0.0, _tl.duration);
    });
    for (final c in _tl.clips) {
      _ensureCtrlFor(c);
    }
  }

  void _undoAction() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    _restoreSnapshot(_undoStack.removeLast());
    _saveDraft();
  }

  void _redoAction() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    _restoreSnapshot(_redoStack.removeLast());
    _saveDraft();
  }

  /// 復原/貼上/草稿還原後，補建缺少的播放器
  void _ensureCtrlFor(TimelineClip c) {
    final src = _tl.sources[c.sourceIndex];
    if (src.kind != ClipKind.video && src.kind != ClipKind.audio) return;
    if (_ctrls.containsKey(c.id)) return;
    final ctrl = makeVideoController(src.path);
    _ctrls[c.id] = ctrl;
    ctrl.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {});
  }

  // ===== 草稿 =====

  int _droppedOnLoad = 0; // 還原時因為檔案不見而剔除的片段數

  /// 草稿封面縮圖：時間軸上最早出現、有縮圖的影片/圖片片段（帶長寬比）
  (String, double)? _draftThumb() {
    TimelineClip? best;
    for (final c in _tl.clips) {
      final src = _tl.sources[c.sourceIndex];
      if (src.kind != ClipKind.video && src.kind != ClipKind.image) {
        continue;
      }
      if (!(_thumbs[c.sourceIndex]?.isNotEmpty ?? false)) continue;
      if (best == null || c.offset < best.offset) best = c;
    }
    if (best == null) return null;
    return (
      base64Encode(_thumbs[best.sourceIndex]!.first),
      _tl.sources[best.sourceIndex].aspect,
    );
  }

  Map<String, dynamic> _projectJson() {
    final thumb = _draftThumb();
    return {
        'savedAt': DateTime.now().toIso8601String(),
        'thumb': ?thumb?.$1,
        if (thumb != null) 'thumbAspect': thumb.$2,
        'sources': [for (final s in _tl.sources) s.toJson()],
        'clips': [for (final c in _tl.clips) c.toJson()],
        'speed': _speed,
        'ratio': _canvasRatio.index,
        'res': _resolution.index,
        'quality': _quality.index,
        'wm': _settings.toJson(),
        'wmStart': _wmStart,
        'wmEnd': _wmEnd,
      };
  }

  Future<void> _saveDraft() async {
    // Web 也存：同一次瀏覽內可以繼續剪；重新整理後素材連結會失效，
    // 還原時由 _loadDraft 剔除並提示
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kDraftKey, jsonEncode(_projectJson()));
  }

  static Future<void> clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kDraftKey);
  }

  Future<void> _loadDraft(Map<String, dynamic> j) async {
    for (final sj in (j['sources'] as List? ?? [])) {
      _tl.sources.add(
          MediaSource.fromJson(Map<String, dynamic>.from(sj as Map)));
    }
    for (final cj in (j['clips'] as List? ?? [])) {
      _tl.clips
          .add(TimelineClip.fromJson(Map<String, dynamic>.from(cj as Map)));
    }
    var maxId = -1;
    for (final c in _tl.clips) {
      if (c.id > maxId) maxId = c.id;
    }
    _tl.ensureIdAbove(maxId);
    _speed = ((j['speed'] ?? 1.0) as num).toDouble();
    _canvasRatio = CanvasRatio.values[
        ((j['ratio'] ?? 0) as int) % CanvasRatio.values.length];
    _resolution = ExportResolution.values[
        ((j['res'] ?? 0) as int) % ExportResolution.values.length];
    _quality = ExportQuality.values[
        ((j['quality'] ?? 0) as int) % ExportQuality.values.length];
    if (j['wm'] != null) {
      final wm = WatermarkSettings.fromJson(
          Map<String, dynamic>.from(j['wm'] as Map));
      _settings.text = wm.text;
      _settings.logo = wm.logo;
      _settings.animation = wm.animation;
      _settings.animSpeed = wm.animSpeed;
      _settings.animRange = wm.animRange;
    }
    _wmStart = ((j['wmStart'] ?? 0) as num).toDouble();
    _wmEnd = j['wmEnd'] == null ? null : (j['wmEnd'] as num).toDouble();

    // 重建播放器與縮圖；素材檔案不見了（例如系統清掉 app 快取）就剔除該片段，
    // 免得留下永遠黑畫面的片段、到匯出才爆錯
    final deadSources = <int>{};
    for (var i = 0; i < _tl.sources.length; i++) {
      final s = _tl.sources[i];
      if (s.kind == ClipKind.text) continue; // 文字素材沒有檔案
      if (s.kind == ClipKind.image) {
        final bytes = await readFileBytes(s.path);
        if (bytes != null) {
          _thumbs[i] = [bytes];
        } else if (!kIsWeb) {
          deadSources.add(i);
        }
      } else if (!kIsWeb && !await fileExists(s.path)) {
        // Web 沒辦法驗檔案還在不在，直接嘗試載入
        deadSources.add(i);
      } else if (s.kind == ClipKind.video) {
        engine
            .makeThumbnails(s.path, s.duration, 10, fastDecode: true)
            .then((t) {
          if (mounted && t.isNotEmpty) setState(() => _thumbs[i] = t);
        });
        _makeScrubCache(i, s.path, s.duration);
      }
    }
    _droppedOnLoad =
        _tl.clips.where((c) => deadSources.contains(c.sourceIndex)).length;
    _tl.clips.removeWhere((c) => deadSources.contains(c.sourceIndex));
    for (final c in _tl.clips) {
      _ensureCtrlFor(c);
    }
  }

  // 「捲動時間軸＝移動播放位置」的同步控制
  bool _suppressScroll = false; // 程式自己捲動時不要回頭改播放位置
  bool _lifting = false; // 拖曳片段中（邊緣自動捲動不算 scrub）

  TimelineClip? get _selClip {
    for (final c in _tl.clips) {
      if (c.id == _sel) return c;
    }
    return null;
  }

  /// 目前畫面上該顯示的影片片段
  TimelineClip? get _activeVideo => _tl.videoAt(_position);

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _ticker = createTicker(_onTick);
    _tlScroll.addListener(_onTimelineScroll);
    if (widget.draft != null) {
      _loadDraft(widget.draft!).then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        if (_droppedOnLoad > 0) {
          showHint(
              context, '有 $_droppedOnLoad 段素材已找不到，已從專案中移除',
              duration: const Duration(seconds: 5));
        }
      });
    } else {
      _importVideoFromPath(widget.videoPath!, track: 0).then((_) {
        if (mounted) setState(() => _ready = true);
        _saveDraft();
      });
    }
  }

  /// 使用者捲動時間軸 → 播放頭跟著走（scrub）。
  /// seek 有節流：捲動中每 100ms 對時一次、放手再補一發，
  /// 否則每個捲動事件都 seek 會把解碼器打爆（超卡）。
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _scrubSettleTimer;

  void _onTimelineScroll() {
    if (_suppressScroll || _lifting || _pxPerSec <= 0) return;
    if (!_tlScroll.hasClients) return;
    if (_playing) _pause();
    final t = (_tlScroll.offset / _pxPerSec).clamp(0.0, _tl.duration);
    if ((t - _position).abs() < 0.001) return;
    _position = t; // 位置 UI 由 _posVN 小範圍重繪，不整頁 setState
    _scrubbing = true; // 快取幀模式（下一次 30fps 重繪就生效）
    _scrubEndTimer?.cancel();
    _scrubEndTimer =
        Timer(const Duration(milliseconds: 220), _tryEndScrub);
    if (_activeScrubCached) {
      // 有快取幀：拖曳中完全不 seek，只約定放手補一發
      _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(const Duration(milliseconds: 120),
          () => _scrubSeek(force: true));
    } else {
      _scrubSeek();
    }
  }

  /// 上一發 seek 還在解碼中就不發新的：
  /// seek 疊 seek 會在解碼器裡排隊，是拖曳卡頓的主因
  bool _seekInFlight = false;

  void _scrubSeek({bool force = false}) {
    final now = DateTime.now();
    if (_seekInFlight ||
        (!force && now.difference(_lastScrubSeek).inMilliseconds < 100)) {
      // 改約：等這發完成（或節流期過了）再補最後位置
      _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(const Duration(milliseconds: 120),
          () => _scrubSeek(force: true));
      return;
    }
    _lastScrubSeek = now;
    final seeks = <Future<void>>[];
    for (final clip in _tl.clips) {
      final c = _ctrls[clip.id];
      if (c == null || !c.value.isInitialized) continue;
      if (clip.covers(_position)) {
        seeks.add(c.seekTo(Duration(
            milliseconds: (clip.sourceTimeAt(_position) * 1000).round())));
      }
    }
    if (seeks.isNotEmpty) {
      _seekInFlight = true;
      Future.wait(seeks).whenComplete(() => _seekInFlight = false);
    }
  }

  /// 程式主動把時間軸捲到目前播放位置（播放中、seek、縮放後）
  void _syncScrollToPosition() {
    if (!_tlScroll.hasClients || _pxPerSec <= 0) return;
    _suppressScroll = true;
    _tlScroll.jumpTo((_position * _pxPerSec)
        .clamp(0.0, _tlScroll.position.maxScrollExtent));
    _suppressScroll = false;
  }

  // ===== 匯入素材 =====

  Future<void> _importVideoFromPath(String path,
      {required int track, String? name}) async {
    final c = makeVideoController(path);
    await c.initialize();
    final dur = c.value.duration.inMilliseconds / 1000.0;
    final srcIndex = _tl.sources.length;
    _tl.sources.add(MediaSource(
      path: path,
      name: name ?? '影片 ${srcIndex + 1}',
      kind: ClipKind.video,
      w: c.value.size.width.round(),
      h: c.value.size.height.round(),
      duration: dur,
    ));
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: dur,
      // 同一軌上接在既有素材後面
      offset: _tl.appendPointOnTrack(track),
      track: track,
    );
    _tl.clips.add(clip);
    _ctrls[clip.id] = c;
    _sel = clip.id;

    engine
        .makeThumbnails(path, dur, 10, fastDecode: true)
        .then((t) {
      if (mounted && t.isNotEmpty) setState(() => _thumbs[srcIndex] = t);
    });
    _makeScrubCache(srcIndex, path, dur);
  }

  // ===== 拖曳快取幀（CapCut 式）=====
  // 拖曳時預覽顯示預先抽好的幀（換圖是瞬間的），完全不叫解碼器
  // seek；放手才真正 seek 到最終位置。這是專業剪輯 App 拖曳滑順的
  // 真正做法——live seek 再怎麼節流都追不上手指。

  /// sourceIndex → 等距格子，分段漸進填滿：
  /// 抽好第一段（幾秒內）就能順順拖那一段
  final Map<int, List<Uint8List?>> _scrubFrames = {};

  /// 每張快取幀的時間間隔（秒）：專業剪輯 App 的拖曳之所以絲滑，
  /// 是因為幀夠密（我們用 8fps）；太疏就只能拿舊幀湊，看起來一段段跳
  static const _scrubFps = 8.0;

  /// 快取幀解析度（長邊）。密度提高後張數變多，
  /// 解析度相對降一階換記憶體與解碼速度——拖曳中肉眼看不出差別
  static const _scrubLongSide = 720;

  bool _scrubbing = false;
  Timer? _scrubEndTimer;

  Future<void> _makeScrubCache(
      int srcIndex, String path, double dur) async {
    if (dur <= 0) return;
    // 上限 2400 張（8fps 約 5 分鐘）；更長的片自動降密度保住記憶體
    final n = (dur * _scrubFps).ceil().clamp(4, 2400);
    final step = dur / n;
    final slots = List<Uint8List?>.filled(n, null);
    _scrubFrames[srcIndex] = slots;
    // 每段約 6 秒，抽完立刻可用、逐段補滿。
    // 播放或拖曳中先暫停：抽幀跟播放搶 CPU 會讓畫面跳針
    final segFrames = (_scrubFps * 6).round();
    // 剛匯入先讓 UI 安頓，再開始背景抽
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    for (var s = 0; s < n; s += segFrames) {
      while (mounted && (_playing || _scrubbing)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (!mounted || !identical(_scrubFrames[srcIndex], slots)) return;
      final count = math.min(segFrames, n - s);
      final t = await engine.makeThumbnails(path, count * step, count,
          height: _scrubLongSide, longSide: true, startAt: s * step);
      // 畫面關了或素材被換掉就停
      if (!mounted || !identical(_scrubFrames[srcIndex], slots)) return;
      for (var i = 0; i < t.length && s + i < n; i++) {
        slots[s + i] = t[i];
      }
      // 段落之間喘口氣，把 CPU 讓給 UI
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  /// 拖曳時預熱鄰近幀的解碼：手指到之前圖已經在快取裡，換圖零延遲。
  /// 幀變密後預熱範圍跟著加大（涵蓋約前後半秒的滑動距離）
  void _prewarmScrubFrames(List<Uint8List?> frames, int fi) {
    for (var d = 1; d <= 6; d++) {
      for (final i in [fi - d, fi + d]) {
        if (i >= 0 && i < frames.length) {
          final b = frames[i];
          if (b != null) {
            precacheImage(
              ResizeImage(MemoryImage(b), width: _scrubLongSide),
              context,
            );
          }
        }
      }
    }
  }

  /// 從格子裡拿離 [fi] 最近的已抽好幀（漸進填滿期間就近湊合）
  static Uint8List? _nearestFrame(List<Uint8List?> slots, int fi) {
    for (var d = 0; d < slots.length; d++) {
      final a = fi - d;
      if (a >= 0 && slots[a] != null) return slots[a];
      final b = fi + d;
      if (b < slots.length && slots[b] != null) return slots[b];
    }
    return null;
  }

  /// 這個時間點附近有快取幀嗎（有 → 拖曳零 seek）
  bool get _activeScrubCached {
    final vids = _tl.videosAt(_position);
    if (vids.isEmpty) return false;
    for (final c in vids) {
      final slots = _scrubFrames[c.sourceIndex];
      if (slots == null || slots.isEmpty) return false;
      final src = _tl.sourceOf(c);
      final fi = (c.sourceTimeAt(_position) /
              math.max(0.01, src.duration) *
              slots.length)
          .floor()
          .clamp(0, slots.length - 1);
      // 附近 ±3 格內要有東西才算蓋到
      var found = false;
      for (var d = -3; d <= 3; d++) {
        final i = fi + d;
        if (i >= 0 && i < slots.length && slots[i] != null) {
          found = true;
          break;
        }
      }
      if (!found) return false;
    }
    return true;
  }

  /// 放手（220ms 沒新事件）→ 收掉快取幀、換回真影片畫面。
  /// seek 還在跑就再等一下，避免閃回舊畫面。
  void _tryEndScrub() {
    if (_seekInFlight) {
      _scrubEndTimer =
          Timer(const Duration(milliseconds: 80), _tryEndScrub);
      return;
    }
    if (_scrubbing && mounted) setState(() => _scrubbing = false);
  }

  Future<void> _pickVideo(int track) async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    _pause();
    _pushUndo();
    await _importVideoFromPath(picked.path,
        track: track, name: picked.name);
    if (mounted) setState(() {});
  }

  Future<void> _pickAudio(int track) async {
    ({String url, String name})? picked;
    try {
      picked = await pickAudioFile();
    } catch (e) {
      if (mounted) showHint(context, '無法開啟檔案選擇器：$e', error: true);
      return;
    }
    if (picked == null) return;
    _pause();
    final c = makeVideoController(picked.url);
    try {
      await c.initialize();
    } catch (_) {
      c.dispose();
      if (mounted) {
        showHint(context, '這個音訊檔無法播放，換一個試試', error: true);
      }
      return;
    }
    final dur = c.value.duration.inMilliseconds / 1000.0;
    if (dur <= 0) {
      c.dispose();
      if (mounted) {
        showHint(context, '讀不到這個音訊的長度，換一個試試', error: true);
      }
      return;
    }
    _pushUndo();
    final srcIndex = _tl.sources.length;
    _tl.sources.add(MediaSource(
      path: picked.url,
      name: picked.name,
      kind: ClipKind.audio,
      duration: dur,
    ));
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: dur,
      offset: _position, // 音樂從播放頭開始
      track: track,
    );
    _tl.clips.add(clip);
    _ctrls[clip.id] = c;
    if (mounted) setState(() => _sel = clip.id);
  }

  /// 素材選單（影片／圖片／文字／音樂）
  Future<ClipKind?> _askKind({String? title}) {
    return showModalBottomSheet<ClipKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              )
            else
              const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: kAmber),
              title: const Text('影片'),
              onTap: () => Navigator.pop(context, ClipKind.video),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: kAmber),
              title: const Text('圖片'),
              onTap: () => Navigator.pop(context, ClipKind.image),
            ),
            ListTile(
              leading: const Icon(Icons.title, color: kAmber),
              title: const Text('文字'),
              onTap: () => Navigator.pop(context, ClipKind.text),
            ),
            ListTile(
              leading: const Icon(Icons.music_note, color: kAmber),
              title: const Text('音樂 / 旁白'),
              onTap: () => Navigator.pop(context, ClipKind.audio),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _dispatchAdd(ClipKind? kind, int track) async {
    switch (kind) {
      case ClipKind.video:
        await _pickVideo(track);
      case ClipKind.image:
        await _pickImage(track);
      case ClipKind.text:
        await _addTextClip(track);
      case ClipKind.audio:
        await _pickAudio(track);
      case null:
        break;
    }
  }

  /// 工具列的「＋」
  Future<void> _addMediaChoice() async {
    final kind = await _askKind();
    // 影片接在目前軌道後面；圖片/文字/音樂放到新的一層
    await _dispatchAdd(
        kind,
        kind == ClipKind.video
            ? (_selClip?.track ?? 0)
            : _tl.usedTracks);
  }

  /// 軌道標籤上的「＋」
  Future<void> _addMedia(int track) async {
    final kind = await _askKind(title: '加素材到第 ${track + 1} 軌');
    await _dispatchAdd(kind, track);
  }

  /// 圖片素材：從播放頭開始、預設 4 秒，可用把手拉長
  Future<void> _pickImage(int track) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    _pause();
    final bytes = await picked.readAsBytes();
    // 解出圖片尺寸，之後縮放定位要用
    var imgW = 0, imgH = 0;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      imgW = frame.image.width;
      imgH = frame.image.height;
      frame.image.dispose();
    } catch (_) {}
    _pushUndo();
    final srcIndex = _tl.sources.length;
    _tl.sources.add(MediaSource(
      path: picked.path,
      name: picked.name,
      kind: ClipKind.image,
      duration: 3600, // 靜態素材，長度隨便拉
      w: imgW,
      h: imgH,
    ));
    _thumbs[srcIndex] = [bytes];
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: 4,
      offset: _position,
      track: track,
    );
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
    });
  }

  /// 文字輸入對話框（新增與編輯共用）
  Future<String?> _askText({String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文字'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(hintText: '輸入文字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: Text(initial.isEmpty ? '加入' : '儲存')),
        ],
      ),
    );
  }

  /// 點選已選取的文字片段 → 編輯內容與樣式
  Future<void> _editTextClip(TimelineClip clip) async {
    final src = _tl.sourceOf(clip);
    if (src.kind != ClipKind.text) return;
    src.textStyle ??= TextMark(text: src.name, sizeFrac: 0.06, opacity: 1);
    final st = src.textStyle!;
    final ctrl = TextEditingController(text: src.name);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // 視窗最多佔半個螢幕：上半留給預覽，邊調邊看即時效果
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void both(VoidCallback fn) {
            setSheet(fn);
            setState(() {});
          }

          Widget toggle(String label, bool v, ValueChanged<bool> on) => Row(
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12, color: kTextDim)),
                  const Spacer(),
                  Transform.scale(
                    scale: 0.72,
                    alignment: Alignment.centerRight,
                    child: Switch(value: v, onChanged: (x) => both(() => on(x))),
                  ),
                ],
              );

          Widget slider(String label, double v, double min, double max,
                  ValueChanged<double> on) =>
              SizedBox(
                height: 34,
                child: Row(
                  children: [
                    SizedBox(
                        width: 56,
                        child: Text(label,
                            style: const TextStyle(
                                fontSize: 12, color: kTextDim))),
                    Expanded(
                      child: Slider(
                        value: v.clamp(min, max),
                        min: min,
                        max: max,
                        onChanged: (x) => both(() => on(x)),
                      ),
                    ),
                  ],
                ),
              );

          Future<void> pickC(
              Color initial, void Function(int argb) apply) async {
            var color = initial;
            final ok = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('顏色'),
                content: SingleChildScrollView(
                  child: ColorPicker(
                    pickerColor: color,
                    enableAlpha: false,
                    labelTypes: const [],
                    onColorChanged: (c) => color = c,
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('確定')),
                ],
              ),
            );
            if (ok == true) both(() => apply(color.toARGB32()));
          }

          // 開關打開後的縮排細項：顏色小圓點列
          Widget colorRow(
                  String label, Color c, void Function(int) apply) =>
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontSize: 12, color: kTextDim)),
                      const Spacer(),
                      InkWell(
                        onTap: () => pickC(c, apply),
                        borderRadius: BorderRadius.circular(11),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: kBorder, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );

          return Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom),
            child: SafeArea(
              child: SingleChildScrollView(
                // 往下滑清單就收鍵盤（打完字回不去的解法）
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: ctrl,
                      autofocus: false,
                      textAlign: TextAlign.center,
                      textInputAction: TextInputAction.done,
                      style: TextStyle(
                        fontFamily: st.fontFamily,
                        fontSize: 20,
                        color: st.color,
                      ),
                      decoration: const InputDecoration(hintText: '文字'),
                      onChanged: (v) => both(() {
                        src.name = v;
                        st.text = v;
                      }),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: Container(
                              height: 38,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12),
                              decoration: BoxDecoration(
                                border: Border.all(color: kBorder),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: st.fontFamily,
                                icon: const Icon(Icons.expand_more,
                                    size: 16, color: kTextDim),
                                // 選單跟 App 同風格：面板色、圓角、
                                // 限高（蓋滿全螢幕太生硬）
                                dropdownColor: kPanelHi,
                                borderRadius: BorderRadius.circular(12),
                                menuMaxHeight: 320,
                                itemHeight: 48,
                                items: [
                                  for (final f in kFontOptions)
                                    DropdownMenuItem(
                                      value: f.family,
                                      child: Text(f.label,
                                          style: TextStyle(
                                              fontFamily: f.family,
                                              fontSize: 13)),
                                    ),
                                ],
                                onChanged: (v) => both(() =>
                                    st.fontFamily = v ?? 'NotoSansTC'),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: () async {
                            var color = st.color;
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('顏色'),
                                content: SingleChildScrollView(
                                  child: ColorPicker(
                                    pickerColor: color,
                                    enableAlpha: false,
                                    labelTypes: const [],
                                    onColorChanged: (c) => color = c,
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('取消')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('確定')),
                                ],
                              ),
                            );
                            if (ok == true) {
                              both(() =>
                                  st.colorValue = color.toARGB32());
                            }
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: st.color,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: kBorder, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    slider('大小', st.sizeFrac, 0.02, 0.2,
                        (v) => st.sizeFrac = v),
                    slider('透明', st.opacity, 0.05, 1,
                        (v) => st.opacity = v),
                    slider('間距', st.spacing, 0, 0.6,
                        (v) => st.spacing = v),
                    // 旋轉：±4° 內吸附回正，點角度數字一鍵歸零
                    SizedBox(
                      height: 34,
                      child: Row(
                        children: [
                          const SizedBox(
                              width: 56,
                              child: Text('旋轉',
                                  style: TextStyle(
                                      fontSize: 12, color: kTextDim))),
                          Expanded(
                            child: Slider(
                              value: st.rotation.clamp(-180, 180),
                              min: -180,
                              max: 180,
                              onChanged: (v) => both(() =>
                                  st.rotation = v.abs() < 4 ? 0 : v),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => both(() => st.rotation = 0),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 4),
                              child: Text('${st.rotation.round()}°',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: st.rotation.round() == 0
                                          ? kTextDim
                                          : kText)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    toggle('陰影', st.shadow, (v) => st.shadow = v),
                    toggle('描邊', st.outline, (v) => st.outline = v),
                    if (st.outline) ...[
                      colorRow('顏色', st.outlineColor,
                          (v) => st.outlineColorValue = v),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider('粗細', st.outlineWidth, 0.02, 0.2,
                            (v) => st.outlineWidth = v),
                      ),
                    ],
                    toggle('底色', st.bg, (v) => st.bg = v),
                    if (st.bg) ...[
                      colorRow(
                          '顏色', st.bgColor, (v) => st.bgColorValue = v),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider('透明度', st.bgOpacity, 0.05, 1,
                            (v) => st.bgOpacity = v),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider('大小', st.bgPad, 0.3, 2.5,
                            (v) => st.bgPad = v),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider('圓角', st.bgCorner, 0, 1,
                            (v) => st.bgCorner = v),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    _saveDraft();
  }

  /// 文字素材：輸入文字、從播放頭開始、預設 3 秒
  Future<void> _addTextClip(int track) async {
    final text = await _askText();
    if (text == null || text.isEmpty) return;
    _pause();
    _pushUndo();
    final srcIndex = _tl.sources.length;
    _tl.sources.add(MediaSource(
      path: '',
      name: text,
      kind: ClipKind.text,
      duration: 3600,
      textStyle: TextMark(
        text: text,
        sizeFrac: 0.06,
        colorValue: 0xFFFFFFFF,
        opacity: 1,
        shadow: true,
      ),
    ));
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: 3,
      offset: _position,
      track: track,
    );
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
    });
  }

  /// 複製浮水印：把浮水印「文字」複製成獨立的時間軸文字素材——
  /// 等於第二個浮水印，可以有自己的時間範圍、位置、大小
  void _duplicateWatermark() {
    final t = _settings.text;
    if (!t.enabled || t.text.trim().isEmpty) {
      showHint(context, '目前只有文字浮水印可以複製', error: true);
      return;
    }
    _pause();
    _pushUndo();
    final srcIndex = _tl.sources.length;
    final style = t.copy()..tiled = false; // 素材是單顆，平鋪無意義
    _tl.sources.add(MediaSource(
      path: '',
      name: t.text,
      kind: ClipKind.text,
      duration: 3600,
      textStyle: style,
    ));
    final start = _wmStart;
    final len = (_wmEndEff - start).clamp(0.5, 3600.0);
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: len,
      offset: start,
      track: _tl.firstFreeTrack(), // 放到新的一層，不壓到現有素材
      px: t.x,
      py: t.y,
    );
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
      _wmSel = false;
    });
    showHint(context, '已複製成文字素材，時間和位置都可獨立調整');
  }

  // ===== 播放 =====

  void _onTick(Duration elapsed) {
    if (!_playing) return;
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    // 時間軸位置以原速計；播放速度反映在實際前進速率上
    _position += dt * _speed;
    if (_position >= _tl.duration) {
      _position = _tl.duration;
      _pause();
    }
    _syncMedia();
    _followPlayhead();
    // 不做 setState：位置相關 UI 由 _posVN 各自小範圍重繪
  }

  void _play() {
    if (_tl.duration <= 0) return;
    if (_position >= _tl.duration - 0.01) _position = 0;
    setState(() => _playing = true);
    _lastTick = Duration.zero;
    _ticker.start();
    _syncMedia();
  }

  void _pause() {
    if (_ticker.isActive) _ticker.stop();
    for (final c in _ctrls.values) {
      if (c.value.isPlaying) c.pause();
    }
    if (_playing) setState(() => _playing = false);
  }

  /// 音量快取：值沒變就不打擾播放器（每格呼叫 setVolume 會卡）
  final Map<int, double> _lastVol = {};

  /// 片段「剛變成作用中」的追蹤：只在進場那一刻 seek 一次
  final Set<int> _wasActive = {};

  /// 每個片段上次大幅校正的時間（防連發）
  final Map<int, DateTime> _lastDriftFix = {};
  DateTime _lastVolSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// 讓每個素材的播放狀態跟上播放頭。
  /// 重要：Android 的 video_player 回報位置每 ~500ms 才更新一次，
  /// 拿過期位置對時鐘會誤判脫節 → seek 風暴＝跳針。
  /// 所以播放中只在「進場那一刻」seek 一次，之後放手讓解碼器自己跑，
  /// 除非真的大幅脫節（>1 秒）才校正、且同片段 2 秒內不重複校正。
  void _syncMedia() {
    final now = DateTime.now();
    final volDue = now.difference(_lastVolSync).inMilliseconds >= 100;
    if (volDue) _lastVolSync = now;
    for (final clip in _tl.clips) {
      final c = _ctrls[clip.id];
      if (c == null || !c.value.isInitialized) continue;
      final active = clip.covers(_position);
      if (!active) {
        _wasActive.remove(clip.id);
        if (c.value.isPlaying) c.pause();
        continue;
      }
      final want = clip.sourceTimeAt(_position);
      if (!_wasActive.contains(clip.id)) {
        // 進場：對準起點，之後不再打擾
        _wasActive.add(clip.id);
        c.seekTo(Duration(milliseconds: (want * 1000).round()));
      } else if (_playing) {
        final actual = c.value.position.inMilliseconds / 1000.0;
        if ((actual - want).abs() > 1.0 &&
            now
                    .difference(_lastDriftFix[clip.id] ??
                        DateTime.fromMillisecondsSinceEpoch(0))
                    .inMilliseconds >
                2000) {
          _lastDriftFix[clip.id] = now;
          c.seekTo(Duration(milliseconds: (want * 1000).round()));
        }
      }
      // 音量最多 10 次/秒（fade 中每格打 method channel 也會卡）
      if (volDue) {
        final trackMute = _mutedTracks.contains(clip.track) ? 0.0 : 1.0;
        final vol = (clip.volume * trackMute * clip.fadeFactorAt(_position))
            .clamp(0.0, 1.0);
        if ((vol - (_lastVol[clip.id] ?? -1)).abs() > 0.02) {
          _lastVol[clip.id] = vol;
          c.setVolume(vol);
        }
      }
      if (_playing) {
        if (!c.value.isPlaying) {
          c.setPlaybackSpeed(_speed * clip.speed);
          c.play();
        }
      } else if (c.value.isPlaying) {
        c.pause();
      }
    }
  }

  /// 刻度尺點按／拖曳：走拖曳管線（快取幀＋節流 seek），
  /// 不能每個手指事件都直接 seek（那也是一種 seek 風暴）
  void _seekScrub(double t) {
    if (_playing) _pause();
    _position = t.clamp(0.0, _tl.duration);
    _scrubbing = true;
    _scrubEndTimer?.cancel();
    _scrubEndTimer =
        Timer(const Duration(milliseconds: 220), _tryEndScrub);
    if (_activeScrubCached) {
      _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(const Duration(milliseconds: 120),
          () => _scrubSeek(force: true));
    } else {
      _scrubSeek();
    }
    _syncScrollToPosition();
  }

  /// 播放中讓時間軸跟著播放頭捲動。
  /// jumpTo 會強制整條時間軸重排，每格都跳會吃掉手機的畫格預算，
  /// 節流到 30fps（播放頭線本身照舊即時重繪，視覺上不掉格）。
  DateTime _lastFollow = DateTime.fromMillisecondsSinceEpoch(0);

  void _followPlayhead() {
    final now = DateTime.now();
    if (now.difference(_lastFollow).inMilliseconds < 33) return;
    _lastFollow = now;
    _syncScrollToPosition();
  }

  // ===== 片段操作 =====

  /// 放開片段：一次寫回位置與軌道。
  /// insert=true：插成新的一層，原本這層以下往下擠。
  /// insert=false：放到這一層；同軌重疊時後放的蓋在上面。
  void _dropClip(int id, double newOffset, int target, bool insert) {
    final clip = _selClipById(id);
    if (clip == null) return;
    _pushUndo();
    final t = target.clamp(0, 9);
    final oldUsed = _tl.usedTracks;
    setState(() {
      clip.offset = newOffset.clamp(0.0, 1e6);
      if (insert) {
        for (final c in _tl.clips) {
          if (c.id != id && c.track >= t) c.track++;
        }
      }
      clip.track = t;
      // 同軌重疊時，讓被拖的這個排在後面 = 蓋在上面
      _tl.clips.remove(clip);
      _tl.clips.add(clip);
      // 搬到最底下那條空軌時不要收斂，否則會被拉回原本的層
      if (insert || t < oldUsed) _tl.compactTracks();
    });
  }

  void _trimClip(int id, double dSec, bool fromLeft) {
    setState(() {
      for (final c in _tl.clips) {
        if (c.id != id) continue;
        final src = _tl.sourceOf(c);
        // 把手拖的是「時間軸秒」，變速片段要換算回素材秒
        final dSrc = dSec * c.speed;
        if (fromLeft) {
          final ns = (c.trimStart + dSrc).clamp(0.0, c.trimEnd - 0.3);
          // offset 位移用時間軸秒（素材差 ÷ 速度）
          c.offset = (c.offset + (ns - c.trimStart) / c.speed)
              .clamp(0.0, 1e6);
          c.trimStart = ns;
        } else {
          c.trimEnd =
              (c.trimEnd + dSrc).clamp(c.trimStart + 0.3, src.duration);
        }
      }
    });
  }

  /// 整條軌道換順序（連同軌上所有片段一起搬）
  void _reorderTrack(int from, int to) {
    final n = _tl.usedTracks;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    _pushUndo();
    final order = List.generate(n, (i) => i);
    order.insert(to, order.removeAt(from));
    // order[新位置] = 舊軌號 → 反查出對照表
    final map = <int, int>{};
    for (var i = 0; i < order.length; i++) {
      map[order[i]] = i;
    }
    setState(() {
      for (final c in _tl.clips) {
        c.track = map[c.track] ?? c.track;
      }
    });
  }

  /// 片段換軌。
  /// insert=true：插進這一層，原本這層以下全部往下擠（多開一層）
  /// insert=false：直接放到這一層，跟原有片段疊在一起（後放的蓋在上面）
  TimelineClip? _selClipById(int id) {
    for (final c in _tl.clips) {
      if (c.id == id) return c;
    }
    return null;
  }

  void _splitAtPlayhead() {
    final c = _selClip;
    if (c == null || !c.covers(_position)) {
      showHint(context, '先選一個片段，把播放頭移到片段中間再切割');
      return;
    }
    _pushUndo();
    final second = _tl.splitAt(c, _position);
    if (second == null) {
      _undoStack.removeLast(); // 沒切成，快照收回
      showHint(context, '太靠近邊緣了，每段至少 0.2 秒');
      return;
    }
    // 後半段需要自己的播放器
    final src = _tl.sourceOf(second);
    final ctrl = makeVideoController(src.path);
    ctrl.initialize().then((_) {
      if (mounted) setState(() {});
    });
    _ctrls[second.id] = ctrl;
    setState(() => _sel = second.id);
  }

  /// 點畫面上的浮水印文字＝直接改字（C 款彈窗、自動聚焦鍵盤）
  Future<void> _editWmText() async {
    _pushWmUndo();
    final ctrl = TextEditingController(text: _settings.text.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kBorder),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  maxLines: null,
                  style: TextStyle(
                    fontFamily: _settings.text.fontFamily,
                    fontSize: 20,
                    color: _settings.text.color,
                  ),
                  decoration: const InputDecoration(
                    hintText: '浮水印文字',
                    filled: true,
                    fillColor: Color(0xFF0F0F11),
                  ),
                  onSubmitted: (_) => Navigator.pop(context, true),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'NotoSansTC'),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('確定'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: TextButton.styleFrom(
                    foregroundColor: kTextDim,
                    minimumSize: const Size.fromHeight(40),
                  ),
                  child: const Text('取消',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _settings.text.text = ctrl.text;
        if (ctrl.text.trim().isNotEmpty) _settings.text.enabled = true;
        _wmSync++; // 面板輸入框同步
      });
      _saveDraft();
    }
  }

  /// 刪除浮水印（整組文字＋圖片清空；按復原可以救回）
  void _deleteWatermark() {
    _pushUndo();
    setState(() {
      _settings.text = TextMark(text: '');
      _settings.logo = LogoMark();
      _settings.animation = WmAnimation.none;
      _wmSel = false;
      _wmStart = 0;
      _wmEnd = null;
      _wmSync++; // 浮水印面板同步內部狀態
    });
    _saveDraft();
  }

  void _deleteSelected() {
    final c = _selClip;
    if (c == null) return;
    _pushUndo();
    // 播放器留著（復原時要用），畫面 dispose 時才統一清
    _ctrls[c.id]?.pause();
    setState(() {
      _tl.clips.remove(c);
      _sel = -1;
    });
  }

  /// 長按片段 → 複製 / 貼上 / 刪除
  Future<void> _showClipMenu(int id, Offset pos) async {
    final clip = _selClipById(id);
    if (clip == null) return;
    setState(() {
      _sel = id;
      _wmSel = false;
    });
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: kBorder),
      ),
      items: [
        if (_tl.sourceOf(clip).kind == ClipKind.text)
          _menuItem('edit', Icons.edit_outlined, '編輯文字'),
        _menuItem('copy', Icons.copy, '複製'),
        _menuItem('paste', Icons.content_paste, '貼上',
            enabled: _clipboard != null),
        _menuItem('delete', Icons.delete_outline, '刪除'),
      ],
    );
    switch (action) {
      case 'edit':
        await _editTextClip(clip);
      case 'copy':
        setState(() => _clipboard = clip.copy());
      case 'paste':
        await _pasteClipboard();
      case 'delete':
        _deleteSelected();
    }
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label,
      {bool enabled = true}) {
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16, color: enabled ? kIcon : kTextDim),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  fontSize: 13, color: enabled ? kText : kTextDim)),
        ],
      ),
    );
  }

  /// 長按空白處 → 在那個位置貼上
  Future<void> _showEmptyMenu(int track, double t, Offset pos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: kBorder),
      ),
      items: [
        _menuItem('paste', Icons.content_paste, '貼上',
            enabled: _clipboard != null),
      ],
    );
    if (action == 'paste') {
      await _pasteClipboard(at: t, track: track);
    }
  }

  /// 貼上：預設以播放頭為起點、放回原本的軌道；
  /// 從空白處長按貼上時則落在按的位置和那一軌。
  Future<void> _pasteClipboard({double? at, int? track}) async {
    final cb = _clipboard;
    if (cb == null) return;
    _pushUndo();
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: cb.sourceIndex,
      trimStart: cb.trimStart,
      trimEnd: cb.trimEnd,
      offset: at ?? _position,
      // 沒指定軌道時：優先貼到目前選取片段的那一軌
      //（長按時間軸空白處＝貼到指定軌道與位置）
      track: (track ?? _selClipById(_sel)?.track ?? cb.track)
          .clamp(0, _tl.usedTracks),
      volume: cb.volume,
    );
    final src = _tl.sources[cb.sourceIndex];
    final ctrl = makeVideoController(src.path);
    ctrl.initialize().then((_) {
      if (mounted) setState(() {});
    });
    _ctrls[clip.id] = ctrl;
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
    });
  }

  @override
  void dispose() {
    _frameSettle?.cancel();
    _scrubSettleTimer?.cancel();
    _scrubEndTimer?.cancel();
    _ticker.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _tlScroll.dispose();
    _tabs.dispose();
    super.dispose();
  }

  String _fmt(double sec) {
    final d = Duration(milliseconds: (sec * 1000).round());
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = ((d.inMilliseconds % 1000) ~/ 100).toString();
    return '$m:$s.$ms';
  }

  // ===== 匯出 =====

  Future<void> _export() async {
    if (_exporting) return;
    if (!engine.videoExportSupported) {
      showHint(context, '影片匯出需要 FFmpeg，只在手機 App 上提供');
      return;
    }
    _pause();
    setState(() => _exporting = true);

    final progress = ValueNotifier<double>(0);
    var cancelRequested = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (context, setDialog) => AlertDialog(
            title: const Text('匯出中…'),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: v > 0 ? v : null),
                  const SizedBox(height: 12),
                  Text('${(v * 100).toStringAsFixed(0)} %'),
                  const SizedBox(height: 4),
                  const Text('高畫質編碼比較花時間，請耐心等候',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey)),
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

    String message;
    bool ok = false;
    var cancelled = false;
    try {
      final (outW, outH) =
          computeCanvasSize(_tl, _resolution, _canvasRatio);
      Uint8List? wmPng;
      if (_settings.hasAnyMark) {
        wmPng = await WatermarkRenderer.renderOverlayPng(_settings, outW, outH);
      }
      // 文字素材 → 渲染成整版透明 PNG
      // 文字圖層：每個片段渲染一張（位置/縮放/樣式烘進 PNG）
      final overlayPngs = <int, Uint8List>{};
      for (final c in _tl.clips) {
        final src = _tl.sources[c.sourceIndex];
        if (src.kind == ClipKind.text) {
          final st = (src.textStyle ?? TextMark(text: src.name)).copy()
            ..text = src.name;
          overlayPngs[c.id] = await WatermarkRenderer.renderTextClipPng(
              st, c.px, c.py, c.scale, outW, outH);
        }
      }
      final result = await engine.exportVideoToGallery(
        ExportSpec(
          sources: _tl.sources,
          clips: [
            for (final c in _tl.clips)
              c.copy()
                ..volume =
                    _mutedTracks.contains(c.track) ? 0 : c.volume
          ],
          timelineDuration: _tl.duration,
          speed: _speed,
          watermarkPng: wmPng,
          outW: outW,
          outH: outH,
          wmStart: _wmStart,
          wmEnd: _wmEndEff,
          wmAnimation: _settings.animation,
          wmSpeed: _settings.animSpeed,
          wmRange: _settings.animRange,
          overlayPngs: overlayPngs,
          crf: _quality.crf,
        ),
        onProgress: (v) => progress.value = v,
      );
      ok = result.ok;
      message = result.message;
      cancelled = result.cancelled;
    } catch (e) {
      message = '匯出失敗：$e';
    }

    if (mounted) {
      Navigator.of(context).pop();
      // 取消是使用者自己的決定，用中性提示就好，不當錯誤
      showHint(context, message,
          error: !ok && !cancelled,
          duration: Duration(seconds: ok || cancelled ? 3 : 8));
    }
    setState(() => _exporting = false);
  }

  // ===== 畫面 =====

  /// 離開保護：問清楚要留草稿還是捨棄（C 款直排大按鈕）
  /// 返回：先退回上一個分頁（匯出→浮水印→剪輯），
  /// 已經在剪輯分頁才問要不要離開專案
  void _handleBack() {
    if (_tabs.index > 0) {
      _tabs.animateTo(_tabs.index - 1);
      return;
    }
    _confirmLeave();
  }

  Future<void> _confirmLeave() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kBorder),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('離開專案？',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: kText)),
                const SizedBox(height: 8),
                const Text('保留草稿之後可以從首頁繼續剪',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: kTextDim, height: 1.55)),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'NotoSansTC'),
                  ),
                  onPressed: () => Navigator.pop(context, 'save'),
                  child: const Text('保留草稿'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, 'discard'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kTextDim,
                    minimumSize: const Size.fromHeight(44),
                    side: const BorderSide(color: kClipBorder),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child:
                      const Text('捨棄', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(height: 2),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    foregroundColor: kTextDim,
                    minimumSize: const Size.fromHeight(40),
                  ),
                  child: const Text('繼續編輯',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'save') {
      await _saveDraft();
      if (mounted) Navigator.of(context).pop();
    } else if (action == 'discard') {
      await clearDraft();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      appBar: AppBar(title: const Text('影片編輯')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(flex: 5, child: _buildPreview()),
                _buildControlBar(),
                Expanded(
                  flex: 5,
                  child: TabBarView(
                    controller: _tabs,
                    // 左右滑動保留給時間軸，分頁只用底部按鈕切換
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _buildTimelineTab(),
                      WatermarkPanel(
                        settings: _settings,
                        onChanged: () => setState(() {}),
                        onBeforeChange: _pushWmUndo,
                        syncVersion: _wmSync,
                        showAnimation: true,
                      ),
                      _buildExportTab(),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: !_ready
          ? null
          : Container(
              decoration: const BoxDecoration(
                color: kBg,
                border: Border(top: BorderSide(color: kBorder)),
              ),
              child: SafeArea(
                top: false,
                child: TabBar(
                  controller: _tabs,
                  indicatorColor: Colors.transparent,
                  dividerHeight: 0,
                  labelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      fontFamily: 'NotoSansTC'),
                  unselectedLabelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      fontFamily: 'NotoSansTC'),
                  tabs: const [
                    Tab(
                        icon: Icon(Icons.content_cut, size: 20),
                        text: '剪輯',
                        height: 54,
                        iconMargin: EdgeInsets.only(bottom: 2)),
                    Tab(
                        icon: Icon(Icons.branding_watermark, size: 20),
                        text: '浮水印',
                        height: 54,
                        iconMargin: EdgeInsets.only(bottom: 2)),
                    Tab(
                        icon: Icon(Icons.ios_share, size: 20),
                        text: '匯出',
                        height: 54,
                        iconMargin: EdgeInsets.only(bottom: 2)),
                  ],
                ),
              ),
            ),
    ),
    );
  }

  /// 預覽下方的控制列（CapCut 式）：播放鈕左、時間碼中、復原/重做右
  Widget _buildControlBar() {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              iconSize: 28,
              color: kText,
              icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: () => _playing ? _pause() : _play(),
            ),
          ),
          // RepaintBoundary：時間碼每格重繪不波及整條播放列
          RepaintBoundary(
            child: ValueListenableBuilder<double>(
              valueListenable: _posVN,
              builder: (context, pos, _) => Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: _fmt(pos),
                    style: const TextStyle(
                        color: kText, fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: ' / ${_fmt(_tl.duration)}',
                    style: const TextStyle(color: kTextDim),
                  ),
                ]),
                style: const TextStyle(
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  iconSize: 20,
                  color: _undoStack.isEmpty ? kTextDim : kText,
                  icon: const Icon(Icons.undo_rounded),
                  onPressed: _undoStack.isEmpty ? null : _undoAction,
                ),
                IconButton(
                  iconSize: 20,
                  color: _redoStack.isEmpty ? kTextDim : kText,
                  icon: const Icon(Icons.redo_rounded),
                  onPressed: _redoStack.isEmpty ? null : _redoAction,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 提示訊息錨定用：貼在預覽區下緣
  final _previewKey = GlobalKey();

  Widget _buildPreview() {
    final baseVideo = _activeVideo;
    final baseCtrl = baseVideo == null ? null : _ctrls[baseVideo.id];
    final baseAspect = (baseCtrl != null && baseCtrl.value.isInitialized)
        ? baseCtrl.value.aspectRatio
        : (_tl.sources.isEmpty ? 16 / 9 : _tl.sources.first.aspect);
    // 畫布比例：選了固定比例就用它（跟匯出一致）
    final canvasAspect = _canvasRatio.value ?? baseAspect;

    return Listener(
      // 雙指縮放選取中的元素（浮水印／片段）。
      // 用 Listener 不搶手勢：元素本身的觸控範圍太小，
      // 兩指張開時第二指會落在範圍外，改在整個預覽區偵測
      onPointerDown: _previewPinchDown,
      onPointerMove: _previewPinchMove,
      onPointerUp: (e) => _previewPinchUp(e.pointer),
      onPointerCancel: (e) => _previewPinchUp(e.pointer),
      child: GestureDetector(
      // 點預覽區任何空白（含畫布外的灰邊）＝取消所有選取＋收鍵盤
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() {
          _sel = -1;
          _wmSel = false;
        });
      },
      child: Container(
      key: _previewKey,
      // 預覽區背景比純黑亮一點，黑色畫布靠對比自己浮出來（CapCut 式）
      color: const Color(0xFF1B1B1F),
      child: Stack(children: [
      Center(
      child: AspectRatio(
        aspectRatio: canvasAspect,
        child: Stack(fit: StackFit.expand, children: [
          // 點預覽空白處＝取消所有選取＋收鍵盤
          GestureDetector(
            onTap: () {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() {
                _sel = -1;
                _wmSel = false;
              });
            },
            child: Container(color: Colors.black),
          ),
          // RepaintBoundary：預覽圖層重繪不波及頁面其他部分
          RepaintBoundary(
          child: ClipRect(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;
            // 位置驅動的圖層（影片/圖片/文字/浮水印）只在這個範圍內
            // 隨播放頭重繪（節流 30fps），播放時不再整頁 setState
            return ValueListenableBuilder<double>(
                valueListenable: _frameVN,
                builder: (context, pos, _) {

            // 依片段的位置/縮放算出圖層的框（跟匯出同一套算法）
            Rect layerBox(TimelineClip c, double srcAspect) {
              double fitW, fitH;
              if (srcAspect >= canvasAspect) {
                fitW = w;
                fitH = w / srcAspect;
              } else {
                fitH = h;
                fitW = h * srcAspect;
              }
              final w2 = fitW * c.scale;
              final h2 = fitH * c.scale;
              return Rect.fromLTWH(
                  c.px * w - w2 / 2, c.py * h - h2 / 2, w2, h2);
            }

            final children = <Widget>[];
            Rect? selRect;
            TimelineClip? selVisual;

            // 影片圖層（由下層往上疊 = 真 PiP）
            final vids = _tl.videosAt(_position);
            for (final c in vids) {
              final ctrl = _ctrls[c.id];
              if (ctrl == null || !ctrl.value.isInitialized) continue;
              final r = layerBox(c, ctrl.value.aspectRatio);
              // 拖曳中：真影片上面疊快取幀。獨立小元件直接聽 _posVN
              // 全速換圖（不吃 30fps 節流），搭配鄰近幀預熱解碼＝跟手
              final frames = _scrubbing ? _scrubFrames[c.sourceIndex] : null;
              children.add(Positioned.fromRect(
                rect: r,
                child: GestureDetector(
                  // 點畫面上的影片＝選取它（等同在時間軸點該片段）
                  onTap: () => setState(() {
                    _sel = c.id;
                    _wmSel = false;
                  }),
                  child: Opacity(
                  opacity: c.fadeFactorAt(_position),
                  child: Stack(fit: StackFit.expand, children: [
                    ctrl.view(key: ValueKey('pv-${c.id}')),
                    if (frames != null && frames.isNotEmpty)
                      IgnorePointer(
                        child: ValueListenableBuilder<double>(
                          valueListenable: _posVN,
                          builder: (context, pos, _) {
                            final src = _tl.sourceOf(c);
                            final fi = (c.sourceTimeAt(pos) /
                                    math.max(0.01, src.duration) *
                                    frames.length)
                                .floor()
                                .clamp(0, frames.length - 1);
                            final f = _nearestFrame(frames, fi);
                            _prewarmScrubFrames(frames, fi);
                            if (f == null) {
                              return const SizedBox.shrink();
                            }
                            return Image.memory(f,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                // 以顯示尺寸解碼：省解碼時間與記憶體，
                                // 快取命中率大增
                                cacheWidth: _scrubLongSide);
                          },
                        ),
                      ),
                  ]),
                  ),
                ),
              ));
              if (c.id == _sel) {
                selRect = r;
                selVisual = c;
              }
            }
            if (vids.isEmpty) {
              children.add(const Center(
                child: Text('這個時間點沒有畫面',
                    style: TextStyle(color: kTextDim, fontSize: 12)),
              ));
            }

            // 圖片 / 文字圖層（永遠疊在影片上面，由下層往上畫）
            for (final c in _tl.overlaysAt(_position)) {
              final src = _tl.sourceOf(c);
              if (src.kind == ClipKind.image &&
                  (_thumbs[c.sourceIndex]?.isNotEmpty ?? false)) {
                final r = layerBox(c, src.aspect);
                children.add(Positioned.fromRect(
                  rect: r,
                  child: GestureDetector(
                    // 點圖片圖層＝選取
                    onTap: () => setState(() {
                      _sel = c.id;
                      _wmSel = false;
                    }),
                    child: Opacity(
                      opacity: c.fadeFactorAt(_position),
                      child: Image.memory(_thumbs[c.sourceIndex]![0],
                          fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                  ),
                ));
                if (c.id == _sel) {
                  selRect = r;
                  selVisual = c;
                }
              } else if (src.kind == ClipKind.text) {
                final st = src.textStyle ?? TextMark(text: src.name);
                final fontSize = st.sizeFrac * w * c.scale;
                final style = TextStyle(
                  fontFamily: st.fontFamily,
                  fontSize: fontSize,
                  letterSpacing: fontSize * st.spacing,
                  color: st.color.withValues(alpha: st.opacity),
                  shadows: st.shadow
                      ? [
                          Shadow(
                            color: Colors.black
                                .withValues(alpha: 0.55 * st.opacity),
                            blurRadius: fontSize * 0.08,
                            offset:
                                Offset(fontSize * 0.03, fontSize * 0.03),
                          ),
                        ]
                      : null,
                );
                final painter = TextPainter(
                  text: TextSpan(text: src.name, style: style),
                  textDirection: TextDirection.ltr,
                )..layout();
                final r = Rect.fromCenter(
                    center: Offset(c.px * w, c.py * h),
                    width: painter.width,
                    height: painter.height);
                Widget textW(TextStyle s2) => Text(src.name,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    textScaler: TextScaler.noScaling,
                    style: s2);
                children.add(Positioned(
                  left: r.left,
                  top: r.top,
                  child: GestureDetector(
                    // 點文字＝選取＋直接進入編輯
                    onTap: () {
                      setState(() {
                        _sel = c.id;
                        _wmSel = false;
                      });
                      _editTextClip(c);
                    },
                    child: Opacity(
                    opacity: c.fadeFactorAt(_position),
                    child: Transform.rotate(
                    angle: st.rotation * 3.1415926535 / 180,
                    child: Container(
                      padding: st.bg
                          ? EdgeInsets.symmetric(
                              horizontal: fontSize * 0.35 * st.bgPad,
                              vertical: fontSize * 0.18 * st.bgPad)
                          : EdgeInsets.zero,
                      decoration: st.bg
                          ? BoxDecoration(
                              color: st.bgColor
                                  .withValues(alpha: st.bgOpacity),
                              borderRadius: BorderRadius.circular(
                                  fontSize * st.bgCorner),
                            )
                          : null,
                      child: st.outline
                          ? Stack(children: [
                              textW(style.copyWith(
                                color: null,
                                shadows: null,
                                foreground: Paint()
                                  ..style = PaintingStyle.stroke
                                  ..strokeWidth =
                                      fontSize * st.outlineWidth
                                  ..color = st.outlineColor
                                      .withValues(alpha: st.opacity),
                              )),
                              textW(style),
                            ])
                          : textW(style),
                    ),
                    ),
                  ),
                  ),
                ));
                if (c.id == _sel) {
                  selRect = r.inflate(8);
                  selVisual = c;
                }
              }
            }

            // 選取中的圖層：細白框＋四角把手 + 拖曳移動 / 雙指縮放
            if (selRect != null && selVisual != null) {
              final sc = selVisual;
              children.add(Positioned.fromRect(
                rect: selRect,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  // 雙擊＝回正中央、恢復原始大小（不小心拖歪的救援）
                  onDoubleTap: () {
                    _pushUndo();
                    setState(() {
                      sc.px = 0.5;
                      sc.py = 0.5;
                      sc.scale = 1.0;
                    });
                    _saveDraft();
                  },
                  onScaleStart: (d) {
                    _pushUndo(); // 拖歪了可以按復原
                    _gestureStartPx = sc.px;
                    _gestureStartPy = sc.py;
                    _gestureStartScale = sc.scale;
                    _gestureStartFocal = d.focalPoint;
                  },
                  onScaleUpdate: (d) {
                    setState(() {
                      sc.px = (_gestureStartPx +
                              (d.focalPoint.dx - _gestureStartFocal.dx) / w)
                          .clamp(0.0, 1.0);
                      sc.py = (_gestureStartPy +
                              (d.focalPoint.dy - _gestureStartFocal.dy) / h)
                          .clamp(0.0, 1.0);
                      sc.scale =
                          (_gestureStartScale * d.scale).clamp(0.05, 3.0);
                    });
                  },
                  onScaleEnd: (_) => _saveDraft(),
                  // 文字素材有旋轉時，選取框跟著轉
                  child: Transform.rotate(
                    angle: (_tl.sourceOf(sc).kind == ClipKind.text
                            ? (_tl.sourceOf(sc).textStyle?.rotation ?? 0)
                            : 0.0) *
                        math.pi /
                        180,
                    child:
                        CustomPaint(painter: _SelectionFramePainter()),
                  ),
                ),
              ));
            }

            if (_wmVisibleNow) {
              children.add(WatermarkLayer(
                settings: _settings,
                onChanged: () => setState(() {}),
                onDragStart: _pushWmUndo,
                selected: _wmSel,
                time: pos, // 動畫跟著播放頭走

                // 點浮水印 Logo＝選取＋切到浮水印分頁
                onTap: () {
                  setState(() {
                    _wmSel = true;
                    _sel = -1;
                  });
                  _tabs.animateTo(1);
                },
                // 點浮水印文字＝直接跳出輸入框改字
                onTapText: () {
                  setState(() {
                    _wmSel = true;
                    _sel = -1;
                  });
                  _tabs.animateTo(1);
                  _editWmText();
                },
              ));
            }

            return Stack(fit: StackFit.expand, children: children);
                });
          }),
          ),
          ),
        ]),
      ),
      ),
      // 比例膠囊釘在整個預覽區右上角（不跟畫布走）
      _canvasHint(),
      ]),
      ),
      ),
    );
  }

  // ===== 預覽區雙指縮放（選取中的浮水印或片段）=====
  final Map<int, Offset> _pvPts = {};
  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;
  double _pvBaseClip = 1;

  void _previewPinchDown(PointerDownEvent e) {
    _pvPts[e.pointer] = e.position;
    if (_pvPts.length != 2) return;
    final p = _pvPts.values.toList();
    final d = (p[0] - p[1]).distance;
    if (d <= 20) return;
    _pvBaseDist = d;
    _pvBaseText = _settings.text.sizeFrac;
    _pvBaseLogo = _settings.logo.sizeFrac;
    _pvBaseClip = _selClipById(_sel)?.scale ?? 1.0;
    _pushUndo();
  }

  void _previewPinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    setState(() {
      if (_wmSel) {
        // 浮水印：文字與圖片一起等比縮放
        final t = _settings.text;
        if (t.enabled && t.text.trim().isNotEmpty) {
          t.sizeFrac = (_pvBaseText * f).clamp(0.015, 0.5);
        }
        if (_settings.logo.enabled) {
          _settings.logo.sizeFrac =
              (_pvBaseLogo * f).clamp(0.03, 0.9);
        }
      } else {
        _selClipById(_sel)?.scale =
            (_pvBaseClip * f).clamp(0.05, 3.0);
      }
    });
  }

  void _previewPinchUp(int pointer) {
    _pvPts.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) {
      _pvBaseDist = null;
      _saveDraft();
    }
  }

  /// 右上角比例小標籤：常駐顯示目前畫面比例，點了直接開比例選單
  Widget _canvasHint() {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: _openRatioSheet,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.aspect_ratio,
                    size: 12, color: kTextDim),
                const SizedBox(width: 4),
                Text(_canvasRatio.label,
                    style: const TextStyle(
                        fontSize: 10.5, color: kIcon, height: 1.2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 預覽手勢的起始狀態
  double _gestureStartPx = 0.5;
  double _gestureStartPy = 0.5;
  double _gestureStartScale = 1.0;
  Offset _gestureStartFocal = Offset.zero;

  /// 工具列按鈕：圖示＋中文標示（CapCut 式：字跟圖示同亮度、清晰不發灰）
  Widget _toolBtn(IconData icon, String label, VoidCallback? onTap,
      {String? tip, int quarterTurns = 0}) {
    final on = onTap != null;
    final color = on ? kText : kTextDim.withValues(alpha: 0.4);
    return Tooltip(
      message: tip ?? label,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RotatedBox(
                  quarterTurns: quarterTurns,
                  child: Icon(icon, size: 21, color: color)),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.15,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w400,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineTab() {
    if (_pxPerSec <= 0) {
      final screenW = MediaQuery.of(context).size.width - 60;
      _pxPerSec =
          (screenW / (_tl.duration <= 0 ? 10 : _tl.duration)).clamp(6.0, 60.0);
    }
    final sel = _selClip;

    return LayoutBuilder(builder: (context, box) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 時間軸（需要時自己捲動；下方空白區的橫滑也捲時間軸）
          Expanded(
            child: Listener(
              // 捏合偵測放在整個分頁最外層：空白處一樣能縮放
              onPointerDown: _pinchDown,
              onPointerMove: _pinchMove,
              onPointerUp: (e) => _pinchUp(e.pointer),
              onPointerCancel: (e) => _pinchUp(e.pointer),
              child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 點時間軸區域的任何空白＝取消所有選取＋收鍵盤
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() {
                  _sel = -1;
                  _wmSel = false;
                });
              },
              onHorizontalDragUpdate: (d) {
                if (_tlPinching) return; // 縮放中不搶橫向捲動
                if (_tlScroll.hasClients) {
                  _tlScroll.jumpTo((_tlScroll.offset - d.delta.dx)
                      .clamp(0.0, _tlScroll.position.maxScrollExtent));
                }
              },
              child: SingleChildScrollView(
              // 雙指縮放時間軸時暫停垂直捲動，縮放手勢才吃得到
              physics: _tlPinching
                  ? const NeverScrollableScrollPhysics()
                  : null,
              // 滾輪縮放要放在捲動容器「內側」才搶得贏：
              // PointerSignal 是最內層先註冊先贏，放外面會被垂直捲動吃掉。
              // opaque 讓上下留白區也吃得到滾輪
              child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: _wheelZoom,
              // 內容比視口矮時直向置中（CapCut 版型），不要貼著頂
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight: (box.maxHeight - 60).clamp(0.0, 1e9)),
                child: Center(
                child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 14, 10, 0),
                // RepaintBoundary：時間軸的重繪與頁面其他部分互不打擾
                child: RepaintBoundary(
                child: TimelineEditor(
                  timeline: _tl,
                  thumbs: _thumbs,
                  selectedId: _sel,
                  playhead: _posVN,
                  pxPerSec: _pxPerSec,
                  scrollController: _tlScroll,
                  onSelect: (id) => setState(() {
                    _sel = id;
                    _wmSel = false;
                  }),
                  onSeek: _seekScrub,
                  onTrim: _trimClip,
                  onTrimStart: _pushUndo,
                  onDrop: _dropClip,
                  onAddMedia: _addMedia,
                  onReorderTrack: _reorderTrack,
                  mutedTracks: _mutedTracks,
                  onToggleMute: (t) => setState(() {
                    if (!_mutedTracks.remove(t)) _mutedTracks.add(t);
                    _syncMedia();
                  }),
                  onLongPressClip: _showClipMenu,
                  onLongPressEmpty: _showEmptyMenu,
                  onTapSelectedClip: (id) {
                    final c = _selClipById(id);
                    if (c != null &&
                        _tl.sourceOf(c).kind == ClipKind.text) {
                      _editTextClip(c);
                    }
                  },
                  onLiftChanged: (v) => _lifting = v,
                  // 捏合由外層偵測，這裡只用來鎖住橫向捲動
                  pinching: _tlPinching,
                  // 桌面滾輪縮放：下限 1px/秒，長片也能整條盡收眼底
                  onZoom: (v) {
                    setState(() => _pxPerSec = v.clamp(1.0, 200.0));
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _syncScrollToPosition());
                  },
                  watermark: _settings.hasAnyMark
                      ? (start: _wmStart, end: _wmEndEff)
                      : null,
                  wmLabel: _settings.text.enabled &&
                          _settings.text.text.trim().isNotEmpty
                      ? _settings.text.text
                      : '浮水印',
                  wmSelected: _wmSel,
                  // 點浮水印軌＝選取＋自動切到浮水印分頁
                  onSelectWm: () {
                    final wasSel = _wmSel;
                    setState(() {
                      _wmSel = true;
                      _sel = -1;
                    });
                    if (!wasSel) _tabs.animateTo(1);
                  },
                  onMoveWm: (ns) => setState(() {
                    final len = _wmEndEff - _wmStart;
                    final s =
                        ns.clamp(0.0, (_tl.duration - len).clamp(0.0, 1e6));
                    _wmStart = s;
                    _wmEnd = s + len;
                  }),
                  onTrimWm: (d, fromLeft) => setState(() {
                    if (fromLeft) {
                      _wmStart =
                          (_wmStart + d).clamp(0.0, _wmEndEff - 0.3);
                    } else {
                      _wmEnd = (_wmEndEff + d)
                          .clamp(_wmStart + 0.3, _tl.duration);
                    }
                  }),
                ),
                ),
              ),
                ),
              ),
            ),
            ),
            ),
            ),
          ),
          // 底部工具列（取代原本的上方工具列與音量列）
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 2),
            // 按鈕加了文字後可能塞不下，塞不下就橫向捲動（同 CapCut）
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth),
                child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 直式 splitscreen 轉 90°＝一段切成兩段；剪刀留給「剪輯」分頁
                _toolBtn(Icons.splitscreen, '切割', _splitAtPlayhead,
                    tip: '在播放處切割', quarterTurns: 1),
                _toolBtn(
                    Icons.delete_outline,
                    '刪除',
                    _wmSel
                        ? _deleteWatermark
                        : (sel == null ? null : _deleteSelected),
                    tip: _wmSel ? '刪除浮水印' : '刪除片段'),
                _toolBtn(
                    Icons.copy,
                    '複製',
                    _wmSel
                        ? _duplicateWatermark
                        : (sel == null
                            ? null
                            : () =>
                                setState(() => _clipboard = sel.copy())),
                    tip: _wmSel ? '複製浮水印成素材' : '複製選取片段'),
                _toolBtn(Icons.content_paste, '貼上',
                    _clipboard == null ? null : _pasteClipboard,
                    tip: '貼在播放處'),
                _toolBtn(
                    Icons.open_in_full,
                    '大小',
                    (sel == null ||
                            _tl.sourceOf(sel).kind == ClipKind.audio)
                        ? null
                        : () => _openScaleSheet(sel),
                    tip: '縮放物件大小'),
                _toolBtn(Icons.speed, '速度', _openSpeedSheet, tip: '播放速度'),
                _toolBtn(Icons.auto_awesome, '效果',
                    sel == null ? null : () => _openClipOptions(sel),
                    tip: '音量與淡化'),
                _toolBtn(Icons.add, '加素材', _addMediaChoice),
              ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  /// 彈窗裡的一列選項：標題＋輸出尺寸副標＋選中勾勾
  Widget _optionRow({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    bool first = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        decoration: first
            ? null
            : const BoxDecoration(
                border: Border(top: BorderSide(color: kPanelHi))),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w400,
                        color: selected ? kAmber : kText,
                      )),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 10.5,
                          color: kTextDim,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 17, color: kAmber),
          ],
        ),
      ),
    );
  }

  /// 輸出畫面比例：置中彈窗，一行一個選項（附輸出尺寸），點了套用關窗
  void _openRatioSheet() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('畫面比例'),
        contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
        content: SizedBox(
          width: 270,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, r) in CanvasRatio.values.indexed)
                Builder(builder: (context) {
                  final (w, h) = computeCanvasSize(_tl, _resolution, r);
                  return _optionRow(
                    title: r.label,
                    subtitle: '$w×$h',
                    selected: _canvasRatio == r,
                    first: i == 0,
                    onTap: () {
                      setState(() => _canvasRatio = r);
                      _saveDraft();
                      Navigator.pop(context);
                    },
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  /// 縮放物件大小（影片/圖片/文字在畫面上的尺寸；跟預覽雙指縮放同一個值）
  void _openScaleSheet(TimelineClip clip) {
    _pushUndo();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('大小',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${(clip.scale * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 12,
                          color: kTextDim,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
              const SizedBox(height: 6),
              Slider(
                value: clip.scale.clamp(0.05, 3.0),
                min: 0.05,
                max: 3.0,
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => clip.scale = v);
                },
              ),
              // 回復預設：置中、原始大小
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    setSheet(() {});
                    setState(() {
                      clip.scale = 1.0;
                      clip.px = 0.5;
                      clip.py = 0.5;
                    });
                  },
                  style:
                      TextButton.styleFrom(foregroundColor: kTextDim),
                  child: const Text('重設',
                      style: TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(_saveDraft);
  }

  /// 片段選項：音量（有聲音的素材）＋淡入淡出
  void _openClipOptions(TimelineClip clip) {
    final hasAudio = _tl.sourceOf(clip).kind == ClipKind.video ||
        _tl.sourceOf(clip).kind == ClipKind.audio;
    _pushUndo();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Widget row(String label, double value, double max, String suffix,
              ValueChanged<double> onChanged) {
            return Row(
              children: [
                SizedBox(
                    width: 44,
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: 12, color: kTextDim))),
                Expanded(
                  child: Slider(
                    value: value.clamp(0, max),
                    max: max,
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => onChanged(v));
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(suffix,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11, color: kTextDim)),
                ),
              ],
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasAudio)
                    row('音量', clip.volume, 2,
                        '${(clip.volume * 100).round()}%', (v) {
                      clip.volume = v;
                      _ctrls[clip.id]?.setVolume(v.clamp(0.0, 1.0));
                    }),
                  row('淡入', clip.fadeIn, 3,
                      '${clip.fadeIn.toStringAsFixed(1)}s',
                      (v) => clip.fadeIn = v),
                  row('淡出', clip.fadeOut, 3,
                      '${clip.fadeOut.toStringAsFixed(1)}s',
                      (v) => clip.fadeOut = v),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(_saveDraft);
  }

  /// 速度選單：選了片段＝調「那個片段」的速度（時間軸長度跟著縮放、
  /// 匯出同步生效）；沒選片段＝調整條影片的播放速度
  void _openSpeedSheet() {
    final sel = _selClipById(_sel);
    final selSrc = sel == null ? null : _tl.sourceOf(sel);
    // 只有影片/音訊能變速（圖片、文字的長度直接拖把手就好）
    final clipMode = sel != null &&
        selSrc != null &&
        (selSrc.isVideo || selSrc.kind == ClipKind.audio);
    var pushed = false; // 這次選單只拍一次快照
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed, size: 18, color: kAmber),
                    const SizedBox(width: 8),
                    Text(
                      clipMode ? '片段速度' : '整體速度',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Text(
                      clipMode
                          ? '這段 ${sel.length.toStringAsFixed(1)}s'
                          : _fmt(_tl.duration / _speed),
                      style: const TextStyle(
                        color: kTextDim,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final sp in kSpeedOptions)
                      ChoiceChip(
                        label: Text('${sp}x'),
                        selected: clipMode
                            ? sel.speed == sp
                            : _speed == sp,
                        onSelected: (s) {
                          if (!s) return;
                          if (clipMode) {
                            if (!pushed) {
                              _pushUndo();
                              pushed = true;
                            }
                            setState(() => sel.speed = sp);
                            _ctrls[sel.id]
                                ?.setPlaybackSpeed(_speed * sp);
                          } else {
                            setState(() => _speed = sp);
                            for (final e in _tl.clips) {
                              _ctrls[e.id]
                                  ?.setPlaybackSpeed(sp * e.speed);
                            }
                          }
                          setSheet(() {});
                        },
                      ),
                  ],
                ),
                if (clipMode) ...[
                  const SizedBox(height: 8),
                  const Text('時間軸上的長度會跟著速度縮放',
                      style:
                          TextStyle(fontSize: 10.5, color: kTextDim)),
                ],
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(_saveDraft);
  }

  /// 匯出頁（使用者選定 B 款極簡設定列）：
  /// 三行資訊列（比例／解析度／預估大小）＋匯出鈕，選項點了開抽屜
  Widget _buildExportTab() {
    final (outW, outH) =
        computeCanvasSize(_tl, _resolution, _canvasRatio);
    final dur = _tl.duration / _speed;
    final mb = (outW * outH * 30 * 0.09 / 8 * dur + 40000 * dur) /
        (1024 * 1024) *
        _quality.sizeFactor;

    Widget row(String label, String value, VoidCallback? onTap,
        {bool divider = true}) {
      return InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
          decoration: divider
              ? const BoxDecoration(
                  border: Border(bottom: BorderSide(color: kBorder)))
              : null,
          child: Row(
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: kText)),
              const Spacer(),
              Text(value,
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: kTextDim,
                      fontFeatures: [FontFeature.tabularFigures()])),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right,
                    size: 17, color: kTextDim),
              ],
            ],
          ),
        ),
      );
    }

    String fmtDur(double sec) =>
        '${sec ~/ 60}:${(sec % 60).round().toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        row('畫面比例', _canvasRatio.label, _openRatioSheet),
        row(
            '解析度',
            _resolution == ExportResolution.original
                ? '$outW×$outH'
                : '${_resolution.label}・$outW×$outH',
            _openResolutionSheet),
        row('畫質', _quality.label, _openQualitySheet),
        row('預估大小',
            '${fmtDur(dur)}・約 ${mb.toStringAsFixed(0)} MB', null,
            divider: false),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.ios_share, size: 20),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('匯出', style: TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }

  /// 畫質：置中彈窗（同款直列，副標說明檔案大小差異）
  void _openQualitySheet() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('畫質'),
        contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
        content: SizedBox(
          width: 270,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, q) in ExportQuality.values.indexed)
                _optionRow(
                  title: q.label,
                  subtitle: q.note,
                  selected: _quality == q,
                  first: i == 0,
                  onTap: () {
                    setState(() => _quality = q);
                    _saveDraft();
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 解析度：置中彈窗（跟比例同款直列）
  void _openResolutionSheet() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解析度'),
        contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
        content: SizedBox(
          width: 270,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, r) in ExportResolution.values.indexed)
                Builder(builder: (context) {
                  final (w, h) = computeCanvasSize(_tl, r, _canvasRatio);
                  return _optionRow(
                    title: r.label,
                    subtitle: '$w×$h',
                    selected: _resolution == r,
                    first: i == 0,
                    onTap: () {
                      setState(() => _resolution = r);
                      _saveDraft();
                      Navigator.pop(context);
                    },
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }
}

/// 預覽裡選取圖層的外框：一圈細白框就好（無把手）
class _SelectionFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_SelectionFramePainter oldDelegate) => false;
}
