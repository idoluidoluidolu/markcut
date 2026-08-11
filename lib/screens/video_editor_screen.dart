import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import '../services/audio_picker.dart';
import '../services/export_speed.dart';
import '../services/file_reader.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../services/watermark_renderer.dart';
import '../theme.dart';
import '../widgets/color_grade_panel.dart';
import '../widgets/timeline_editor.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

/// 「加素材」選單的項目（錄旁白不是一種素材類型，所以另立一個 enum）
enum _AddKind { video, image, text, wm, audio, record, mosaic, blankTrack }

const kSpeedOptions = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];

/// 速度滑桿的檔位（帶號）：負的＝倒著放。
/// 左端最快的倒轉 → 往中間變慢 → 過中線轉正 → 右端最快正播
const kSpeedStops = <double>[
  -4,
  -3,
  -2,
  -1.5,
  -1,
  -0.75,
  -0.5,
  -0.25,
  0.25,
  0.5,
  0.75,
  1,
  1.5,
  2,
  3,
  4,
];

/// 草稿存放鍵
const kDraftKey = 'project_draft_v1';

class VideoEditorScreen extends StatefulWidget {
  final String? videoPath;
  final WatermarkSettings? initialWatermark; // 從範本卡片開新專案時帶入
  final Map<String, dynamic>? draft; // 從草稿還原

  const VideoEditorScreen({
    super.key,
    this.videoPath,
    this.initialWatermark,
    this.draft,
  }) : assert(videoPath != null || draft != null);

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
  int _selTrack = -1; // 選取的軌道（點軌道空白處；貼上的目標）
  int _extraBlankTracks = 0; // 手動加的空白軌數（常駐空軌之外）
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

  double get _wmEndEff => (_wmEnd ?? _tl.duration).clamp(0.0, _tl.duration);

  /// 浮水印選到哪個部件（文字或圖片）。縮放只動被選的那個
  WmPart _wmPart = WmPart.none;

  /// 點浮水印軌標籤＝關掉浮水印。預覽和匯出一起關，
  /// 不然「看起來沒有、匯出卻有」更容易做白工
  bool _wmHidden = false;

  bool get _wmVisibleNow =>
      !_wmHidden &&
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
      setState(
        () =>
            _pxPerSec = (_pinchBasePx * d / _pinchBaseDist!).clamp(1.0, 200.0),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _syncScrollToPosition(),
      );
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
      setState(
        () => _pxPerSec = (_pxPerSec * math.exp(-dy * 0.002)).clamp(1.0, 200.0),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _syncScrollToPosition(),
      );
    });
  }

  /// 靜音的軌道（點軌道標籤的喇叭切換）
  final Set<int> _mutedTracks = {};

  // ===== 復原 / 重做 =====
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  String _snapshot() => jsonEncode({
    'clips': [for (final c in _tl.clips) c.toJson()],
    // 來源也要進快照：浮水印／文字素材的樣式（wmStyle/textStyle/name）
    // 存在來源上，漏掉的話那些編輯按復原根本退不回去
    'sources': [for (final s in _tl.sources) s.toJson()],
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
      // 舊快照可能沒有 sources（升級前拍的），那就沿用現況
      if (j['sources'] != null) {
        _tl.sources
          ..clear()
          ..addAll([
            for (final s in (j['sources'] as List))
              MediaSource.fromJson(Map<String, dynamic>.from(s as Map)),
          ]);
      }
      _tl.clips
        ..clear()
        ..addAll([
          for (final c in (j['clips'] as List))
            TimelineClip.fromJson(Map<String, dynamic>.from(c as Map)),
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
          Map<String, dynamic>.from(j['wm'] as Map),
        );
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
    _resyncPlayback(); // 復原改了時間對應，播放要重新對位
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
    ctrl
        .initialize()
        .then((_) {
          if (mounted) setState(() {});
        })
        .catchError((_) {});
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
      'extraTracks': _extraBlankTracks,
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
        MediaSource.fromJson(Map<String, dynamic>.from(sj as Map)),
      );
    }
    for (final cj in (j['clips'] as List? ?? [])) {
      _tl.clips.add(
        TimelineClip.fromJson(Map<String, dynamic>.from(cj as Map)),
      );
    }
    var maxId = -1;
    for (final c in _tl.clips) {
      if (c.id > maxId) maxId = c.id;
    }
    _tl.ensureIdAbove(maxId);
    _speed = ((j['speed'] ?? 1.0) as num).toDouble();
    _canvasRatio = CanvasRatio
        .values[((j['ratio'] ?? 0) as int) % CanvasRatio.values.length];
    _resolution = ExportResolution
        .values[((j['res'] ?? 0) as int) % ExportResolution.values.length];
    _quality = ExportQuality
        .values[((j['quality'] ?? 0) as int) % ExportQuality.values.length];
    if (j['wm'] != null) {
      final wm = WatermarkSettings.fromJson(
        Map<String, dynamic>.from(j['wm'] as Map),
      );
      _settings.text = wm.text;
      _settings.logo = wm.logo;
      _settings.animation = wm.animation;
      _settings.animSpeed = wm.animSpeed;
      _settings.animRange = wm.animRange;
    }
    _wmStart = ((j['wmStart'] ?? 0) as num).toDouble();
    _wmEnd = j['wmEnd'] == null ? null : (j['wmEnd'] as num).toDouble();
    _extraBlankTracks = ((j['extraTracks'] ?? 0) as num).toInt();

    // 重建播放器與縮圖；素材檔案不見了（例如系統清掉 app 快取）就剔除該片段，
    // 免得留下永遠黑畫面的片段、到匯出才爆錯
    final deadSources = <int>{};
    for (var i = 0; i < _tl.sources.length; i++) {
      final s = _tl.sources[i];
      if (s.kind == ClipKind.text ||
          s.kind == ClipKind.wm ||
          s.kind == ClipKind.mosaic) {
        continue; // 這幾種素材沒有檔案
      }
      // Web：blob 連結活不過重新整理，留著只會是永遠黑畫面
      // 又不報錯的片段——剔除並讓下面的提示講清楚
      if (kIsWeb &&
          (s.kind == ClipKind.video || s.kind == ClipKind.audio) &&
          s.path.startsWith('blob:')) {
        deadSources.add(i);
        continue;
      }
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
        engine.makeThumbnails(s.path, s.duration, 10, fastDecode: true).then((
          t,
        ) {
          if (mounted && t.isNotEmpty) setState(() => _thumbs[i] = t);
        });
        _makeScrubCache(i, s.path, s.duration);
      }
    }
    _droppedOnLoad = _tl.clips
        .where((c) => deadSources.contains(c.sourceIndex))
        .length;
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

  /// 馬賽克預覽 shader 程式（載不到就退回霧化，web/舊 GPU 都走得下去）。
  /// 存「程式」不存實例：多塊馬賽克同幀各建各的實例，
  /// 共用實例會讓後設定的參數蓋掉前面的
  ui.FragmentProgram? _mosaicProg;

  Future<void> _loadMosaicShader() async {
    try {
      final prog = await ui.FragmentProgram.fromAsset('shaders/mosaic.frag');
      if (mounted) setState(() => _mosaicProg = prog);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _ticker = createTicker(_onTick);
    _tlScroll.addListener(_onTimelineScroll);
    _loadMosaicShader();
    _loadSnapPref(); // 記住上次磁吸開還關
    if (widget.draft != null) {
      _loadDraft(widget.draft!).then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        if (_droppedOnLoad > 0) {
          showHint(
            context,
            '有 $_droppedOnLoad 段素材已找不到，已從專案中移除',
            duration: const Duration(seconds: 5),
          );
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
    final raw = (_tlScroll.offset / _pxPerSec).clamp(0.0, _tl.duration);
    // 即時吸附：靠近素材頭尾時，播放頭當場黏在那條邊上（底下的
    // 時間軸繼續跟著手指滑），滑遠了自動脫離。
    // 不去改捲動位置——改了會跟手指打架，也就是「慢半拍、
    // 滑過去又被吸回來」的來源
    final edge = _nearestEdge(raw);
    if (edge != _lastHeadDetent) {
      _lastHeadDetent = edge;
      if (edge != null) HapticFeedback.selectionClick();
    }
    final t = (edge ?? raw).clamp(0.0, _tl.duration);
    if ((t - _position).abs() < 0.001) return;
    _position = t; // 位置 UI 由 _posVN 小範圍重繪，不整頁 setState
    _scrubbing = true; // 快取幀模式（下一次 30fps 重繪就生效）
    _scrubEndTimer?.cancel();
    _scrubEndTimer = Timer(const Duration(milliseconds: 220), _tryEndScrub);
    if (_activeScrubCached) {
      // 有快取幀：拖曳中完全不 seek，只約定放手補一發
      _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(
        const Duration(milliseconds: 120),
        () => _scrubSeek(force: true),
      );
    } else {
      _scrubSeek();
    }
  }

  /// 播放頭上一個吸住的卡榫（換卡榫時震一下）
  double? _lastHeadDetent;

  /// 磁吸開關（記住上次的選擇）。關掉之後拖曳、修剪、播放頭
  /// 全部照手指走，不會被拉到別的邊緣，也不震動
  bool _snapOn = true;
  static const _kSnapPrefKey = 'timeline_snap_on';

  Future<void> _loadSnapPref() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_kSnapPrefKey) ?? true;
    if (mounted && v != _snapOn) setState(() => _snapOn = v);
  }

  Future<void> _toggleSnap() async {
    setState(() => _snapOn = !_snapOn);
    showHint(context, _snapOn ? '磁吸已開啟' : '磁吸已關閉');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSnapPrefKey, _snapOn);
  }

  /// 這個時間點附近有沒有素材的頭或尾可以吸（沒有回 null）。
  /// 播放頭吸的是「片段邊緣」，不吸自己也不吸播放頭。
  /// 半徑用 12px：太大會在滑過去的時候一直被抓住
  double? _nearestEdge(double t) {
    if (!_snapOn) return null;
    final snapped = _tl.snapTime(t, -1, _pxPerSec, radiusPx: 12);
    return (snapped - t).abs() > 0.0005 ? snapped : null;
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
      _scrubSettleTimer = Timer(
        const Duration(milliseconds: 120),
        () => _scrubSeek(force: true),
      );
      return;
    }
    _lastScrubSeek = now;
    final seeks = <Future<void>>[];
    for (final clip in _tl.clips) {
      final c = _ctrls[clip.id];
      if (c == null || !c.value.isInitialized) continue;
      if (clip.covers(_position)) {
        seeks.add(
          c.seekTo(
            Duration(
              milliseconds: (clip.sourceTimeAt(_position) * 1000).round(),
            ),
          ),
        );
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
    _tlScroll.jumpTo(
      (_position * _pxPerSec).clamp(0.0, _tlScroll.position.maxScrollExtent),
    );
    _suppressScroll = false;
  }

  // ===== 匯入素材 =====

  Future<void> _importVideoFromPath(
    String path, {
    required int track,
    String? name,
  }) async {
    final c = makeVideoController(path);
    await c.initialize();
    final dur = c.value.duration.inMilliseconds / 1000.0;
    final srcIndex = _tl.sources.length;
    _tl.sources.add(
      MediaSource(
        path: path,
        name: name ?? '影片 ${srcIndex + 1}',
        kind: ClipKind.video,
        w: c.value.size.width.round(),
        h: c.value.size.height.round(),
        duration: dur,
      ),
    );
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

    engine.makeThumbnails(path, dur, 10, fastDecode: true).then((t) {
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
  /// 是因為幀夠密；太疏就只能拿舊幀湊，看起來一段段跳
  static const _scrubFps = 14.0;

  /// 快取幀解析度（長邊）。密度提高後張數變多，
  /// 解析度相對降一階換記憶體與解碼速度——拖曳中肉眼看不出差別。
  /// 540×960 的 RGBA 一張約 2MB，所以窗內張數要控制（見 _ScrubDecoder）
  static const _scrubLongSide = 540;

  /// 同時最多留幾個素材的解碼器。每個解碼器就是一份幾十 MB 的
  /// 已解碼影格，素材一多就會把記憶體吃光、匯出時被系統殺掉
  static const _maxLiveDecoders = 2;

  /// 已解碼的幀（每個素材一份）
  final Map<int, _ScrubDecoder> _scrubDecoders = {};

  /// 解碼器的使用順序（最近用的排最後），超量時淘汰最久沒用的
  final List<int> _decoderLru = [];

  _ScrubDecoder _decoderFor(int srcIndex, List<Uint8List?> frames) {
    _decoderLru
      ..remove(srcIndex)
      ..add(srcIndex);
    // 超量就把最久沒碰的整個放掉
    while (_decoderLru.length > _maxLiveDecoders) {
      final old = _decoderLru.removeAt(0);
      _scrubDecoders.remove(old)?.dispose();
    }
    final existing = _scrubDecoders[srcIndex];
    if (existing != null && identical(existing.frames, frames)) {
      return existing;
    }
    existing?.dispose();
    return _scrubDecoders[srcIndex] = _ScrubDecoder(
      frames,
      // 停在原地時晚一步解好的圖也要補畫上去
      onReady: () {
        if (mounted && _scrubbing) _frameVN.value = _posVN.value;
      },
    );
  }

  bool _scrubbing = false;
  Timer? _scrubEndTimer;

  /// 正在跑的抽幀 FFmpeg 段數（匯出前要等它歸零，
  /// 不然兩個 FFmpeg 同時跑會吃爆記憶體、進度統計也會打架）
  int _scrubExtracting = 0;

  Future<void> _makeScrubCache(int srcIndex, String path, double dur) async {
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
      // 匯出中一定要停：抽幀的 FFmpeg 跟匯出的 FFmpeg 同時跑，
      // 記憶體疊加會把整個 App 弄死（OOM 直接閃退）
      while (mounted && (_playing || _scrubbing || _exporting)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (!mounted || !identical(_scrubFrames[srcIndex], slots)) return;
      final count = math.min(segFrames, n - s);
      _scrubExtracting++;
      List<Uint8List> t;
      try {
        t = await engine.makeThumbnails(
          path,
          count * step,
          count,
          height: _scrubLongSide,
          longSide: true,
          startAt: s * step,
        );
      } finally {
        _scrubExtracting--;
      }
      // 畫面關了或素材被換掉就停
      if (!mounted || !identical(_scrubFrames[srcIndex], slots)) return;
      for (var i = 0; i < t.length && s + i < n; i++) {
        slots[s + i] = t[i];
      }
      // 段落之間喘口氣，把 CPU 讓給 UI
      await Future<void>.delayed(const Duration(milliseconds: 120));
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
      final fi =
          (c.sourceTimeAt(_position) /
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
      _scrubEndTimer = Timer(const Duration(milliseconds: 80), _tryEndScrub);
      return;
    }
    // 放手：拖曳中播放頭黏在剪接點上時，捲動位置會跟播放頭差一點點
    //（最多十來個像素），這裡把時間軸補回來對齊，畫面才不會歪著。
    // 播放頭本身不動，所以不會有「被吸回來」的感覺
    _lastHeadDetent = null;
    if (_tlScroll.hasClients && _pxPerSec > 0) {
      final want = (_position * _pxPerSec).clamp(
        0.0,
        _tlScroll.position.maxScrollExtent,
      );
      if ((want - _tlScroll.offset).abs() > 0.5) {
        _suppressScroll = true;
        _tlScroll
            .animateTo(
              want,
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
            )
            .whenComplete(() {
              _suppressScroll = false;
              _scrubSeek(force: true);
            });
      }
    }
    if (_scrubbing && mounted) setState(() => _scrubbing = false);
  }

  Future<void> _pickVideo(int track) async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    if (!mounted) return;
    _pause();
    _pushUndo();
    await _importVideoFromPath(picked.path, track: track, name: picked.name);
    if (mounted) setState(() {});
    _saveDraft(); // 加完立刻落草稿
  }

  Future<void> _pickAudio(int track) async {
    // 音樂來源：音樂檔，或從自己的影片提取聲音（只取音軌）
    final fromVideo = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.library_music_outlined, color: kAmber),
              title: const Text('音樂檔案'),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.movie_outlined, color: kAmber),
              title: const Text('從影片提取聲音'),
              subtitle: const Text(
                '只取影片的音軌，不會加入畫面',
                style: TextStyle(fontSize: 11.5, color: kTextDim),
              ),
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (fromVideo == null || !mounted) return;

    String url;
    String name;
    if (fromVideo) {
      final v = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (v == null) return;
      url = v.path;
      name = v.name;
    } else {
      ({String url, String name})? picked;
      try {
        picked = await pickAudioFile();
      } catch (e) {
        if (mounted) showHint(context, '無法開啟檔案選擇器：$e', error: true);
        return;
      }
      if (picked == null) return;
      url = picked.url;
      name = picked.name;
    }
    if (!mounted) return; // 挑檔期間畫面可能已被收掉
    _pause();
    final c = makeVideoController(url);
    try {
      await c.initialize();
    } catch (_) {
      c.dispose();
      if (mounted) {
        showHint(context, '這個檔案無法播放，換一個試試', error: true);
      }
      return;
    }
    final dur = c.value.duration.inMilliseconds / 1000.0;
    if (dur <= 0) {
      c.dispose();
      if (mounted) {
        showHint(context, '讀不到這個檔案的長度，換一個試試', error: true);
      }
      return;
    }
    _pushUndo();
    final srcIndex = _tl.sources.length;
    _tl.sources.add(
      // 影片來源也一樣掛成 audio 種類：預覽和匯出都只用它的音軌，
      // 畫面完全不進時間軸
      MediaSource(path: url, name: name, kind: ClipKind.audio, duration: dur),
    );
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
    _saveDraft(); // 加完立刻落草稿，被系統殺掉也不會掉
  }

  // ===== 旁白：邊看影片邊錄 =====
  // 選了「錄旁白」＝準備一條旁白軌，軌道標籤變成紅色錄音鈕；
  // 按下去＝影片從播放頭開始播、同時錄音；再按一次停止並落成片段。
  final _recorder = AudioRecorder();
  int? _voTrack; // 預備好的旁白軌
  bool _voRecording = false;
  double _voStartPos = 0; // 開始錄的時間軸位置
  String? _voPath;
  DateTime? _voStartAt;

  /// 錄音中的即時音量取樣（0~1），時間軸上畫成紅色波形
  final _voLevels = ValueNotifier<List<double>>(const []);
  StreamSubscription<Amplitude>? _voAmpSub;

  /// 選單選了「錄旁白」：先把軌道準備好，紅鈕按下去才要權限
  ///（瀏覽器要求麥克風權限必須在使用者操作的當下請求）
  Future<void> _recordVoice(int track) async {
    _pause();
    setState(() => _voTrack = track);
    showHint(context, '按軌道左邊的紅色按鈕，就會一邊播影片一邊錄');
  }

  /// 紅鈕：開始／停止錄旁白
  Future<void> _toggleVoiceRecord() async {
    if (_voRecording) {
      await _finishVoiceRecord();
      return;
    }
    final track = _voTrack;
    if (track == null) return;
    try {
      // 權限在這裡要（使用者剛按下按鈕，瀏覽器才准跳詢問）
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          showHint(context, '需要麥克風權限才能錄旁白', error: true);
        }
        return;
      }
      // Web 不能寫檔案路徑，交給套件自己處理
      final path = kIsWeb
          ? ''
          : '${(await getTemporaryDirectory()).path}'
                '${Platform.pathSeparator}voice_'
                '${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
        path: path,
      );
      _voPath = path;
      _voStartPos = _position;
      _voStartAt = DateTime.now();
      // 即時波形：訂閱麥克風音量，一路累積成峰值陣列
      _voLevels.value = const [];
      _voAmpSub?.cancel();
      _voAmpSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 60))
          .listen((amp) {
            // dBFS（-160~0）轉 0~1；-50dB 以下當作靜音。
            // 開根號是音量表的慣例，小聲講話才看得出起伏
            final db = amp.current.isFinite ? amp.current : -50.0;
            final v = math.sqrt(((db + 50) / 50).clamp(0.0, 1.0));
            // 一定要換成新的 List，CustomPainter 才知道要重畫
            _voLevels.value = [..._voLevels.value, v];
          });
      setState(() => _voRecording = true);
      _play(); // 影片跟著跑，才能對著畫面講
    } catch (e) {
      if (mounted) showHint(context, '無法開始錄音：$e', error: true);
    }
  }

  /// 停止錄音，把錄好的旁白落成片段
  Future<void> _finishVoiceRecord() async {
    if (!_voRecording) return;
    _pause();
    await _voAmpSub?.cancel();
    _voAmpSub = null;
    setState(() => _voRecording = false);
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    path ??= _voPath;
    final elapsed = _voStartAt == null
        ? 0.0
        : DateTime.now().difference(_voStartAt!).inMilliseconds / 1000.0;
    if (path == null || elapsed < 0.3) {
      if (mounted) showHint(context, '錄得太短了，再試一次', error: true);
      return;
    }
    final c = makeVideoController(path);
    try {
      await c.initialize();
    } catch (_) {
      c.dispose();
      if (mounted) showHint(context, '錄音檔讀不到，再錄一次', error: true);
      return;
    }
    final reported = c.value.duration.inMilliseconds / 1000.0;
    final dur = reported > 0.05 ? reported : elapsed;
    _pushUndo();
    final srcIndex = _tl.sources.length;
    _tl.sources.add(
      MediaSource(path: path, name: '旁白', kind: ClipKind.audio, duration: dur),
    );
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: dur,
      offset: _voStartPos, // 對齊開始錄的位置
      track: _voTrack ?? _tl.usedTracks,
    );
    _ctrls[clip.id] = c;
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
      _voTrack = null; // 錄完收起紅鈕
    });
    // 錄音波形交棒給真正的音檔波形
    _voLevels.value = const [];
    _saveDraft();
    if (mounted) showHint(context, '旁白已加入時間軸');
  }

  /// 素材選單（影片／圖片／文字／音樂／錄旁白）
  Future<_AddKind?> _askKind({String? title}) {
    return showModalBottomSheet<_AddKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else
              const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: kAmber),
              title: const Text('影片'),
              onTap: () => Navigator.pop(context, _AddKind.video),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: kAmber),
              title: const Text('圖片'),
              onTap: () => Navigator.pop(context, _AddKind.image),
            ),
            ListTile(
              leading: const Icon(Icons.title, color: kAmber),
              title: const Text('文字'),
              onTap: () => Navigator.pop(context, _AddKind.text),
            ),
            ListTile(
              leading: const Icon(Icons.branding_watermark, color: kAmber),
              title: const Text('浮水印'),
              onTap: () => Navigator.pop(context, _AddKind.wm),
            ),
            ListTile(
              leading: const Icon(Icons.music_note, color: kAmber),
              title: const Text('音樂'),
              onTap: () => Navigator.pop(context, _AddKind.audio),
            ),
            ListTile(
              leading: const Icon(Icons.mic, color: kAmber),
              title: const Text('錄旁白'),
              onTap: () => Navigator.pop(context, _AddKind.record),
            ),
            ListTile(
              leading: const Icon(Icons.blur_on, color: kAmber),
              title: const Text('馬賽克'),
              onTap: () => Navigator.pop(context, _AddKind.mosaic),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add, color: kAmber),
              title: const Text('空白軌道'),
              onTap: () => Navigator.pop(context, _AddKind.blankTrack),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _dispatchAdd(_AddKind? kind, int track) async {
    switch (kind) {
      case _AddKind.video:
        await _pickVideo(track);
      case _AddKind.image:
        await _pickImage(track);
      case _AddKind.text:
        await _addTextClip(track);
      case _AddKind.wm:
        _addWmClip(track);
      case _AddKind.audio:
        await _pickAudio(track);
      case _AddKind.record:
        await _recordVoice(track);
      case _AddKind.mosaic:
        _addMosaicClip(track);
      case _AddKind.blankTrack:
        // 多畫一條空軌，之後可以貼上或拖片段進去
        setState(() {
          _extraBlankTracks++;
          _selTrack = _tl.usedTracks + _extraBlankTracks - 1;
        });
      case null:
        break;
    }
  }

  /// 工具列的「＋」
  Future<void> _addMediaChoice() async {
    final kind = await _askKind();
    // 影片接在目前軌道後面；圖片/文字/音樂/旁白放到新的一層
    await _dispatchAdd(
      kind,
      kind == _AddKind.video ? (_selClip?.track ?? 0) : _tl.usedTracks,
    );
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
    _tl.sources.add(
      MediaSource(
        path: picked.path,
        name: picked.name,
        kind: ClipKind.image,
        duration: 3600, // 靜態素材，長度隨便拉
        w: imgW,
        h: imgH,
      ),
    );
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
    _saveDraft(); // 加完立刻落草稿
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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(initial.isEmpty ? '加入' : '儲存'),
          ),
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
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: kTextDim),
              ),
              const Spacer(),
              Transform.scale(
                scale: 0.72,
                alignment: Alignment.centerRight,
                child: Switch(value: v, onChanged: (x) => both(() => on(x))),
              ),
            ],
          );

          Widget slider(
            String label,
            double v,
            double min,
            double max,
            ValueChanged<double> on,
          ) => SizedBox(
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ),
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
            Color initial,
            void Function(int argb) apply,
          ) async {
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
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('確定'),
                  ),
                ],
              ),
            );
            if (ok == true) both(() => apply(color.toARGB32()));
          }

          // 開關打開後的縮排細項：顏色小圓點列
          Widget colorRow(String label, Color c, void Function(int) apply) =>
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(fontSize: 12, color: kTextDim),
                      ),
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
                            border: Border.all(color: kBorder, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
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
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: kBorder),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: st.fontFamily,
                                icon: const Icon(
                                  Icons.expand_more,
                                  size: 16,
                                  color: kTextDim,
                                ),
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
                                      child: Text(
                                        f.label,
                                        style: TextStyle(
                                          fontFamily: f.family,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                ],
                                onChanged: (v) => both(
                                  () => st.fontFamily = v ?? 'NotoSansTC',
                                ),
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
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('確定'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              both(() => st.colorValue = color.toARGB32());
                            }
                          },
                          borderRadius: BorderRadius.circular(6),
                          // 跟浮水印面板同款：框＋「顏色」字樣，
                          // 裸圓點看起來不像可以點
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: kBorder),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: st.color,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: kBorder,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  '顏色',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: kTextDim,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    slider(
                      '大小',
                      st.sizeFrac,
                      0.02,
                      2.0,
                      (v) => st.sizeFrac = v,
                    ),
                    slider('透明', st.opacity, 0.05, 1, (v) => st.opacity = v),
                    slider('間距', st.spacing, 0, 0.6, (v) => st.spacing = v),
                    // 旋轉：±4° 內吸附回正，點角度數字一鍵歸零
                    SizedBox(
                      height: 34,
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 56,
                            child: Text(
                              '旋轉',
                              style: TextStyle(fontSize: 12, color: kTextDim),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: st.rotation.clamp(-180, 180),
                              min: -180,
                              max: 180,
                              onChanged: (v) =>
                                  both(() => st.rotation = v.abs() < 4 ? 0 : v),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => both(() => st.rotation = 0),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Text(
                                '${st.rotation.round()}°',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: st.rotation.round() == 0
                                      ? kTextDim
                                      : kText,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    toggle('陰影', st.shadow, (v) => st.shadow = v),
                    toggle('描邊', st.outline, (v) => st.outline = v),
                    if (st.outline) ...[
                      colorRow(
                        '顏色',
                        st.outlineColor,
                        (v) => st.outlineColorValue = v,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider(
                          '粗細',
                          st.outlineWidth,
                          0.02,
                          0.2,
                          (v) => st.outlineWidth = v,
                        ),
                      ),
                    ],
                    toggle('底色', st.bg, (v) => st.bg = v),
                    if (st.bg) ...[
                      colorRow('顏色', st.bgColor, (v) => st.bgColorValue = v),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider(
                          '透明度',
                          st.bgOpacity,
                          0.05,
                          1,
                          (v) => st.bgOpacity = v,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider(
                          '大小',
                          st.bgPad,
                          0.3,
                          2.5,
                          (v) => st.bgPad = v,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: slider(
                          '圓角',
                          st.bgCorner,
                          0,
                          1,
                          (v) => st.bgCorner = v,
                        ),
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
    _tl.sources.add(
      MediaSource(
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
      ),
    );
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
    _saveDraft(); // 加完立刻落草稿
  }

  /// 馬賽克素材：畫面上一塊方形區域打碼。
  /// 位置/大小直接在預覽上拖曳、雙指縮放；時間範圍在時間軸上拉
  void _addMosaicClip(int track) {
    _pause();
    _pushUndo();
    final srcIndex = _tl.sources.length;
    _tl.sources.add(
      MediaSource(
        path: '',
        name: '馬賽克',
        kind: ClipKind.mosaic,
        duration: 3600,
        mosaicStyle: MosaicStyle(),
      ),
    );
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: 3,
      offset: _position,
      track: track,
      scale: 0.35, // 預設一塊不大不小的方形
    );
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
      _wmSel = false;
    });
    _saveDraft();
    showHint(context, '拖曳調位置、雙指縮放；再點一下可調樣式與濃度');
  }

  /// 馬賽克樣式表：樣式（像素化/模糊/純色遮蓋）＋濃度/顏色
  void _editMosaicClip(TimelineClip clip) {
    final src = _tl.sourceOf(clip);
    if (src.kind != ClipKind.mosaic) return;
    src.mosaicStyle ??= MosaicStyle();
    final st = src.mosaicStyle!;
    var pushed = false;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void change(VoidCallback f) {
            if (!pushed) {
              _pushUndo();
              pushed = true;
            }
            setState(f);
            setSheet(() {});
          }

          Widget chip(String label, int type) {
            final on = st.type == type;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => change(() => st.type = type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on
                          ? kSelect.withValues(alpha: 0.18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: on ? kSelect : kClipBorder,
                        width: on ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                        color: on ? kSelect : kText,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.blur_on, size: 18, color: kAmber),
                      SizedBox(width: 8),
                      Text(
                        '馬賽克樣式',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [chip('像素化', 0), chip('模糊', 1), chip('純色遮蓋', 2)],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const SizedBox(
                        width: 40,
                        child: Text(
                          '大小',
                          style: TextStyle(fontSize: 12, color: kTextDim),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: clip.scale.clamp(0.05, 3.0),
                          min: 0.05,
                          max: 3.0,
                          onChanged: (v) => change(() => clip.scale = v),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(clip.scale * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: kTextDim,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (st.type != 2) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const SizedBox(
                          width: 40,
                          child: Text(
                            '濃度',
                            style: TextStyle(fontSize: 12, color: kTextDim),
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: st.strength,
                            onChanged: (v) => change(() => st.strength = v),
                          ),
                        ),
                        SizedBox(
                          width: 40,
                          child: Text(
                            '${(st.strength * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: kTextDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (st.type == 1)
                      Row(
                        children: [
                          const SizedBox(
                            width: 40,
                            child: Text(
                              '柔邊',
                              style: TextStyle(
                                fontSize: 12,
                                color: kTextDim,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: st.feather,
                              onChanged: (v) =>
                                  change(() => st.feather = v),
                            ),
                          ),
                          SizedBox(
                            width: 40,
                            child: Text(
                              '${(st.feather * 100).round()}%',
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: kTextDim,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ] else ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 32,
                      child: Row(
                        children: [
                          const Text(
                            '顏色',
                            style: TextStyle(fontSize: 12, color: kTextDim),
                          ),
                          const Spacer(),
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              var color = Color(st.color);
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
                                      child: const Text('取消'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('確定'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                change(() => st.color = color.toARGB32());
                              }
                            },
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: Color(st.color),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: kBorder,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(_saveDraft);
  }

  /// 浮水印素材：一個完整的浮水印（文字＋Logo）當成時間軸元素。
  /// 跟最上面那條全域浮水印軌不同——這種可以放很多個、放不同軌、
  /// 切割、移動，跟一般素材完全一樣
  void _addWmClip(int track) {
    _pause();
    _pushUndo();
    // 起手用目前浮水印的設定當底（沒設定就給一個預設文字），
    // 點兩下隨時可以改
    final style = _settings.hasAnyMark
        ? _settings.copy()
        : (WatermarkSettings()
            ..text = TextMark(
              text: '@浮水印',
              sizeFrac: 0.08,
              colorValue: 0xFFFFFFFF,
              opacity: 0.8,
              shadow: true,
            ));
    final srcIndex = _tl.sources.length;
    _tl.sources.add(
      MediaSource(
        path: '',
        name: style.text.enabled && style.text.text.trim().isNotEmpty
            ? style.text.text
            : '浮水印',
        kind: ClipKind.wm,
        duration: 3600,
        wmStyle: style,
      ),
    );
    // 預設從播放頭鋪到影片結尾（浮水印通常要蓋整段）。
    // 播放頭貼著結尾時不硬撐 3 秒——那會讓匯出多一段
    // 只有浮水印的黑畫面；至少留 1 秒讓片段抓得到就好
    final remain = _tl.duration - _position;
    final len = remain >= 1.0
        ? remain.clamp(1.0, 3600.0)
        : 1.0; // 空專案或貼著結尾：給最短 1 秒
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: len,
      offset: _position,
      track: track,
    );
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
    });
    _saveDraft();
  }

  /// 編輯浮水印片段＝選取它並切到浮水印分頁（跟全域浮水印同一套，
  /// 不開抽屜）
  Future<void> _editWmClip(TimelineClip clip) async {
    final src = _tl.sourceOf(clip);
    if (src.kind != ClipKind.wm) return;
    src.wmStyle ??= WatermarkSettings();
    setState(() {
      _sel = clip.id;
      _wmSel = false;
    });
    _tabs.animateTo(1);
  }

  /// 複製浮水印：把浮水印「文字」複製成獨立的時間軸文字素材——
  /// 等於第二個浮水印，可以有自己的時間範圍、位置、大小
  void _duplicateWatermark() {
    if (!_settings.hasAnyMark) {
      showHint(context, '浮水印還是空的，沒東西可以複製', error: true);
      return;
    }
    _pause();
    _pushUndo();
    // 整組複製（文字＋Logo 都帶著）成獨立的浮水印素材，
    // 有自己的時間範圍、位置、大小，跟原本的互不影響
    final srcIndex = _tl.sources.length;
    _tl.sources.add(
      MediaSource(
        path: '',
        name: _settings.text.enabled && _settings.text.text.trim().isNotEmpty
            ? _settings.text.text
            : '浮水印',
        kind: ClipKind.wm,
        duration: 3600,
        wmStyle: _settings.copy(),
      ),
    );
    final start = _wmStart;
    final len = (_wmEndEff - start).clamp(0.5, 3600.0);
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIndex,
      trimStart: 0,
      trimEnd: len,
      offset: start,
      track: _tl.firstFreeTrack(), // 放到新的一層，不壓到現有素材
    );
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
      _wmSel = false;
    });
    showHint(context, '已複製整組浮水印（文字＋圖片），時間和位置都可獨立調整');
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

  /// 時間軸的「時間→內容」對應被改動（移動/修剪/變速/刪除/復原）後
  /// 一定要呼叫：清掉進場狀態，下次播放每個片段重新對位。
  /// 不清的話進場 seek 被跳過，1 秒內的錯位永遠不會被修正
  void _resyncPlayback() {
    _wasActive.clear();
    _lastDriftFix.clear();
  }

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
    // 無縫接續：切割出來的兩段（同來源、內容連續、同速度）在交界時
    // 直接把前段「正在播」的播放器交給後段——暫停＋seek＋重新起播
    // 就是播放跨過切點會卡一下的原因
    if (_playing) {
      for (final clip in _tl.clips) {
        if (!clip.covers(_position) || _wasActive.contains(clip.id)) continue;
        for (final prev in _tl.clips) {
          if (identical(prev, clip) ||
              prev.sourceIndex != clip.sourceIndex ||
              prev.track != clip.track ||
              prev.covers(_position) ||
              !_wasActive.contains(prev.id)) {
            continue;
          }
          if ((prev.end - clip.offset).abs() > 0.05 ||
              (prev.trimEnd - clip.trimStart).abs() > 0.05 ||
              (prev.speed - clip.speed).abs() > 0.001) {
            continue;
          }
          final cOld = _ctrls[prev.id];
          if (cOld == null || !cOld.value.isInitialized) break;
          // 保險絲：舊播放器必須真的停在交界附近才換手，
          // 不然任何狀態殘留都會把錯位置的播放器塞給新片段
          final oldPos = cOld.value.position.inMilliseconds / 1000.0;
          if ((oldPos - clip.trimStart).abs() > 1.0) continue;
          // 換手：後段接走正在播的，前段拿到後段那顆（離場會被暫停）
          final cNew = _ctrls[clip.id];
          _ctrls[clip.id] = cOld;
          if (cNew != null) {
            _ctrls[prev.id] = cNew;
          } else {
            _ctrls.remove(prev.id);
          }
          _lastVol[clip.id] = _lastVol.remove(prev.id) ?? -1;
          _wasActive
            ..add(clip.id) // 視為已進場：跳過 seek，讓它繼續跑
            ..remove(prev.id);
          break;
        }
      }
    }
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
        // 門檻隨播放速度放大：Android 位置回報有 ~500ms 延遲，
        // 2 倍速以上光是延遲就會超過 1 秒，會被誤判成脫節狂 seek
        final driftThr = math.max(1.0, _speed * clip.speed);
        if ((actual - want).abs() > driftThr &&
            now
                    .difference(
                      _lastDriftFix[clip.id] ??
                          DateTime.fromMillisecondsSinceEpoch(0),
                    )
                    .inMilliseconds >
                2000) {
          _lastDriftFix[clip.id] = now;
          c.seekTo(Duration(milliseconds: (want * 1000).round()));
        }
      }
      // 音量最多 10 次/秒（fade 中每格打 method channel 也會卡）
      if (volDue) {
        final trackMute = _mutedTracks.contains(clip.track) ? 0.0 : 1.0;
        // 倒轉的片段預覽時靜音：播放器只會正著播，聲音是反的內容，
        // 放出來只會干擾（匯出時會用 areverse 正確倒過來）
        final revMute = clip.reverse ? 0.0 : 1.0;
        final vol =
            (clip.volume * trackMute * revMute * clip.fadeFactorAt(_position))
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
    // 跟捲動時間軸同一套：靠近素材頭尾就當場吸住，換卡榫震一下
    final edge = _nearestEdge(_position);
    if (edge != _lastHeadDetent) {
      _lastHeadDetent = edge;
      if (edge != null) HapticFeedback.selectionClick();
    }
    if (edge != null) _position = edge.clamp(0.0, _tl.duration);
    _scrubbing = true;
    _scrubEndTimer?.cancel();
    _scrubEndTimer = Timer(const Duration(milliseconds: 220), _tryEndScrub);
    if (_activeScrubCached) {
      _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(
        const Duration(milliseconds: 120),
        () => _scrubSeek(force: true),
      );
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
      // 插入/收斂會重編軌號，選取的軌道指不準了——直接清掉
      if (insert) _selTrack = -1;
    });
    _resyncPlayback();
  }

  /// 上一刻修剪把手有沒有吸住（吸住的瞬間震一下，才有磁鐵的感覺）
  bool _trimSnapped = false;

  void _trimClip(int id, double dSec, bool fromLeft) {
    if (_tlPinching) return; // 雙指縮放中不修剪
    setState(() {
      for (final c in _tl.clips) {
        if (c.id != id) continue;
        final src = _tl.sourceOf(c);
        // 磁吸：先算這條邊被拖到哪，吸附到鄰近片段邊緣／播放頭／0
        // 之後，再換算回實際的位移量——接片段才能剛好無縫貼齊
        final edge = fromLeft ? c.offset + dSec : c.end + dSec;
        final snapped = _snapOn
            ? _tl.snapEdge(c, edge, _position, _pxPerSec)
            : edge;
        // 剛吸上去的那一下震動回饋
        final on = (snapped - edge).abs() > 0.0005;
        if (on != _trimSnapped) {
          _trimSnapped = on;
          if (on) HapticFeedback.selectionClick();
        }
        dSec = fromLeft ? snapped - c.offset : snapped - c.end;
        // 把手拖的是「時間軸秒」，變速片段要換算回素材秒
        final dSrc = dSec * c.speed;
        if (fromLeft) {
          final ns = (c.trimStart + dSrc).clamp(0.0, c.trimEnd - 0.3);
          // offset 位移用時間軸秒（素材差 ÷ 速度）
          c.offset = (c.offset + (ns - c.trimStart) / c.speed).clamp(0.0, 1e6);
          c.trimStart = ns;
        } else {
          c.trimEnd = (c.trimEnd + dSrc).clamp(c.trimStart + 0.3, src.duration);
        }
      }
    });
    _resyncPlayback();
  }

  /// 一鍵補洞：把空隙收掉、片段接齊。
  /// 有選片段就只整理那一軌，沒選就整條時間軸一起整理
  void _closeGaps() {
    final t = _selClip?.track ?? (_selTrack >= 0 ? _selTrack : null);
    if (_tl.clips.isEmpty) {
      showHint(context, '時間軸還是空的');
      return;
    }
    _pushUndo();
    double removed = 0;
    setState(() => removed = _tl.closeGaps(track: t));
    _resyncPlayback();
    _saveDraft();
    if (removed < 0.05) {
      showHint(context, t == null ? '沒有空隙可以補' : '第 ${t + 1} 軌沒有空隙');
      return;
    }
    showHint(
      context,
      t == null
          ? '已補起空隙，總共收掉 ${removed.toStringAsFixed(1)} 秒'
          : '已整理第 ${t + 1} 軌，收掉 ${removed.toStringAsFixed(1)} 秒',
    );
  }

  /// 刪掉整條軌道（軌上所有片段一起消失）
  Future<void> _deleteTrack(int track) async {
    final n = _tl.onTrack(track).length;
    if (n == 0) {
      showHint(context, '這一軌是空的');
      return;
    }
    final ok = await showConfirm(
      context,
      title: '刪除第 ${track + 1} 軌？',
      message: '這一軌的 $n 個素材會一起刪掉（可以按上一步救回來）',
      action: '刪除整軌',
    );
    if (!ok || !mounted) return;
    _pushUndo();
    setState(() {
      _tl.removeTrack(track);
      _sel = -1;
      _selTrack = -1;
    });
    _resyncPlayback();
    _saveDraft();
    showHint(context, '已刪除第 ${track + 1} 軌');
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
      // 軌號整批換過了，選取的軌道跟著對照表走
      if (_selTrack >= 0) _selTrack = map[_selTrack] ?? -1;
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
    // 舊播放器正好停在切點附近，直接過戶給後半段——
    // 切完當下畫面顯示的就是後半，重開播放器會黑一下（跳一下）。
    // 前半再補一個新的（浮水印／文字／圖片沒有播放器，
    // _ensureCtrlFor 會自己判斷跳過）
    final oldCtrl = _ctrls.remove(c.id);
    if (oldCtrl != null) _ctrls[second.id] = oldCtrl;
    // 「已進場」狀態要跟著播放器走：留著前半的舊狀態的話，
    // 下次播放時無縫換手會反向觸發，把還停在 0 秒的新播放器
    // 塞給正在播的後半段（後半整段播錯內容）
    if (_wasActive.remove(c.id)) _wasActive.add(second.id);
    _lastVol[second.id] = _lastVol.remove(c.id) ?? -1;
    _ensureCtrlFor(c);
    setState(() => _sel = second.id);
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
    _resyncPlayback();
  }

  /// 長按片段 → 複製 / 貼上 / 刪除
  Future<void> _showClipMenu(int id, Offset pos) async {
    final clip = _selClipById(id);
    if (clip == null) return;
    setState(() {
      _sel = id;
      _wmSel = false;
    });
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
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
        if (_tl.sourceOf(clip).kind == ClipKind.wm)
          _menuItem('edit', Icons.edit_outlined, '編輯樣式'),
        if (_tl.sourceOf(clip).kind == ClipKind.mosaic)
          _menuItem('edit', Icons.edit_outlined, '調整馬賽克'),
        _menuItem('copy', Icons.copy, '複製'),
        _menuItem(
          'paste',
          Icons.content_paste,
          '貼上',
          enabled: _clipboard != null,
        ),
        _menuItem('delete', Icons.delete_outline, '刪除'),
      ],
    );
    switch (action) {
      case 'edit':
        final k = _tl.sourceOf(clip).kind;
        if (k == ClipKind.wm) {
          await _editWmClip(clip);
        } else if (k == ClipKind.mosaic) {
          _editMosaicClip(clip);
        } else {
          await _editTextClip(clip);
        }
      case 'copy':
        setState(() => _clipboard = clip.copy());
      case 'paste':
        await _pasteClipboard();
      case 'delete':
        _deleteSelected();
    }
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16, color: enabled ? kIcon : kTextDim),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: enabled ? kText : kTextDim),
          ),
        ],
      ),
    );
  }

  /// 長按空白處 → 在那個位置貼上
  Future<void> _showEmptyMenu(int track, double t, Offset pos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
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
        _menuItem(
          'paste',
          Icons.content_paste,
          '貼上',
          enabled: _clipboard != null,
        ),
        _menuItem('tidy', Icons.compress, '整理這一軌'),
        _menuItem(
          'delTrack',
          Icons.delete_sweep_outlined,
          '刪除整軌',
          enabled: _tl.onTrack(track).isNotEmpty,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'paste':
        await _pasteClipboard(at: t, track: track);
      case 'tidy':
        setState(() => _selTrack = track);
        _closeGaps();
      case 'delTrack':
        await _deleteTrack(track);
    }
  }

  /// 貼上：預設以播放頭為起點、放回原本的軌道；
  /// 從空白處長按貼上時則落在按的位置和那一軌。
  Future<void> _pasteClipboard({double? at, int? track}) async {
    final cb = _clipboard;
    if (cb == null) return;
    _pushUndo();
    // 浮水印／文字／馬賽克素材：樣式在來源上，貼上要有自己的一份，
    // 不然改貼出來那份的樣式，原本那份會跟著變
    var srcIdx = cb.sourceIndex;
    final cbSrc = _tl.sources[srcIdx];
    if (cbSrc.kind == ClipKind.wm ||
        cbSrc.kind == ClipKind.text ||
        cbSrc.kind == ClipKind.mosaic) {
      _tl.sources.add(
        MediaSource(
          path: cbSrc.path,
          name: cbSrc.name,
          kind: cbSrc.kind,
          w: cbSrc.w,
          h: cbSrc.h,
          duration: cbSrc.duration,
          textStyle: cbSrc.textStyle?.copy(),
          wmStyle: cbSrc.wmStyle?.copy(),
          mosaicStyle: cbSrc.mosaicStyle?.copy(),
        ),
      );
      srcIdx = _tl.sources.length - 1;
    }
    final clip = TimelineClip(
      id: _tl.nextId(),
      sourceIndex: srcIdx,
      trimStart: cb.trimStart,
      trimEnd: cb.trimEnd,
      offset: at ?? _position,
      // 沒指定軌道時：選取片段的軌 → 點選中的軌道 → 複製來源的軌
      //（長按時間軸空白處＝貼到指定軌道與位置）
      track:
          (track ??
                  _selClipById(_sel)?.track ??
                  (_selTrack >= 0 ? _selTrack : cb.track))
              .clamp(0, _tl.usedTracks + _extraBlankTracks),
      volume: cb.volume,
      // 這些貼上時原本被丟掉：2 倍速片段貼上會變 1 倍速、
      // 調好位置大小的疊圖會跳回置中原尺寸
      speed: cb.speed,
      px: cb.px,
      py: cb.py,
      scale: cb.scale,
      fadeIn: cb.fadeIn,
      fadeOut: cb.fadeOut,
      color: cb.color.copy(),
    );
    // 播放器交給 _ensureCtrlFor（有種類判斷＋錯誤保護）
    _ensureCtrlFor(clip);
    setState(() {
      _tl.clips.add(clip);
      _sel = clip.id;
    });
    _resyncPlayback();
    _saveDraft(); // 貼上完立刻落草稿，被系統殺掉也不會掉
  }

  @override
  void dispose() {
    _frameSettle?.cancel();
    _scrubSettleTimer?.cancel();
    _scrubEndTimer?.cancel();
    _wheelSaveTimer?.cancel();
    for (final d in _scrubDecoders.values) {
      d.dispose();
    }
    _voAmpSub?.cancel();
    _voLevels.dispose();
    _recorder.dispose();
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
    // 匯出前把所有快取放掉：已解碼的幀（幾十 MB）、壓縮的抽幀
    // （長片可到 ~80MB）、ImageCache。匯出本身就要吃大量記憶體，
    // 疊上這些很容易被系統 OOM 直接殺掉。
    // 清掉 _scrubFrames 也會讓進行中的抽幀迴圈自動收工（identical 檢查）
    for (final d in _scrubDecoders.values) {
      d.dispose();
    }
    _scrubDecoders.clear();
    _decoderLru.clear();
    _scrubFrames.clear();
    // 上限也壓到 0：只清內容的話，匯出期間畫面一重繪又會長回來，
    // 跟 FFmpeg 搶記憶體。匯出結束再還原
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages()
      ..maximumSize = 0
      ..maximumSizeBytes = 0;
    // 播放器也全部放掉：每顆播放器（解碼器＋緩衝）都是幾十 MB，
    // 片段一多加起來比快取還兇——沒調色也會被系統殺掉就是這裡。
    // 匯出完再重建（_ensureCtrlFor 會自動補）
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
    _wasActive.clear();

    setState(() => _exporting = true);

    // 抽幀可能正好在跑一段（約 6 秒）——等它收尾再開匯出，
    // 上限 10 秒，卡住也不至於永遠不動
    for (var i = 0; i < 100 && _scrubExtracting > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;

    final progress = ValueNotifier<double>(0);
    // 剩餘時間用實際進度速率推，比任何靜態公式都準
    final startedAt = DateTime.now();
    var cancelRequested = false;

    String etaText(double v) {
      final gone = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
      // 前 3 秒或進度還沒動，速率不可信，先不要亂報
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
                  Text(
                    etaText(v),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
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

    // 高畫質編碼跑很久，螢幕一關系統就可能凍結或回收 App
    await keepScreenAwake(true);

    String message;
    bool ok = false;
    var cancelled = false;
    try {
      final (outW, outH) = computeCanvasSize(_tl, _resolution, _canvasRatio);
      Uint8List? wmPng;
      // 浮水印軌關掉時匯出也不要有——所見即所得
      if (!_wmHidden && _settings.hasAnyMark) {
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
            st,
            c.px,
            c.py,
            c.scale,
            outW,
            outH,
          );
        } else if (src.kind == ClipKind.wm) {
          overlayPngs[c.id] = await WatermarkRenderer.renderOverlayPng(
            src.wmStyle ?? WatermarkSettings(),
            outW,
            outH,
          );
        }
      }
      final result = await engine.exportVideoToGallery(
        ExportSpec(
          sources: _tl.sources,
          clips: [
            for (final c in _tl.clips)
              c.copy()..volume = _mutedTracks.contains(c.track) ? 0 : c.volume,
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
    // 這次實際跑多久 → 更新這台機器的速度係數，下次預估才準
    if (ok) {
      final (ow, oh) = computeCanvasSize(_tl, _resolution, _canvasRatio);
      await ExportSpeed.record(
        outW: ow,
        outH: oh,
        outSeconds: _tl.duration / _speed,
        elapsed: DateTime.now().difference(startedAt),
      );
    }
    await keepScreenAwake(false);

    if (mounted) {
      Navigator.of(context).pop();
      // 取消是使用者自己的決定，用中性提示就好，不當錯誤
      showHint(
        context,
        message,
        error: !ok && !cancelled,
        duration: Duration(seconds: ok || cancelled ? 3 : 8),
      );
    }
    // 還原圖片快取上限（匯出期間壓成 0）
    PaintingBinding.instance.imageCache
      ..maximumSize = 300
      ..maximumSizeBytes = 96 << 20;
    // 播放器匯出前全放掉了，現在重建
    for (final c in _tl.clips) {
      _ensureCtrlFor(c);
    }
    _resyncPlayback();
    setState(() => _exporting = false);
    // 匯出前把抽幀快取清光了，現在重新抽回來（拖曳預覽要用）
    for (var i = 0; i < _tl.sources.length; i++) {
      final s = _tl.sources[i];
      if (s.isVideo && s.duration > 0) {
        _makeScrubCache(i, s.path, s.duration);
      }
    }
  }

  // ===== 畫面 =====

  /// 離開保護：問清楚要留草稿還是捨棄（C 款直排大按鈕）
  /// 返回：先退回上一個分頁（匯出→浮水印→剪輯），
  /// 已經在剪輯分頁才問要不要離開專案
  void _handleBack() {
    // 調色模式先退出去，不要直接跳掉整個分頁
    if (_colorMode) {
      _exitColorMode();
      return;
    }
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
                const Text(
                  '離開專案？',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '保留草稿之後可以從首頁繼續剪',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: kTextDim,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC',
                    ),
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
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('捨棄', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(height: 2),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    foregroundColor: kTextDim,
                    minimumSize: const Size.fromHeight(40),
                  ),
                  child: const Text('繼續編輯', style: TextStyle(fontSize: 13)),
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
            // 編輯模式「不放」右滑返回：時間軸捲動、拖片段、移浮水印
            // 全是橫向手勢，跟返回判定天生打架。返回走上一頁鍵／返回鍵
            : Column(
                children: [
                  // 軌道多的時候把預覽讓一點空間給時間軸，
                  // 不然四軌以上只剩一條縫可以捲
                  Expanded(
                    flex: _tl.usedTracks >= 3 ? 4 : 5,
                    child: _buildPreview(),
                  ),
                  _buildControlBar(),
                  Expanded(
                    flex: _tl.usedTracks >= 3 ? 6 : 5,
                    child: TabBarView(
                      controller: _tabs,
                      // 左右滑動保留給時間軸，分頁只用底部按鈕切換
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        // 調色模式接管下半部，預覽照常在上面看得到
                        _colorMode ? _buildColorPanel() : _buildTimelineTab(),
                        // 浮水印分頁認選取目標：選中的是浮水印素材
                        // 就編它，否則編全域浮水印。key 綁目標，
                        // 切換目標時面板內部狀態才會重置
                        Builder(
                          builder: (context) {
                            final c = _selClipById(_sel);
                            final src = c == null ? null : _tl.sourceOf(c);
                            final isClipWm =
                                src != null && src.kind == ClipKind.wm;
                            if (isClipWm) src.wmStyle ??= WatermarkSettings();
                            return WatermarkPanel(
                              key: ValueKey(isClipWm ? _sel : -1),
                              settings: isClipWm ? src.wmStyle! : _settings,
                              onChanged: () => setState(() {
                                if (isClipWm) {
                                  // 名字跟著文字走，時間軸上才認得出來
                                  final st = src.wmStyle!;
                                  src.name =
                                      st.text.enabled &&
                                          st.text.text.trim().isNotEmpty
                                      ? st.text.text
                                      : '浮水印';
                                }
                              }),
                              onBeforeChange: _pushWmUndo,
                              syncVersion: _wmSync,
                              showAnimation: true,
                              // 剛加的圖片直接選起來，可以馬上拖／縮放
                              onLogoAdded: () => setState(() {
                                _wmPart = WmPart.logo;
                                if (!isClipWm) _wmSel = true;
                              }),
                            );
                          },
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
                    // 調色模式沒有「完成」鈕：點任何分頁＝離開調色
                    onTap: (_) {
                      if (_colorMode) _exitColorMode();
                    },
                    indicatorColor: Colors.transparent,
                    dividerHeight: 0,
                    labelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      fontFamily: 'NotoSansTC',
                    ),
                    unselectedLabelStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      fontFamily: 'NotoSansTC',
                    ),
                    tabs: const [
                      Tab(
                        icon: Icon(Icons.content_cut, size: 20),
                        text: '剪輯',
                        height: 54,
                        iconMargin: EdgeInsets.only(bottom: 2),
                      ),
                      Tab(
                        icon: Icon(Icons.branding_watermark, size: 20),
                        text: '浮水印',
                        height: 54,
                        iconMargin: EdgeInsets.only(bottom: 2),
                      ),
                      Tab(
                        icon: Icon(Icons.ios_share, size: 20),
                        text: '匯出',
                        height: 54,
                        iconMargin: EdgeInsets.only(bottom: 2),
                      ),
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
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              onPressed: () => _playing ? _pause() : _play(),
            ),
          ),
          // RepaintBoundary：時間碼每格重繪不波及整條播放列
          RepaintBoundary(
            child: ValueListenableBuilder<double>(
              valueListenable: _posVN,
              builder: (context, pos, _) => Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: _fmt(pos),
                      style: const TextStyle(
                        color: kText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: ' / ${_fmt(_tl.duration)}',
                      style: const TextStyle(color: kTextDim),
                    ),
                  ],
                ),
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
      // 電腦版：滾輪縮放選取中的元素
      onPointerSignal: _previewWheel,
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
          child: Stack(
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: canvasAspect,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
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
                          child: LayoutBuilder(
                            builder: (context, box) {
                              final w = box.maxWidth;
                              final h = box.maxHeight;
                              // 位置驅動的圖層（影片/圖片/文字/浮水印）只在這個範圍內
                              // 隨播放頭重繪（節流 30fps），播放時不再整頁 setState
                              return ValueListenableBuilder<double>(
                                valueListenable: _frameVN,
                                builder: (context, pos, _) {
                                  // 依片段的位置/縮放算出圖層的框（跟匯出同一套算法）
                                  Rect layerBox(
                                    TimelineClip c,
                                    double srcAspect,
                                  ) {
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
                                      c.px * w - w2 / 2,
                                      c.py * h - h2 / 2,
                                      w2,
                                      h2,
                                    );
                                  }

                                  final children = <Widget>[];
                                  Rect? selRect;
                                  TimelineClip? selVisual;

                                  // 影片圖層（由下層往上疊 = 真 PiP）
                                  final vids = _tl.videosAt(_position);
                                  for (final c in vids) {
                                    final ctrl = _ctrls[c.id];
                                    if (ctrl == null ||
                                        !ctrl.value.isInitialized) {
                                      // 播放器還沒好（初始化中／掛掉）：
                                      // 有抽好的幀就先畫著，
                                      // 不能讓畫面整片黑
                                      final fs = _scrubFrames[c.sourceIndex];
                                      final src0 = _tl.sourceOf(c);
                                      final rf = layerBox(c, src0.aspect);
                                      Uint8List? fb;
                                      if (fs != null && fs.isNotEmpty) {
                                        final fi =
                                            (c.sourceTimeAt(_position) /
                                                    math.max(
                                                      0.01,
                                                      src0.duration,
                                                    ) *
                                                    fs.length)
                                                .floor()
                                                .clamp(0, fs.length - 1);
                                        fb = _ScrubDecoder.nearestBytes(fs, fi);
                                      }
                                      fb ??=
                                          (_thumbs[c.sourceIndex] ?? const [])
                                              .firstOrNull;
                                      if (fb != null) {
                                        children.add(
                                          Positioned.fromRect(
                                            rect: rf,
                                            child: _tinted(
                                              c,
                                              Opacity(
                                                opacity: c.fadeFactorAt(
                                                  _position,
                                                ),
                                                child: Image.memory(
                                                  fb,
                                                  fit: BoxFit.fill,
                                                  gaplessPlayback: true,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                        if (c.id == _sel) {
                                          selRect = rf;
                                          selVisual = c;
                                        }
                                      }
                                      continue;
                                    }
                                    final r = layerBox(
                                      c,
                                      ctrl.value.aspectRatio,
                                    );
                                    // 拖曳中：真影片上面疊快取幀。獨立小元件直接聽 _posVN
                                    // 全速換圖（不吃 30fps 節流），搭配鄰近幀預熱解碼＝跟手。
                                    //
                                    // Web 的調色模式也走這條：HTML video 元素跟
                                    // Flutter 畫布分開合成，吃不到濾鏡，換成快取幀
                                    // 才看得到即時的顏色。手機是材質（texture），
                                    // 濾鏡本來就吃得到，維持原解析度不降級
                                    final frames =
                                        // 倒轉的片段一律走快取幀：播放器
                                        // 沒辦法倒著播，只能拿抽好的影格
                                        // 反著貼（sourceTimeAt 已經算好
                                        // 從尾巴往回的時間）
                                        (_scrubbing ||
                                            c.reverse ||
                                            (_colorMode && kIsWeb))
                                        ? _scrubFrames[c.sourceIndex]
                                        : null;
                                    children.add(
                                      Positioned.fromRect(
                                        rect: r,
                                        child: _tinted(
                                          c,
                                          Opacity(
                                            opacity: c.fadeFactorAt(_position),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                // key 綁「播放器」不綁片段 id：
                                                // 切割的兩段在交界換手同一顆
                                                // 播放器，key 不變貼圖就不用
                                                // 拆掉重掛，畫面才不會閃一下
                                                ctrl.view(key: ObjectKey(ctrl)),
                                                if (frames != null &&
                                                    frames.isNotEmpty)
                                                  IgnorePointer(
                                                    child: ValueListenableBuilder<double>(
                                                      valueListenable: _posVN,
                                                      builder: (context, pos, _) {
                                                        final src = _tl
                                                            .sourceOf(c);
                                                        final fi =
                                                            (c.sourceTimeAt(
                                                                      pos,
                                                                    ) /
                                                                    math.max(
                                                                      0.01,
                                                                      src.duration,
                                                                    ) *
                                                                    frames
                                                                        .length)
                                                                .floor()
                                                                .clamp(
                                                                  0,
                                                                  frames.length -
                                                                      1,
                                                                );
                                                        final dec = _decoderFor(
                                                          c.sourceIndex,
                                                          frames,
                                                        );
                                                        dec.focus(fi);
                                                        // 已經解好的：直接貼材質，UI 執行緒零解碼
                                                        final img = dec[fi];
                                                        if (img != null) {
                                                          return RawImage(
                                                            image: img,
                                                            fit: BoxFit.fill,
                                                            filterQuality:
                                                                FilterQuality
                                                                    .medium,
                                                          );
                                                        }
                                                        // 還沒解好（剛拖到很遠的位置）先用位元組頂著
                                                        final f = _nearestFrame(
                                                          frames,
                                                          fi,
                                                        );
                                                        if (f == null) {
                                                          return const SizedBox.shrink();
                                                        }
                                                        return Image.memory(
                                                          f,
                                                          fit: BoxFit.fill,
                                                          gaplessPlayback: true,
                                                          filterQuality:
                                                              FilterQuality
                                                                  .medium,
                                                          cacheWidth:
                                                              _scrubLongSide,
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                // 點擊層必須疊在影片「上面」：影片是平台原生元件
                                                // （Web 是 HTML video），會吃掉底下的點擊事件
                                                GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  // 點畫面上的影片＝選取它（等同在時間軸點該片段）
                                                  onTap: () => setState(() {
                                                    _sel = c.id;
                                                    _wmSel = false;
                                                  }),
                                                  child:
                                                      const SizedBox.expand(),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                    if (c.id == _sel) {
                                      selRect = r;
                                      selVisual = c;
                                    }
                                  }

                                  // 圖片 / 文字圖層（永遠疊在影片上面，由下層往上畫）
                                  for (final c in _tl.overlaysAt(_position)) {
                                    final src = _tl.sourceOf(c);
                                    if (src.kind == ClipKind.mosaic) {
                                      final r = layerBox(c, 1.0);
                                      children.add(
                                        Positioned.fromRect(
                                          rect: r,
                                          child: GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () => setState(() {
                                              _sel = c.id;
                                              _wmSel = false;
                                            }),
                                            // 純效果不加字不加框：
                                            // 像素化 = shader 取格中心色
                                            // （真色塊）；不支援 shader 的
                                            // 平台退回霧化。web 播放中抓不
                                            // 到 HTML 影片，效果以匯出為準
                                            child: Builder(
                                              builder: (context) {
                                                final ms =
                                                    src.mosaicStyle ??
                                                    MosaicStyle();
                                                if (ms.type == 2) {
                                                  return Container(
                                                    color: Color(ms.color),
                                                  );
                                                }
                                                if (ms.type == 1 &&
                                                    ms.feather > 0) {
                                                  // 邊緣柔化：同心圈疊加，
                                                  // 中心累積較糊、邊緣輕
                                                  //（跟匯出的漸進圈同思路）
                                                  final sg =
                                                      (4.0 +
                                                          16 * ms.strength) /
                                                      3;
                                                  final ins =
                                                      ms.feather *
                                                      0.175 *
                                                      math.min(
                                                        r.width,
                                                        r.height,
                                                      );
                                                  Widget ring(double i) =>
                                                      Positioned(
                                                        left: i,
                                                        top: i,
                                                        right: i,
                                                        bottom: i,
                                                        child: ClipRect(
                                                          child: BackdropFilter(
                                                            filter:
                                                                ui.ImageFilter.blur(
                                                                  sigmaX: sg,
                                                                  sigmaY: sg,
                                                                ),
                                                            child:
                                                                const SizedBox
                                                                    .expand(),
                                                          ),
                                                        ),
                                                      );
                                                  return Stack(
                                                    children: [
                                                      ring(0),
                                                      ring(ins),
                                                      ring(ins * 2),
                                                    ],
                                                  );
                                                }
                                                ui.ImageFilter? filter;
                                                if (ms.type == 0 &&
                                                    _mosaicProg != null) {
                                                  // 格數跟匯出同一條公式，
                                                  // 濃度越高格子越大
                                                  final cells =
                                                      (26 - 20 * ms.strength)
                                                          .round()
                                                          .clamp(4, 40);
                                                  final dpr = MediaQuery.of(
                                                    context,
                                                  ).devicePixelRatio;
                                                  final cell = math.max(
                                                    2.0,
                                                    r.width * dpr / cells,
                                                  );
                                                  try {
                                                    // 0,1 = u_size(引擎
                                                    // 自動填),2 = u_cell
                                                    final sh = _mosaicProg!
                                                        .fragmentShader();
                                                    sh.setFloat(2, cell);
                                                    filter =
                                                        ui.ImageFilter.shader(
                                                          sh,
                                                        );
                                                  } catch (_) {
                                                    filter = null;
                                                  }
                                                }
                                                final sigma =
                                                    4.0 + 16 * ms.strength;
                                                filter ??= ui.ImageFilter.blur(
                                                  sigmaX: sigma,
                                                  sigmaY: sigma,
                                                );
                                                return ClipRect(
                                                  child: BackdropFilter(
                                                    filter: filter,
                                                    child: const SizedBox
                                                        .expand(),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                      if (c.id == _sel) {
                                        selRect = r;
                                        selVisual = c;
                                      }
                                      continue;
                                    }
                                    if (src.kind == ClipKind.image &&
                                        (_thumbs[c.sourceIndex]?.isNotEmpty ??
                                            false)) {
                                      final r = layerBox(c, src.aspect);
                                      children.add(
                                        Positioned.fromRect(
                                          rect: r,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              _tinted(
                                                c,
                                                Opacity(
                                                  opacity: c.fadeFactorAt(
                                                    _position,
                                                  ),
                                                  child: Image.memory(
                                                    _thumbs[c.sourceIndex]![0],
                                                    fit: BoxFit.fill,
                                                    gaplessPlayback: true,
                                                  ),
                                                ),
                                              ),
                                              // 點擊層疊最上面，確保收得到（跟影片圖層同一套）
                                              GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () => setState(() {
                                                  _sel = c.id;
                                                  _wmSel = false;
                                                }),
                                                child: const SizedBox.expand(),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                      if (c.id == _sel) {
                                        selRect = r;
                                        selVisual = c;
                                      }
                                    } else if (src.kind == ClipKind.wm) {
                                      final st =
                                          src.wmStyle ?? WatermarkSettings();
                                      children.add(
                                        Positioned.fill(
                                          child: Opacity(
                                            opacity: c.fadeFactorAt(_position),
                                            child: WatermarkLayer(
                                              settings: st,
                                              onChanged: () => setState(() {}),
                                              onDragStart: _pushUndo,
                                              time: pos,
                                              panLocked: () =>
                                                  _pvPts.length >= 2,
                                              // 有別的東西被選取時不吃拖曳，
                                              // 讓給選取路由
                                              panAllowed: (_) =>
                                                  _sel == c.id ||
                                                  (_sel == -1 && !_wmSel),
                                              // 點浮水印片段的元素＝
                                              // 選取＋進浮水印分頁編輯
                                              onTap: () {
                                                setState(() {
                                                  _sel = c.id;
                                                  _wmSel = false;
                                                });
                                                _tabs.animateTo(1);
                                              },
                                              onTapText: () {
                                                setState(() {
                                                  _sel = c.id;
                                                  _wmSel = false;
                                                });
                                                _tabs.animateTo(1);
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    } else if (src.kind == ClipKind.text) {
                                      final st =
                                          src.textStyle ??
                                          TextMark(text: src.name);
                                      final fontSize =
                                          st.sizeFrac * w * c.scale;
                                      final style = TextStyle(
                                        fontFamily: st.fontFamily,
                                        fontSize: fontSize,
                                        letterSpacing: fontSize * st.spacing,
                                        color: st.color.withValues(
                                          alpha: st.opacity,
                                        ),
                                        shadows: st.shadow
                                            ? [
                                                Shadow(
                                                  color: Colors.black
                                                      .withValues(
                                                        alpha:
                                                            0.55 * st.opacity,
                                                      ),
                                                  blurRadius: fontSize * 0.08,
                                                  offset: Offset(
                                                    fontSize * 0.03,
                                                    fontSize * 0.03,
                                                  ),
                                                ),
                                              ]
                                            : null,
                                      );
                                      final painter = TextPainter(
                                        text: TextSpan(
                                          text: src.name,
                                          style: style,
                                        ),
                                        textDirection: TextDirection.ltr,
                                      )..layout();
                                      final r = Rect.fromCenter(
                                        center: Offset(c.px * w, c.py * h),
                                        width: painter.width,
                                        height: painter.height,
                                      );
                                      Widget textW(TextStyle s2) => Text(
                                        src.name,
                                        softWrap: false,
                                        overflow: TextOverflow.visible,
                                        textScaler: TextScaler.noScaling,
                                        style: s2,
                                      );
                                      children.add(
                                        Positioned(
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
                                              opacity: c.fadeFactorAt(
                                                _position,
                                              ),
                                              child: Transform.rotate(
                                                angle:
                                                    st.rotation *
                                                    3.1415926535 /
                                                    180,
                                                child: Container(
                                                  padding: st.bg
                                                      ? EdgeInsets.symmetric(
                                                          horizontal:
                                                              fontSize *
                                                              0.35 *
                                                              st.bgPad,
                                                          vertical:
                                                              fontSize *
                                                              0.18 *
                                                              st.bgPad,
                                                        )
                                                      : EdgeInsets.zero,
                                                  decoration: st.bg
                                                      ? BoxDecoration(
                                                          color: st.bgColor
                                                              .withValues(
                                                                alpha: st
                                                                    .bgOpacity,
                                                              ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                fontSize *
                                                                    st.bgCorner,
                                                              ),
                                                        )
                                                      : null,
                                                  child: st.outline
                                                      ? Stack(
                                                          children: [
                                                            textW(
                                                              style.copyWith(
                                                                color: null,
                                                                shadows: null,
                                                                foreground: Paint()
                                                                  ..style =
                                                                      PaintingStyle
                                                                          .stroke
                                                                  ..strokeWidth =
                                                                      fontSize *
                                                                      st.outlineWidth
                                                                  ..color = st
                                                                      .outlineColor
                                                                      .withValues(
                                                                        alpha: st
                                                                            .opacity,
                                                                      ),
                                                              ),
                                                            ),
                                                            textW(style),
                                                          ],
                                                        )
                                                      : textW(style),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                      if (c.id == _sel) {
                                        selRect = r.inflate(8);
                                        selVisual = c;
                                      }
                                    }
                                  }

                                  // 選取中的圖層：細白框＋四角把手 + 拖曳移動 / 雙指縮放
                                  if (selRect != null && selVisual != null) {
                                    final sc = selVisual;
                                    children.add(
                                      Positioned.fromRect(
                                        rect: selRect,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          // 已選取時再點一次＝維持選取（不要漏到底層變成取消選取）
                                          onTap: () => setState(() {
                                            _sel = sc.id;
                                            _wmSel = false;
                                          }),
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
                                          // 移動／縮放手勢在最上層的
                                          // 「選取路由」處理（拖曳整個
                                          // 預覽區都只作用在選中的素材）
                                          // 文字素材有旋轉時，選取框跟著轉
                                          child: Transform.rotate(
                                            angle:
                                                (_tl.sourceOf(sc).kind ==
                                                        ClipKind.text
                                                    ? (_tl
                                                              .sourceOf(sc)
                                                              .textStyle
                                                              ?.rotation ??
                                                          0)
                                                    : 0.0) *
                                                math.pi /
                                                180,
                                            child: CustomPaint(
                                              painter: _SelectionFramePainter(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }

                                  if (_wmVisibleNow) {
                                    children.add(
                                      WatermarkLayer(
                                        settings: _settings,
                                        onChanged: () => setState(() {}),
                                        onDragStart: _pushWmUndo,
                                        selectedPart: _wmSel
                                            ? _wmPart
                                            : WmPart.none,
                                        onSelectPart: (p) =>
                                            setState(() => _wmPart = p),
                                        // 捏合期間鎖拖曳，手指滑過別的
                                        // 元素才不會把它拖走
                                        panLocked: () => _pvPts.length >= 2,
                                        // 有片段被選取時不吃拖曳，
                                        // 讓給選取路由
                                        panAllowed: (_) => _sel == -1,
                                        time: pos, // 動畫跟著播放頭走
                                        // 點浮水印 Logo＝選取＋切到浮水印分頁
                                        onTap: () {
                                          setState(() {
                                            _wmSel = true;
                                            _sel = -1;
                                          });
                                          _tabs.animateTo(1);
                                        },
                                        // 點浮水印文字＝跟點 Logo 一樣，
                                        // 只切到浮水印分頁。要改字在
                                        // 面板裡改，不要一點就跳鍵盤
                                        onTapText: () {
                                          setState(() {
                                            _wmSel = true;
                                            _sel = -1;
                                          });
                                          _tabs.animateTo(1);
                                        },
                                      ),
                                    );
                                  }

                                  // ===== 選取路由（疊最上層）=====
                                  // 有東西被選取時，整個預覽區的拖曳都
                                  // 只作用在被選取的素材上——手指滑到
                                  // 別的素材也不會把它拖走。
                                  // 點選（tap）會穿透下去，仍可切換選取
                                  TimelineClip? selWmClip;
                                  {
                                    final c = _selClipById(_sel);
                                    // 只在片段真的顯示在播放頭上時才路由，
                                    // 不然會盲拖一個看不見的浮水印
                                    if (c != null &&
                                        _tl.sourceOf(c).kind == ClipKind.wm &&
                                        c.covers(_position)) {
                                      selWmClip = c;
                                    }
                                  }
                                  final wmClipStyle = selWmClip == null
                                      ? null
                                      : _tl.sourceOf(selWmClip).wmStyle;
                                  final selVis = selVisual;
                                  if (selVis != null ||
                                      wmClipStyle != null ||
                                      (_wmSel && _wmVisibleNow)) {
                                    children.add(
                                      Positioned.fill(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          onScaleStart: (d) {
                                            // undo 延到第一次真的動到東西
                                            // 才拍：光按一下不該吃掉 redo
                                            _routerUndoPending = true;
                                            _rtClearGuides();
                                            if (selVis != null) {
                                              _gestureStartPx = selVis.px;
                                              _gestureStartPy = selVis.py;
                                              _gestureStartScale = selVis.scale;
                                              _gestureStartFocal = d.focalPoint;
                                            }
                                            _routerLast = d.focalPoint;
                                          },
                                          onScaleUpdate: (d) {
                                            if (selVis != null) {
                                              _routerPushUndoIfNeeded();
                                              // 文字素材可以放大到 12 倍
                                              //（跟捏合 Listener 同一套），
                                              // 其他 3 倍
                                              final maxS =
                                                  _tl.sourceOf(selVis).kind ==
                                                      ClipKind.text
                                                  ? 12.0
                                                  : 3.0;
                                              setState(() {
                                                // 起點+總位移=未吸附原始值，
                                                // 顯示值才吸中線
                                                final rx =
                                                    (_gestureStartPx +
                                                            (d.focalPoint.dx -
                                                                    _gestureStartFocal
                                                                        .dx) /
                                                                w)
                                                        .clamp(0.0, 1.0);
                                                final ry =
                                                    (_gestureStartPy +
                                                            (d.focalPoint.dy -
                                                                    _gestureStartFocal
                                                                        .dy) /
                                                                h)
                                                        .clamp(0.0, 1.0);
                                                selVis.px = _snapC(rx);
                                                selVis.py = _snapC(ry);
                                                selVis.scale =
                                                    (_gestureStartScale *
                                                            d.scale)
                                                        .clamp(0.05, maxS);
                                              });
                                              _rtSetGuides(
                                                selVis.px,
                                                selVis.py,
                                              );
                                              return;
                                            }
                                            // 浮水印：兩指縮放由外層
                                            // Listener 處理，這裡只管移動
                                            if (_pvPts.length >= 2) {
                                              _routerLast = d.focalPoint;
                                              return;
                                            }
                                            final dd =
                                                d.focalPoint - _routerLast;
                                            _routerLast = d.focalPoint;
                                            final ddx = dd.dx / w;
                                            final ddy = dd.dy / h;
                                            // 平鋪滿版的部件沒有位置概念，
                                            // 移了沒效果，也不該吃 undo
                                            var moved = false;
                                            setState(() {
                                              if (wmClipStyle != null) {
                                                // 浮水印片段：整組一起移。
                                                // 吸附以「領頭」（文字，
                                                // 沒文字就 Logo）為準，兩個
                                                // 部件加同一個修正量，
                                                // 相對位置不會被吸歪
                                                final t2 = wmClipStyle.text;
                                                final lg = wmClipStyle.logo;
                                                final tAlive =
                                                    t2.enabled &&
                                                    !t2.tiled &&
                                                    t2.text.trim().isNotEmpty;
                                                final lAlive =
                                                    lg.enabled && !lg.tiled;
                                                if (tAlive || lAlive) {
                                                  _routerPushUndoIfNeeded();
                                                  moved = true;
                                                  if (_rtRawX == null) {
                                                    _rtRawX = tAlive
                                                        ? t2.x
                                                        : lg.x;
                                                    _rtRawY = tAlive
                                                        ? t2.y
                                                        : lg.y;
                                                    _rtRawX2 = lg.x;
                                                    _rtRawY2 = lg.y;
                                                  }
                                                  _rtRawX = (_rtRawX! + ddx)
                                                      .clamp(0.0, 1.0);
                                                  _rtRawY = (_rtRawY! + ddy)
                                                      .clamp(0.0, 1.0);
                                                  _rtRawX2 = (_rtRawX2 + ddx)
                                                      .clamp(0.0, 1.0);
                                                  _rtRawY2 = (_rtRawY2 + ddy)
                                                      .clamp(0.0, 1.0);
                                                  final sx = _snapC(_rtRawX!);
                                                  final sy = _snapC(_rtRawY!);
                                                  final cx = sx - _rtRawX!;
                                                  final cy = sy - _rtRawY!;
                                                  if (tAlive) {
                                                    t2.x = sx;
                                                    t2.y = sy;
                                                    if (lAlive) {
                                                      lg.x = (_rtRawX2 + cx)
                                                          .clamp(0.0, 1.0);
                                                      lg.y = (_rtRawY2 + cy)
                                                          .clamp(0.0, 1.0);
                                                    }
                                                  } else {
                                                    lg.x = sx;
                                                    lg.y = sy;
                                                  }
                                                  _rtSetGuides(sx, sy);
                                                }
                                              } else {
                                                // 全域浮水印：只移被選部件；
                                                // 被選的已消失/平鋪就退回
                                                // 另一個活著的，不留死拖曳
                                                final t2 = _settings.text;
                                                final lg = _settings.logo;
                                                final hasT =
                                                    t2.enabled &&
                                                    t2.text.trim().isNotEmpty;
                                                final tAlive =
                                                    hasT && !t2.tiled;
                                                final lAlive =
                                                    lg.enabled && !lg.tiled;
                                                var part = _wmPart;
                                                if (part == WmPart.text &&
                                                    !tAlive) {
                                                  part = WmPart.none;
                                                }
                                                if (part == WmPart.logo &&
                                                    !lAlive) {
                                                  part = WmPart.none;
                                                }
                                                if (part == WmPart.none) {
                                                  part = tAlive
                                                      ? WmPart.text
                                                      : (lAlive
                                                            ? WmPart.logo
                                                            : WmPart.none);
                                                }
                                                if (part == WmPart.text) {
                                                  _routerPushUndoIfNeeded();
                                                  moved = true;
                                                  _rtRawX ??= t2.x;
                                                  _rtRawY ??= t2.y;
                                                  _rtRawX = (_rtRawX! + ddx)
                                                      .clamp(0.0, 1.0);
                                                  _rtRawY = (_rtRawY! + ddy)
                                                      .clamp(0.0, 1.0);
                                                  t2.x = _snapC(_rtRawX!);
                                                  t2.y = _snapC(_rtRawY!);
                                                  _rtSetGuides(t2.x, t2.y);
                                                } else if (part ==
                                                        WmPart.logo &&
                                                    lg.enabled &&
                                                    !lg.tiled) {
                                                  _routerPushUndoIfNeeded();
                                                  moved = true;
                                                  _rtRawX ??= lg.x;
                                                  _rtRawY ??= lg.y;
                                                  _rtRawX = (_rtRawX! + ddx)
                                                      .clamp(0.0, 1.0);
                                                  _rtRawY = (_rtRawY! + ddy)
                                                      .clamp(0.0, 1.0);
                                                  lg.x = _snapC(_rtRawX!);
                                                  lg.y = _snapC(_rtRawY!);
                                                  _rtSetGuides(lg.x, lg.y);
                                                }
                                              }
                                            });
                                            if (!moved) return;
                                          },
                                          onScaleEnd: (_) {
                                            _rtClearGuides();
                                            _saveDraft();
                                          },
                                          child: const SizedBox.expand(),
                                        ),
                                      ),
                                    );
                                  }
                                  // 置中輔助線（路由拖曳吸到中線時）
                                  if (_rtGuideV || _rtGuideH) {
                                    children.add(
                                      Positioned.fill(
                                        child: CenterGuides(
                                          vertical: _rtGuideV,
                                          horizontal: _rtGuideH,
                                        ),
                                      ),
                                    );
                                  }

                                  return Stack(
                                    fit: StackFit.expand,
                                    children: children,
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 比例膠囊釘在整個預覽區右上角（不跟畫布走）
              _canvasHint(),
            ],
          ),
        ),
      ),
    );
  }

  // ===== 預覽區雙指縮放（選取中的浮水印或片段）=====
  final Map<int, Offset> _pvPts = {};

  /// 選取路由的上一個拖曳點（算增量用）
  Offset _routerLast = Offset.zero;

  // ===== 選取路由的置中吸附（跟 WatermarkLayer 內建拖曳同手感）=====
  /// 未吸附的原始座標（吸附只作用在顯示值上，不然吸上就拖不出來）
  double? _rtRawX, _rtRawY;

  /// 浮水印片段整組移動時的第二個部件（logo）原始座標
  double _rtRawX2 = 0, _rtRawY2 = 0;

  bool _rtGuideV = false, _rtGuideH = false;
  bool _rtSnapped = false;

  double _snapC(double v) => (v - 0.5).abs() < 0.015 ? 0.5 : v;

  void _rtSetGuides(double x, double y) {
    final v = x == 0.5, hh = y == 0.5;
    if (v != _rtGuideV || hh != _rtGuideH) {
      setState(() {
        _rtGuideV = v;
        _rtGuideH = hh;
      });
    }
    final on = v || hh;
    if (on != _rtSnapped) {
      _rtSnapped = on;
      if (on) HapticFeedback.selectionClick();
    }
  }

  void _rtClearGuides() {
    _rtRawX = null;
    _rtRawY = null;
    _rtSnapped = false;
    if (_rtGuideV || _rtGuideH) {
      setState(() {
        _rtGuideV = false;
        _rtGuideH = false;
      });
    }
  }

  /// 選取路由的 undo 快照「欠著」旗標：手勢開始先掛著，
  /// 第一次真的動到東西才拍——光按一下不該清掉 redo
  bool _routerUndoPending = false;

  void _routerPushUndoIfNeeded() {
    if (!_routerUndoPending) return;
    _routerUndoPending = false;
    _pushWmUndo(); // 0.7 秒內合併，跟捏合 Listener 的快照不會重複拍
  }

  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;
  double _pvBaseClip = 1;

  /// 兩指中點落在畫布的哪個位置（0~1）。算不出來就回 null
  Offset? _canvasPoint(Offset globalPos) {
    final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPos);
    final aspect =
        _canvasRatio.value ??
        (_tl.sources.isEmpty ? 16 / 9 : _tl.sources.first.aspect);
    // 畫布是置中的 AspectRatio，先還原它在預覽區裡的框
    final s = box.size;
    double cw, ch;
    if (s.width / s.height > aspect) {
      ch = s.height;
      cw = ch * aspect;
    } else {
      cw = s.width;
      ch = cw / aspect;
    }
    final left = (s.width - cw) / 2;
    final top = (s.height - ch) / 2;
    if (cw <= 0 || ch <= 0) return null;
    return Offset((local.dx - left) / cw, (local.dy - top) / ch);
  }

  /// 這次捏合要動文字還是圖片：看中點離誰比較近。
  /// 兩者的大小是獨立的，一起縮放會讓已經調好的搭配跑掉
  void _pickPinchTarget(Offset mid) {
    final t = _settings.text;
    final hasText = t.enabled && t.text.trim().isNotEmpty;
    final hasLogo = _settings.logo.enabled;
    // 只有一個存在就不用選，直接動它
    if (!hasText || !hasLogo) {
      _pvHitText = hasText;
      _pvHitLogo = hasLogo;
      return;
    }
    // 有選取就以選取為準（畫面上有白框，使用者知道會動到誰）
    if (_wmPart == WmPart.text) {
      _pvHitText = true;
      _pvHitLogo = false;
      return;
    }
    if (_wmPart == WmPart.logo) {
      _pvHitText = false;
      _pvHitLogo = true;
      return;
    }
    // 還沒選過：用兩指中點離誰近來猜，並把選取設過去讓框顯示出來
    final p = _canvasPoint(mid);
    final nearText = p == null
        ? true
        : (p - Offset(t.x, t.y)).distance <=
              (p - Offset(_settings.logo.x, _settings.logo.y)).distance;
    _pvHitText = nearText;
    _pvHitLogo = !nearText;
    _wmPart = nearText ? WmPart.text : WmPart.logo;
  }

  bool _pvHitText = true;
  bool _pvHitLogo = true;

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
    // 選中的是浮水印素材：記它樣式裡的底值（clip.scale 對它沒作用）
    final selC = _selClipById(_sel);
    final selWm = selC == null ? null : _tl.sourceOf(selC).wmStyle;
    if (selC != null && _tl.sourceOf(selC).kind == ClipKind.wm) {
      _pvBaseClipWmText = selWm?.text.sizeFrac ?? 0.08;
      _pvBaseClipWmLogo = selWm?.logo.sizeFrac ?? 0.2;
    }
    if (_wmSel) _pickPinchTarget((p[0] + p[1]) / 2);
    // 沒選任何東西的捏合什麼都不會動——別拍快照、別清 redo。
    // 有選取時用節流版，跟選取路由的快照 0.7 秒內合併成一步
    if (_wmSel || _sel != -1) _pushWmUndo();
  }

  double _pvBaseClipWmText = 0.08;
  double _pvBaseClipWmLogo = 0.2;

  void _previewPinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    setState(() {
      if (_wmSel) {
        // 只縮放「被選取」的那個部件。文字和圖片是兩個獨立的東西，
        // 一起縮放會把已經調好的搭配弄壞
        final t = _settings.text;
        if (_pvHitText && t.enabled && t.text.trim().isNotEmpty) {
          t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
        }
        if (_pvHitLogo && _settings.logo.enabled) {
          _settings.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
        }
      } else {
        final c = _selClipById(_sel);
        if (c != null) {
          final src = _tl.sourceOf(c);
          if (src.kind == ClipKind.wm) {
            // 浮水印素材整版渲染，不吃 clip.scale——
            // 縮放要落在它樣式的字級／Logo 大小上才有反應
            final st = src.wmStyle;
            if (st != null) {
              if (st.text.enabled && st.text.text.trim().isNotEmpty) {
                st.text.sizeFrac = (_pvBaseClipWmText * f).clamp(0.015, 2.0);
              }
              if (st.logo.enabled) {
                st.logo.sizeFrac = (_pvBaseClipWmLogo * f).clamp(0.03, 2.0);
              }
            }
          } else {
            final maxS = src.kind == ClipKind.text ? 12.0 : 3.0;
            c.scale = (_pvBaseClip * f).clamp(0.05, maxS);
          }
        }
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

  /// 電腦版滾輪 = 縮放選取中的元素（滑鼠沒有雙指縮放）。
  /// 滾輪沒有「結束」事件，存草稿用 debounce
  Timer? _wheelSaveTimer;

  void _previewWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final f = e.scrollDelta.dy > 0 ? (1 / 1.07) : 1.07;
    // 快照要在改動前拍；節流版讓連續滾動 0.7 秒內合併成一步
    if (_wmSel || _sel != -1) _pushWmUndo();
    var changed = false;
    setState(() {
      if (_wmSel) {
        // 兩個部件乘同一個倍率：比例不變，搭配不會跑掉
        final t = _settings.text;
        if (t.enabled && t.text.trim().isNotEmpty) {
          t.sizeFrac = (t.sizeFrac * f).clamp(0.015, 2.0);
          changed = true;
        }
        if (_settings.logo.enabled) {
          _settings.logo.sizeFrac = (_settings.logo.sizeFrac * f).clamp(
            0.03,
            2.0,
          );
          changed = true;
        }
      } else {
        final c = _selClipById(_sel);
        if (c == null) return;
        final src = _tl.sourceOf(c);
        if (src.kind == ClipKind.audio) return;
        if (src.kind == ClipKind.wm) {
          final st = src.wmStyle;
          if (st == null) return;
          if (st.text.enabled && st.text.text.trim().isNotEmpty) {
            st.text.sizeFrac = (st.text.sizeFrac * f).clamp(0.015, 2.0);
          }
          if (st.logo.enabled) {
            st.logo.sizeFrac = (st.logo.sizeFrac * f).clamp(0.03, 2.0);
          }
          changed = true;
        } else {
          final maxS = src.kind == ClipKind.text ? 12.0 : 3.0;
          c.scale = (c.scale * f).clamp(0.05, maxS);
          changed = true;
        }
      }
    });
    if (changed) {
      _wheelSaveTimer?.cancel();
      _wheelSaveTimer = Timer(const Duration(milliseconds: 600), _saveDraft);
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.aspect_ratio, size: 12, color: kTextDim),
                const SizedBox(width: 4),
                Text(
                  _canvasRatio.label,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: kIcon,
                    height: 1.2,
                  ),
                ),
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
  Widget _toolBtn(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    String? tip,
    // 按鈕灰掉時點下去的提示——沒提示的話新手不知道為什麼不能按
    String? disabledHint,
    int quarterTurns = 0,
  }) {
    final on = onTap != null;
    final color = on ? kText : kTextDim.withValues(alpha: 0.4);
    return Tooltip(
      message: tip ?? label,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap:
            onTap ??
            (disabledHint == null
                ? null
                : () => showHint(context, disabledHint)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RotatedBox(
                quarterTurns: quarterTurns,
                child: Icon(icon, size: 21, color: color),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.15,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 工具列上的磁吸開關：自繪磁鐵圖示。
  /// 開啟＝琥珀色、關閉＝灰（不加底色，才不會在一排線條圖示裡過重）
  Widget _snapToolBtn() {
    final color = _snapOn ? kSelect : kTextDim.withValues(alpha: 0.55);
    return Tooltip(
      message: _snapOn ? '磁吸：開（點一下關掉）' : '磁吸：關（點一下打開）',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _toggleSnap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(21, 21),
                painter: _MagnetPainter(color),
              ),
              const SizedBox(height: 4),
              Text(
                '磁吸',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.15,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineTab() {
    if (_pxPerSec <= 0) {
      final screenW = MediaQuery.of(context).size.width - 60;
      _pxPerSec = (screenW / (_tl.duration <= 0 ? 10 : _tl.duration)).clamp(
        6.0,
        60.0,
      );
    }
    final sel = _selClip;

    return LayoutBuilder(
      builder: (context, box) {
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
                      _tlScroll.jumpTo(
                        (_tlScroll.offset - d.delta.dx).clamp(
                          0.0,
                          _tlScroll.position.maxScrollExtent,
                        ),
                      );
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
                          minHeight: (box.maxHeight - 60).clamp(0.0, 1e9),
                        ),
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
                                  if (id != -1) _selTrack = -1;
                                }),
                                // 點軌道空白處＝選取該軌（貼上目標）
                                onTapTrack: (t) =>
                                    setState(() => _selTrack = t),
                                // 長按左邊的圖示＝刪掉整條軌道
                                onDeleteTrack: _deleteTrack,
                                selectedTrack: _selTrack,
                                extraTracks: _extraBlankTracks,
                                snapEnabled: _snapOn,
                                onSeek: _seekScrub,
                                onTrim: _trimClip,
                                onTrimStart: _pushUndo,
                                onDrop: _dropClip,
                                onAddMedia: _addMedia,
                                onReorderTrack: _reorderTrack,
                                mutedTracks: _mutedTracks,
                                onToggleMute: (t) => setState(() {
                                  if (!_mutedTracks.remove(t)) {
                                    _mutedTracks.add(t);
                                  }
                                  _syncMedia();
                                }),
                                onLongPressClip: _showClipMenu,
                                onLongPressEmpty: _showEmptyMenu,
                                onTapSelectedClip: (id) {
                                  final c = _selClipById(id);
                                  if (c == null) return;
                                  final k = _tl.sourceOf(c).kind;
                                  if (k == ClipKind.text) {
                                    _editTextClip(c);
                                  } else if (k == ClipKind.wm) {
                                    _editWmClip(c);
                                  } else if (k == ClipKind.mosaic) {
                                    _editMosaicClip(c);
                                  }
                                },
                                onLiftChanged: (v) => _lifting = v,
                                // 旁白軌：標籤變紅色錄音鈕，按了邊播邊錄
                                voiceTrack: _voTrack,
                                voiceRecording: _voRecording,
                                onVoiceRecordTap: _toggleVoiceRecord,
                                voiceStart: _voStartPos,
                                voiceLevels: _voLevels,
                                // 捏合由外層偵測，這裡只用來鎖住橫向捲動
                                pinching: _tlPinching,
                                // 桌面滾輪縮放：下限 1px/秒，長片也能整條盡收眼底
                                onZoom: (v) {
                                  setState(
                                    () => _pxPerSec = v.clamp(1.0, 200.0),
                                  );
                                  WidgetsBinding.instance.addPostFrameCallback(
                                    (_) => _syncScrollToPosition(),
                                  );
                                },
                                watermark: _settings.hasAnyMark
                                    ? (start: _wmStart, end: _wmEndEff)
                                    : null,
                                wmLabel:
                                    _settings.text.enabled &&
                                        _settings.text.text.trim().isNotEmpty
                                    ? _settings.text.text
                                    : '浮水印',
                                wmSelected: _wmSel,
                                wmHidden: _wmHidden,
                                onToggleWmVisible: () =>
                                    setState(() => _wmHidden = !_wmHidden),
                                // 點浮水印軌＝選取＋自動切到浮水印分頁。
                                // 一律跳：按下時 onSelectWmDrag 已先把
                                // 選取設起來，這裡再看 wasSel 永遠不會跳
                                onSelectWm: () {
                                  setState(() {
                                    _wmSel = true;
                                    _sel = -1;
                                  });
                                  _tabs.animateTo(1);
                                },
                                // 按下只安靜選取；點擊（放開時幾乎沒動）
                                // 才由 timeline_editor 呼叫 onSelectWm 跳分頁。
                                // 拖曳調範圍不會被打斷、捏合誤觸也不會跳
                                onSelectWmDrag: () => setState(() {
                                  _wmSel = true;
                                  _sel = -1;
                                }),
                                onMoveWm: (ns) => setState(() {
                                  final len = _wmEndEff - _wmStart;
                                  final s = ns.clamp(
                                    0.0,
                                    (_tl.duration - len).clamp(0.0, 1e6),
                                  );
                                  _wmStart = s;
                                  _wmEnd = s + len;
                                }),
                                onTrimWm: (d, fromLeft) => setState(() {
                                  // 跟片段修剪同一套磁吸：對齊素材頭尾
                                  if (fromLeft) {
                                    final w = _wmStart + d;
                                    final s = _snapOn
                                        ? _tl.snapTime(w, _position, _pxPerSec)
                                        : w;
                                    _wmStart = s.clamp(0.0, _wmEndEff - 0.3);
                                  } else {
                                    final w = _wmEndEff + d;
                                    final e = _snapOn
                                        ? _tl.snapTime(w, _position, _pxPerSec)
                                        : w;
                                    _wmEnd = e.clamp(
                                      _wmStart + 0.3,
                                      _tl.duration,
                                    );
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
                      _toolBtn(
                        Icons.splitscreen,
                        '切割',
                        _splitAtPlayhead,
                        tip: '在播放處切割',
                        quarterTurns: 1,
                      ),
                      _toolBtn(
                        Icons.delete_outline,
                        '刪除',
                        _wmSel
                            ? _deleteWatermark
                            : (sel == null ? null : _deleteSelected),
                        tip: _wmSel ? '刪除浮水印' : '刪除片段',
                        disabledHint: '先在時間軸點選一個片段',
                      ),
                      _toolBtn(
                        Icons.copy,
                        '複製',
                        _wmSel
                            ? _duplicateWatermark
                            : (sel == null
                                  ? null
                                  : () => setState(
                                      () => _clipboard = sel.copy(),
                                    )),
                        tip: _wmSel ? '複製浮水印成素材' : '複製選取片段',
                        disabledHint: '先在時間軸點選一個片段',
                      ),
                      _toolBtn(
                        Icons.content_paste,
                        '貼上',
                        _clipboard == null ? null : _pasteClipboard,
                        tip: '貼在播放處',
                        disabledHint: '還沒有複製任何片段',
                      ),
                      _toolBtn(
                        Icons.open_in_full,
                        '大小',
                        (sel == null ||
                                _tl.sourceOf(sel).kind == ClipKind.audio ||
                                // 浮水印素材整版渲染不吃 clip.scale，
                                // 開這張表調了也沒反應
                                _tl.sourceOf(sel).kind == ClipKind.wm)
                            ? null
                            : () => _openScaleSheet(sel),
                        tip: '縮放物件大小',
                        disabledHint: sel == null
                            ? '先在時間軸點選一個片段'
                            : (_tl.sourceOf(sel).kind == ClipKind.wm
                                  ? '浮水印大小請在浮水印分頁調，或在預覽雙指縮放'
                                  : '聲音片段沒有畫面大小可調'),
                      ),
                      _toolBtn(Icons.speed, '速度', _openSpeedSheet, tip: '播放速度'),
                      _toolBtn(
                        Icons.tune,
                        '調色',
                        (sel == null ||
                                _tl.sourceOf(sel).kind == ClipKind.audio ||
                                _tl.sourceOf(sel).kind == ClipKind.text ||
                                _tl.sourceOf(sel).kind == ClipKind.mosaic ||
                                // 浮水印素材的調色管線沒接（預覽跟匯出
                                // 都不吃），開了等於騙人
                                _tl.sourceOf(sel).kind == ClipKind.wm)
                            ? null
                            : _enterColorMode,
                        tip: 'HSV 調色',
                        disabledHint: sel == null
                            ? '先在時間軸點選要調色的片段'
                            : '這種素材不能調色（影片、圖片才可以）',
                      ),
                      // 直向的 compress 轉 90°＝把左右的空隙擠掉
                      _toolBtn(
                        Icons.compress,
                        '整理',
                        _closeGaps,
                        tip: '把空隙補起來、素材接齊',
                        quarterTurns: 1,
                      ),
                      _snapToolBtn(),
                      _toolBtn(Icons.add, '加素材', _addMediaChoice),
                      _toolBtn(
                        Icons.auto_awesome,
                        '效果',
                        sel == null ? null : () => _openClipOptions(sel),
                        tip: '音量與淡化',
                        disabledHint: '先在時間軸點選一個片段',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
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
                border: Border(top: BorderSide(color: kPanelHi)),
              ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected ? kAmber : kText,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: kTextDim,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (selected) const Icon(Icons.check, size: 17, color: kAmber),
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
                Builder(
                  builder: (context) {
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
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 縮放物件大小（影片/圖片/文字在畫面上的尺寸；跟預覽雙指縮放同一個值）
  void _openScaleSheet(TimelineClip clip) {
    _pushUndo();
    // 文字的底字級小，3 倍看起來還是小；放寬到 12 倍，允許超出畫面
    final maxScale = _tl.sourceOf(clip).kind == ClipKind.text ? 12.0 : 3.0;
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
                  const Text(
                    '大小',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    '${(clip.scale * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 12,
                      color: kTextDim,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Slider(
                value: clip.scale.clamp(0.05, maxScale),
                min: 0.05,
                max: maxScale,
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
                  style: TextButton.styleFrom(foregroundColor: kTextDim),
                  child: const Text('重設', style: TextStyle(fontSize: 12.5)),
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
    final hasAudio =
        _tl.sourceOf(clip).kind == ClipKind.video ||
        _tl.sourceOf(clip).kind == ClipKind.audio;
    _pushUndo();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Widget row(
            String label,
            double value,
            double max,
            String suffix,
            ValueChanged<double> onChanged,
          ) {
            return Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ),
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
                  child: Text(
                    suffix,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: kTextDim),
                  ),
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
                    row(
                      '音量',
                      clip.volume,
                      2,
                      '${(clip.volume * 100).round()}%',
                      (v) {
                        clip.volume = v;
                        _ctrls[clip.id]?.setVolume(v.clamp(0.0, 1.0));
                      },
                    ),
                  row(
                    '淡入',
                    clip.fadeIn,
                    3,
                    '${clip.fadeIn.toStringAsFixed(1)}s',
                    (v) => clip.fadeIn = v,
                  ),
                  row(
                    '淡出',
                    clip.fadeOut,
                    3,
                    '${clip.fadeOut.toStringAsFixed(1)}s',
                    (v) => clip.fadeOut = v,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(_saveDraft);
  }

  /// 把片段（同 id）換成新的實例（倒轉／還原時 sourceIndex 是 final，
  /// 只能整顆重建）。播放器也跟著換新來源
  void _swapClip(TimelineClip oldClip, TimelineClip newClip) {
    final i = _tl.clips.indexOf(oldClip);
    if (i < 0) return;
    setState(() => _tl.clips[i] = newClip);
    _ctrls.remove(oldClip.id)?.dispose();
    _ensureCtrlFor(newClip);
    _resyncPlayback();
    _saveDraft();
  }

  /// 按下倒轉：把這段現場做成「已經倒好的影片檔」再換上去。
  /// 之後它就是普通素材——預覽有聲音、播放流暢、匯出不用特殊處理。
  /// Web 或處理失敗時退回簡易模式（抽幀預覽，匯出時才倒轉）
  Future<void> _reverseClip(int clipId, double sp, VoidCallback onDone) async {
    final c = _selClipById(clipId);
    if (c == null) return;
    final src = _tl.sourceOf(c);
    if (src.kind != ClipKind.video || kIsWeb) {
      setState(() {
        c.speed = sp;
        c.reverse = true;
      });
      _resyncPlayback();
      onDone();
      return;
    }
    _pause();
    // 進度視窗：長片段要分很多段處理，得讓人知道還活著
    final progress = ValueNotifier<double>(0);
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在倒轉…'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: v > 0 ? v : null),
                const SizedBox(height: 12),
                Text('${(v * 100).toStringAsFixed(0)} %'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => engine.cancelExport(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    ).whenComplete(() => dialogOpen = false);

    // 輸出尺寸：跟著來源走，但長邊 cap 在 1920（記憶體與速度的平衡）
    var tw = src.w > 0 ? src.w : 1080;
    var th = src.h > 0 ? src.h : 1920;
    final long = math.max(tw, th);
    if (long > 1920) {
      final k = 1920 / long;
      tw = (tw * k).round();
      th = (th * k).round();
    }
    tw -= tw % 2;
    th -= th % 2;

    final made = await engine.renderReversedClip(
      src.path,
      c.trimStart,
      c.trimEnd,
      tw,
      th,
      onProgress: (v) => progress.value = v,
    );
    if (mounted && dialogOpen) Navigator.of(context).pop();
    if (!mounted) return;

    final cur = _selClipById(clipId);
    if (cur == null) return;
    if (made == null) {
      // 失敗／取消：退回簡易模式，功能照樣能用
      setState(() {
        cur.speed = sp;
        cur.reverse = true;
      });
      _resyncPlayback();
      showHint(context, '倒轉檔沒做成，改用簡易預覽（匯出仍會正確倒轉）');
      onDone();
      return;
    }
    final segLen = cur.trimEnd - cur.trimStart;
    final newIdx = _tl.sources.length;
    _tl.sources.add(
      MediaSource(
        path: made,
        name: src.name,
        kind: ClipKind.video,
        duration: segLen,
        w: tw,
        h: th,
        // 還原用：記下是從哪個原始檔的哪一段倒出來的
        revOf: src.path,
        revStart: cur.trimStart,
        revEnd: cur.trimEnd,
      ),
    );
    // 倒轉檔的縮圖與拖曳快取
    engine.makeThumbnails(made, segLen, 10, fastDecode: true).then((t) {
      if (mounted && t.isNotEmpty) setState(() => _thumbs[newIdx] = t);
    });
    _makeScrubCache(newIdx, made, segLen);
    _swapClip(
      cur,
      TimelineClip.fromJson({
        ...cur.toJson(),
        'sourceIndex': newIdx,
        'trimStart': 0.0,
        'trimEnd': segLen,
        'reverse': false, // 內容已經倒好，不用再標
        'speed': sp,
      }),
    );
    onDone();
  }

  /// 速度拉回正的：把倒轉檔換回原始素材（修剪過的範圍照樣對應回去）
  void _unreverseClip(int clipId, double sp, VoidCallback onDone) {
    final c = _selClipById(clipId);
    if (c == null) return;
    if (c.reverse) {
      // 簡易模式：關掉旗標就好
      setState(() {
        c.reverse = false;
        c.speed = sp;
      });
      _resyncPlayback();
      onDone();
      return;
    }
    final src = _tl.sourceOf(c);
    final orig = src.revOf;
    if (orig == null) return; // 不是倒轉檔，沒事做
    final idx = _tl.sources.indexWhere(
      (s) => s.path == orig && s.revOf == null,
    );
    if (idx < 0) {
      // 原始素材已不在專案裡（理論上不會發生）：保底只調速度
      setState(() => c.speed = sp);
      onDone();
      return;
    }
    // 倒轉檔上的修剪範圍（a,b）對應回原始檔：
    // 檔長 L＝revEnd-revStart，start'＝revStart+(L-b)、end'＝revStart+(L-a)
    final revLen = src.revEnd - src.revStart;
    _swapClip(
      c,
      TimelineClip.fromJson({
        ...c.toJson(),
        'sourceIndex': idx,
        'trimStart': src.revStart + (revLen - c.trimEnd),
        'trimEnd': src.revStart + (revLen - c.trimStart),
        'reverse': false,
        'speed': sp,
      }),
    );
    onDone();
  }

  /// 速度選單：選了片段＝調「那個片段」的速度（時間軸長度跟著縮放、
  /// 匯出同步生效）；沒選片段＝調整條影片的播放速度
  void _openSpeedSheet() {
    final selId = _sel; // 倒轉會換掉片段實例，之後都用 id 重查
    final sel = _selClipById(selId);
    final selSrc = sel == null ? null : _tl.sourceOf(sel);
    // 只有影片/音訊能變速（圖片、文字的長度直接拖把手就好）
    final clipMode =
        sel != null &&
        selSrc != null &&
        (selSrc.isVideo || selSrc.kind == ClipKind.audio);
    var pushed = false; // 這次選單只拍一次快照
    // 拖過方向線先掛著，「放開滑桿」才真的做倒轉／還原——
    // 不然拖到一半就跳出處理視窗，嚇人
    double? pendingSigned;
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
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      clipMode
                          ? '這段 '
                                '${(_selClipById(selId) ?? sel).length.toStringAsFixed(1)}s'
                          : _fmt(_tl.duration / _speed),
                      style: const TextStyle(
                        color: kTextDim,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 速度檔位：滑桿左半邊是負的＝倒著放。
                // 用固定檔位不用連續值，免得停在 1.03x 這種數字
                Builder(
                  builder: (context) {
                    // 倒轉/還原會把片段換成新實例（指向倒轉檔），每次重查
                    final sel = _selClipById(selId);
                    if (sel == null) return const SizedBox.shrink();
                    final now = clipMode ? sel.speed : _speed;
                    // 倒轉中＝flag（簡易模式）或素材本身就是倒轉檔
                    final rev =
                        clipMode &&
                        (sel.reverse || _tl.sourceOf(sel).revOf != null);
                    final actualSigned = rev ? -now : now;
                    // 拖曳中先顯示手指所在的檔位，放開才生效
                    final signed = pendingSigned ?? actualSigned;
                    final showRev = signed < 0;
                    final stops = clipMode
                        ? kSpeedStops
                        : kSpeedStops.where((s) => s > 0).toList();
                    var idx = 0;
                    for (var i = 1; i < stops.length; i++) {
                      if ((stops[i] - signed).abs() <
                          (stops[idx] - signed).abs()) {
                        idx = i;
                      }
                    }

                    void apply(double s) {
                      final sp = s.abs();
                      if (clipMode) {
                        if (!pushed) {
                          _pushUndo();
                          pushed = true;
                        }
                        final wantRev = s < 0;
                        if (wantRev != rev) {
                          // 方向變了：做倒轉檔／還原原始素材（非同步，
                          // 完成後片段會被換成新實例）
                          if (wantRev) {
                            _reverseClip(selId, sp, () => setSheet(() {}));
                          } else {
                            _unreverseClip(selId, sp, () => setSheet(() {}));
                          }
                          return;
                        }
                        setState(() => sel.speed = sp);
                        _ctrls[sel.id]?.setPlaybackSpeed(_speed * sp);
                        _resyncPlayback(); // 變速改了時間對應
                      } else {
                        setState(() => _speed = sp);
                        for (final e in _tl.clips) {
                          _ctrls[e.id]?.setPlaybackSpeed(sp * e.speed);
                        }
                      }
                      setSheet(() {});
                    }

                    return Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              clipMode ? '-4x' : '0.25x',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: kTextDim,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: idx.toDouble(),
                                min: 0,
                                max: (stops.length - 1).toDouble(),
                                divisions: stops.length - 1,
                                onChanged: (v) {
                                  final s = stops[v.round()];
                                  if (s == signed) return;
                                  if ((s < 0) == rev) {
                                    // 同方向：速度即時生效
                                    pendingSigned = null;
                                    apply(s);
                                  } else {
                                    // 換方向：先掛著，放開才處理
                                    pendingSigned = s;
                                    setSheet(() {});
                                  }
                                },
                                onChangeEnd: (_) {
                                  final s = pendingSigned;
                                  if (s == null) return;
                                  pendingSigned = null;
                                  apply(s);
                                },
                              ),
                            ),
                            const Text(
                              '4x',
                              style: TextStyle(fontSize: 10.5, color: kTextDim),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${signed.abs().toStringAsFixed(signed.abs() == signed.abs().roundToDouble() ? 0 : 2)}x',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            if (showRev) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: kSelect,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  '倒轉',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: kBg,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (rev && sel.reverse)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              kIsWeb
                                  ? '網頁版只能逐格預覽；手機 App 會直接'
                                        '做成流暢、有聲音的倒轉片段'
                                  : '這段用簡易預覽（逐格、無聲音）；'
                                        '匯出的成品畫面和聲音都會正確倒轉',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 11,
                                color: kTextDim,
                                height: 1.5,
                              ),
                            ),
                          ),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: (now == 1.0 && !rev)
                              ? null
                              : () => apply(1.0),
                          style: TextButton.styleFrom(
                            foregroundColor: kTextDim,
                            minimumSize: const Size(0, 32),
                          ),
                          child: const Text(
                            '回到原速',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(_saveDraft);
  }

  /// 預覽時把調色套上去。沒調過就原樣回傳，不多包一層。
  ///
  /// 注意：Web 的影片是 HTML <video> 元素，跟 Flutter 畫布分開合成，
  /// 濾鏡吃不到它——Web 上只有拖曳時的快取幀會變色，播放中的影片不會。
  /// 手機是材質（texture），兩種都正常。
  Widget _tinted(TimelineClip c, Widget child) {
    // 比對中直接回傳原樣，看得出調色前後差多少
    if (_colorCompare || !c.color.hasColor) return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(c.color.matrix),
      child: child,
    );
  }

  /// 色相／飽和度／明度／對比合成一個 4x5 色彩矩陣。
  ///
  /// 套用順序跟匯出端一致：先色相旋轉、再飽和度、

  // ===== 調色模式 =====
  //
  // 用獨立模式而不是彈出選單：選單會蓋住半個畫面，調色最需要的就是
  // 一邊拉一邊看預覽。進入後下半部換成調色盤，預覽照常在上面
  bool _colorMode = false;
  int _colorClipId = -1;

  /// 按住「原圖」比對中：先不要套調色
  bool _colorCompare = false;

  void _enterColorMode() {
    final sel = _selClipById(_sel);
    final selSrc = sel == null ? null : _tl.sourceOf(sel);
    if (sel == null ||
        selSrc == null ||
        selSrc.kind == ClipKind.audio ||
        selSrc.kind == ClipKind.text) {
      showHint(context, '先選一個影片或圖片片段再調色', error: true);
      return;
    }
    _pause();
    // 播放頭不在這個片段上的話先跳進去。不然畫面顯示的是別的素材，
    // 拉滑桿完全看不到變化，會以為調色壞掉
    if (!sel.covers(_position)) {
      _seekScrub(sel.offset + math.min(0.15, sel.length / 2));
      // 時間軸也跟著捲過去，播放頭才不會跑到看不見的地方
      if (_tlScroll.hasClients) {
        _tlScroll.jumpTo(
          (_position * _pxPerSec).clamp(
            0.0,
            _tlScroll.position.maxScrollExtent,
          ),
        );
      }
    }
    setState(() {
      _colorMode = true;
      _colorClipId = sel.id;
    });
  }

  void _exitColorMode() {
    setState(() {
      _colorMode = false;
      _colorCompare = false;
    });
    _saveDraft();
  }

  /// 調色盤：共用元件，照片編輯也是同一個
  Widget _buildColorPanel() {
    // 調色中點了預覽裡別的影片/圖片 → 調色目標跟著換過去，
    // 不然白框在 B 身上、滑桿卻在調 A，看起來像壞掉
    final selNow = _selClipById(_sel);
    if (selNow != null) {
      final k = _tl.sourceOf(selNow).kind;
      if (k == ClipKind.video || k == ClipKind.image) {
        _colorClipId = selNow.id;
      }
    }
    final c = _selClipById(_colorClipId);
    if (c == null) {
      // 片段被刪掉了就退出去，不要留在空白的調色盤
      WidgetsBinding.instance.addPostFrameCallback((_) => _exitColorMode());
      return const SizedBox.shrink();
    }
    return ColorGradePanel(
      key: ValueKey('grade-${c.id}'), // 換目標時面板內部狀態重置
      grade: c.color,
      onChanged: () => setState(() {}),
      onBeforeChange: _pushUndo,
      // 完成鈕＝離開調色；點下方任何分頁也一樣會離開（雙保險）
      onDone: _exitColorMode,
      // 面板 dispose 時會回呼一次 false，那時這頁可能也在收——要擋
      onCompare: (on) {
        if (mounted) setState(() => _colorCompare = on);
      },
    );
  }

  /// 預估匯出時間，以及那是不是實測過的數字
  Future<(double, bool)> _estimateExport(int outW, int outH, double dur) async {
    return (
      await ExportSpeed.estimate(outW: outW, outH: outH, outSeconds: dur),
      await ExportSpeed.hasMeasured(),
    );
  }

  /// 匯出頁（使用者選定 B 款極簡設定列）：
  /// 資訊列（比例／解析度／畫質／預估大小／預估時間）＋匯出鈕
  Widget _buildExportTab() {
    final (outW, outH) = computeCanvasSize(_tl, _resolution, _canvasRatio);
    final dur = _tl.duration / _speed;
    final mb =
        (outW * outH * 30 * 0.09 / 8 * dur + 40000 * dur) /
        (1024 * 1024) *
        _quality.sizeFactor;

    Widget row(
      String label,
      String value,
      VoidCallback? onTap, {
      bool divider = true,
    }) {
      return InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
          decoration: divider
              ? const BoxDecoration(
                  border: Border(bottom: BorderSide(color: kBorder)),
                )
              : null,
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: kText,
                ),
              ),
              const Spacer(),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: kTextDim,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right, size: 17, color: kTextDim),
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
          _openResolutionSheet,
        ),
        row('畫質', _quality.label, _openQualitySheet),
        row('預估大小', '${fmtDur(dur)}・約 ${mb.toStringAsFixed(0)} MB', null),
        // 匯出時間：跑過一次之後才是「這台機器」的實測值，
        // 第一次只能粗估，所以標示清楚不要讓人以為很準
        FutureBuilder<(double, bool)>(
          future: _estimateExport(outW, outH, dur),
          builder: (context, snap) {
            final d = snap.data;
            return row(
              '預估時間',
              d == null
                  ? '計算中…'
                  : '約 ${fmtDuration(d.$1)}${d.$2 ? '' : '（粗估）'}',
              null,
              divider: false,
            );
          },
        ),
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
                Builder(
                  builder: (context) {
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
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 實心馬蹄磁鐵（Flutter 內建圖示沒有磁鐵，自己畫一顆）。
/// 兩隻腳靠近末端挖一條橫縫，分出「磁極」——沒有這條縫的話
/// 小尺寸下看起來只是一個拱門
class _MagnetPainter extends CustomPainter {
  final Color color;

  const _MagnetPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // 以 24×24 設計，等比縮放到實際大小
    double x(double v) => v * size.width / 24.0;
    double y(double v) => v * size.height / 24.0;

    // 外圈往下兩隻腳 → 內圈繞回去，形成 U 型實心
    final body = Path()
      ..moveTo(x(4), y(20))
      ..lineTo(x(4), y(11))
      ..arcToPoint(
        Offset(x(20), y(11)),
        radius: Radius.circular(x(8)),
        clockwise: true,
      )
      ..lineTo(x(20), y(20))
      ..lineTo(x(15.5), y(20))
      ..lineTo(x(15.5), y(11))
      ..arcToPoint(
        Offset(x(8.5), y(11)),
        radius: Radius.circular(x(3.5)),
        clockwise: false,
      )
      ..lineTo(x(8.5), y(20))
      ..close();

    // 橫縫挖掉（不是塗深色）：這樣不管底下是深色還是反白都看得出來
    final gap = Path()..addRect(Rect.fromLTWH(0, y(16.2), size.width, y(1.4)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, body, gap),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_MagnetPainter old) => old.color != color;
}

/// 馬賽克區域的細格線（淡淡的，標示範圍但不擋內容）
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

/// 拖曳預覽用的「已解碼幀」快取。
///
/// 之前每張都交給 Image.memory 現解，ImageCache 一沒命中就是一次 JPEG 解碼
/// 卡在 UI 執行緒上；手指一快就整片 miss，於是怎麼加幀都還是頓。
/// 改成事先把播放頭附近的幀解成 ui.Image 放著，畫的時候只是貼一張材質。
class _ScrubDecoder {
  /// 從快取幀清單裡拿離 [fi] 最近、已經抽好的那張（可能整排都還沒好）
  static Uint8List? nearestBytes(List<Uint8List?> frames, int fi) {
    for (var d = 0; d < frames.length; d++) {
      final a = fi - d;
      if (a >= 0 && frames[a] != null) return frames[a];
      final b = fi + d;
      if (b < frames.length && frames[b] != null) return frames[b];
    }
    return null;
  }

  /// 播放頭前後各先解好幾張
  static const _window = 10;

  /// 最多留幾張已解碼的（超過就丟離播放頭最遠的）。
  /// 540×960 的 RGBA 一張就是 2MB——這個數字直接決定
  /// 拖曳時會佔多少記憶體，開太大匯出就會被系統殺掉
  static const _capacity = 24;

  final List<Uint8List?> frames;
  final VoidCallback onReady;

  final Map<int, ui.Image> _decoded = {};
  final Set<int> _pending = {};
  int _center = -1;
  bool _disposed = false;

  _ScrubDecoder(this.frames, {required this.onReady});

  ui.Image? operator [](int i) => _decoded[i];

  /// 把窗口中心移到 [fi]：補解窗內缺的，丟掉離太遠的
  void focus(int fi) {
    if (_disposed || fi == _center) return; // 沒移動就什麼都不用做
    _center = fi;
    _evictFar();
    for (var d = 0; d <= _window; d++) {
      for (final i in d == 0 ? [fi] : [fi + d, fi - d]) {
        if (i < 0 || i >= frames.length) continue;
        if (_decoded.containsKey(i) || _pending.contains(i)) continue;
        final b = frames[i];
        if (b == null) continue;
        _pending.add(i);
        _decode(i, b);
      }
    }
  }

  Future<void> _decode(int i, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      _decoded[i] = frame.image;
      // 只有「現在正要顯示的那張」才值得觸發重畫，
      // 不然一次解 37 張就是 37 次重畫
      if (i == _center) onReady();
    } catch (_) {
      // 解不開就算了，顯示端會退回用位元組畫
    } finally {
      _pending.remove(i);
    }
  }

  void _evictFar() {
    if (_decoded.length <= _capacity) return;
    final keys = _decoded.keys.toList()
      ..sort((a, b) => (b - _center).abs().compareTo((a - _center).abs()));
    for (final k in keys) {
      if (_decoded.length <= _capacity) break;
      _decoded.remove(k)?.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    for (final img in _decoded.values) {
      img.dispose();
    }
    _decoded.clear();
  }
}
