import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData,
    HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import '../services/audio_picker.dart';
import '../services/native_frames.dart';
import '../services/playback_trace.dart';
import '../services/comp_player.dart';
import '../services/diagnostics.dart';
import '../services/export_speed.dart';
import '../services/file_reader.dart';
import '../services/media_prep.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../services/watermark_renderer.dart';
import '../services/work_files.dart';
import '../theme.dart';
import 'playback_test_screen.dart';
import '../widgets/color_grade_panel.dart';
import '../widgets/timeline_editor.dart';
import '../widgets/prep_gate_view.dart';
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

  /// 一次帶一整批影片進來（照選取順序接在同一軌上）。
  /// 從首頁選了好幾支就走這條——以前多選只能進批次浮水印，
  /// 想剪成一支還得先進去再一支一支加
  final List<String>? videoPaths;

  /// 空白專案：不帶素材直接進編輯器，進去再用「加素材」加。
  /// 想先鋪好文字／浮水印再放影片的人不用被迫先選一支
  final bool blank;
  final WatermarkSettings? initialWatermark; // 從範本卡片開新專案時帶入
  final Map<String, dynamic>? draft; // 從草稿還原

  const VideoEditorScreen({
    super.key,
    this.videoPath,
    this.videoPaths,
    this.initialWatermark,
    this.draft,
    this.blank = false,
  }) : assert(
         videoPath != null ||
             videoPaths != null ||
             draft != null ||
             blank,
       );

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

/// 按住才能拖，但比 Flutter 內建的 ReorderableDelayedDragStartListener
/// 短——那個寫死 kLongPressTimeout（500ms），按起來像沒反應。
///
/// 短一點不會跟左右捲動打架：DelayedMultiDragGestureRecognizer 在
/// 時間到之前只要手指移動超過 slop 就會放棄，直接滑＝捲動、
/// 按著不動＝拖曳，兩者分得開
class _HoldToDragListener extends ReorderableDragStartListener {
  const _HoldToDragListener({
    super.key,
    required super.child,
    required super.index,
  });

  /// 200ms：內建那個是 500ms，按起來像沒反應；再短就會跟捲動搶
  static const _delay = Duration(milliseconds: 200);

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      DelayedMultiDragGestureRecognizer(delay: _delay, debugOwner: this);
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

  // 片段選取與浮水印選取互斥：用 getter/setter 綁死，
  // 而不是在每個「加素材」的地方各補一行清除。
  // 漏掉一個就會同時亮兩個選取框（加影片、加音樂、錄旁白、
  // 貼上都曾經漏掉），而且以後新增路徑還會再漏一次
  int _selValue = -1;
  bool _wmSelValue = false;

  /// 選取的片段 id（-1 = 沒有）
  int get _sel => _selValue;
  set _sel(int v) {
    _selValue = v;
    if (v != -1) _wmSelValue = false;
  }

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

  /// 畫質還沒被使用者手動選過＝跟著素材自動挑（見 _qualityEff）
  bool _qualityAuto = true;

  /// 素材裡最高的位元率（kbps，檔案大小÷長度）。0＝量不到（Web）
  double _srcKbps = 0;

  /// 位元率最高那支素材的編碼格式（hevc/h264/空＝不知道）
  String _srcCodec = '';

  /// 專案裡最高的影格率（輸出會跟著它走）
  double _srcFps = 0;

  /// 實際要用的畫質：使用者選過就聽他的，沒選過就依素材本身的
  /// 位元率挑。放成 getter 而不是存起來，改解析度時才會跟著重算——
  /// 同一支影片縮到 720p，需要的位元率就少了一半
  ExportQuality get _qualityEff {
    if (!_qualityAuto || _srcKbps <= 0) return _quality;
    final (w, h) = computeCanvasSize(_tl, _resolution, _canvasRatio);
    return recommendQuality(
      srcKbps: _srcKbps,
      outW: w,
      outH: h,
      fps: outputFps(_srcFps, w, h),
      // 重壓一次的餘裕看來源編碼：HEVC 換 H.264 同畫質要多吃五六成
      // 位元率，H.264 對 H.264 幾乎打平，不知道是哪種取中間值
      headroom: switch (_srcCodec) {
        'hevc' => 1.6,
        'h264' => 1.1,
        _ => 1.25,
      },
    );
  }

  /// 量素材的位元率（檔案大小÷長度），取最高的那支當基準：
  /// 一次匯出只有一個畫質，要顧就顧最吃位元率的那支
  Future<void> _measureSrcKbps() async {
    var best = 0.0;
    var bestCodec = '';
    var maxFps = 0.0;
    for (final src in _tl.sources) {
      if (!src.isVideo || src.duration <= 0) continue;
      final bytes = await fileSizeBytes(src.path);
      if (bytes <= 0) continue;
      // 編碼格式跟影格率順便帶回來（匯入時為了偵測 HDR 已經 probe
      // 過一次，引擎有快取，這裡不會再跑一次 FFprobe）
      final info = await engine.probeVideoInfo(src.path);
      if (info.fps > maxFps) maxFps = info.fps;
      final kbps = bytes * 8 / src.duration / 1000;
      if (kbps > best) {
        best = kbps;
        bestCodec = info.codec;
      }
    }
    if (!mounted) return;
    if (best != _srcKbps || bestCodec != _srcCodec || maxFps != _srcFps) {
      setState(() {
        _srcKbps = best;
        _srcCodec = bestCodec;
        _srcFps = maxFps;
      });
    }
  }

  CanvasRatio _canvasRatio = CanvasRatio.original;
  double _pxPerSec = 0;
  final _tlScroll = ScrollController();

  // 浮水印顯示範圍（時間軸秒）；_wmEnd null = 跟到結尾
  double _wmStart = 0;
  double? _wmEnd;

  /// 有沒有選取全域浮水印（跟 _sel 互斥，見上面）
  bool get _wmSel => _wmSelValue;
  set _wmSel(bool v) {
    _wmSelValue = v;
    if (v) _selValue = -1;
  }

  double get _wmEndEff {
    final e = (_wmEnd ?? _tl.duration).clamp(0.0, _tl.duration);
    // 空白專案剛進來時時間軸長度是 0。那時候碰過浮水印，會把
    // 「跟到結尾」(null) 寫死成 0 長度，之後匯入素材也拉不開。
    // 修剪本身有 0.3 秒的最短限制，所以「終點不大於起點」只可能是
    // 這樣來的壞狀態，一律當成跟到結尾
    return e <= _wmStart ? _tl.duration : e;
  }

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
    // _lifting 只在素材「真的被拖動」時才是 true（見 timeline 的 armed 判定）。
    // 手指剛按上去還沒移動就不算，這樣第二指下來仍然轉得成縮放——
    // 不然按著素材再放第二指，會變成一路把素材拖走
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

  /// 軌號被重編之後，把靜音狀態一起搬過去。
  /// 不搬的話靜音會落在別軌，而且匯出時是照這個集合把音量寫成 0，
  /// 成品的聲音會跟預覽不一樣
  void _remapMuted(Map<int, int> map) {
    if (_mutedTracks.isEmpty || map.isEmpty) return;
    final moved = _mutedTracks.map((k) => map[k] ?? k).toSet();
    _mutedTracks
      ..clear()
      ..addAll(moved);
  }

  // ===== 復原 / 重做 =====
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  /// Logo base64 動輒好幾 MB，每次快照都整份 jsonEncode 會讓
  /// 拖曳起手卡一下；池子只存字串參照，快照裡留編號
  final List<String> _wmB64Pool = [];

  String _wmB64Token(String b64) {
    for (var i = 0; i < _wmB64Pool.length; i++) {
      if (identical(_wmB64Pool[i], b64)) return '@@b64:$i';
    }
    _wmB64Pool.add(b64);
    return '@@b64:${_wmB64Pool.length - 1}';
  }

  String _snapshot() {
    final wm = _settings.toJson();
    // 一組浮水印可以有很多張圖片，每一張都要換成池子編號
    for (final lg in ((wm['logos'] as List?) ?? const [])) {
      if (lg is Map && lg['b64'] is String) {
        lg['b64'] = _wmB64Token(lg['b64'] as String);
      }
    }
    return jsonEncode({
      'clips': [for (final c in _tl.clips) c.toJson()],
      // 來源也要進快照：浮水印／文字素材的樣式（wmStyle/textStyle/name）
      // 存在來源上，漏掉的話那些編輯按復原根本退不回去
      'sources': [for (final s in _tl.sources) s.toJson()],
      'wmStart': _wmStart,
      'wmEnd': _wmEnd,
      'wm': wm,
    });
  }

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
    // 這裡不重組合成。
    //
    // _pushUndo 是「每個破壞性操作前」都會呼叫的——拖曳片段的過程中
    // 一路呼叫，重組就一路發生（使用者的紀錄裡「合成播放器就緒」出現
    // 二十幾次）。每次重組都要換掉 AVPlayerItem，畫面會抖、位置會跳。
    // 交給 _saveDraft 那條併批的路：停手 900ms 之後比對指紋，
    // 值真的變了才重組一次
    _undoStack.add(_snapshot());
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    _redoStack.clear();
    _saveDraft();
  }

  void _restoreSnapshot(String snap) {
    final j = jsonDecode(snap) as Map<String, dynamic>;
    // 快照裡的 Logo 是池子編號，先換回真正的 base64
    final wmJ = j['wm'];
    if (wmJ is Map) {
      for (final lg in ((wmJ['logos'] as List?) ?? const [])) {
        if (lg is! Map || lg['b64'] is! String) continue;
        final v = lg['b64'] as String;
        if (v.startsWith('@@b64:')) {
          final i = int.tryParse(v.substring(6)) ?? -1;
          lg['b64'] = (i >= 0 && i < _wmB64Pool.length) ? _wmB64Pool[i] : null;
        }
      }
    }
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
        _settings.copyMarksFrom(wm);
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
    // 有工作檔就播工作檔：1080p SDR 一顆解碼器的成本只有 4K HDR 的
    // 幾分之一，三段同時活著也不會掉格
    final ctrl = makeVideoController(src.previewPath);
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
      'resV': 2, // 解析度選項的語意版本（見 _loadDraft 的換算）
      'quality': _quality.index,
      'qualityAuto': _qualityAuto,
      'wm': _settings.toJson(),
      'wmStart': _wmStart,
      'wmEnd': _wmEnd,
      'extraTracks': _extraBlankTracks,
    };
  }

  Timer? _draftSaveTimer;

  /// 存草稿（併批）：每個編輯動作、每次拖曳起手都會呼叫，
  /// 而整包 jsonEncode（含 Logo base64）在主執行緒要好幾毫秒，
  /// 連續操作時會吃掉幀——延後一拍、把連續呼叫併成一次真正的寫入
  Future<void> _saveDraft() async {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 900), () {
      _saveDraftNow();
      // 合成把 trim、變速、淡入淡出、縮放位移都烘在裡面，而這些值在
      // 拖曳過程中連續變——_pushUndo 只在起手時重組一次，結束時的最終
      // 值會漏掉。跟存草稿共用同一個併批節奏：停手後比對指紋，變了才重組
      _compRefreshIfChanged();
    });
  }

  /// 合成播放器烘進去的那些值的指紋（變了就要重組）。
  ///
  /// [withPaths] 分兩種用途：帶路徑的是「這份合成還對不對」，不帶的是
  /// 「使用者改了什麼」。要分開是因為工作檔一支接一支轉好，路徑會連著
  /// 變好幾次——那種變化得等全部轉完再一次換，每變一次就重烘的話
  /// 畫面會重載好幾次
  String _compSig({bool withPaths = true}) => [
    for (final c in _tl.clips)
      if (_tl.sourceOf(c).isVideo)
        '${withPaths ? _tl.sourceOf(c).previewPath : c.sourceIndex}|'
            '${c.trimStart}|${c.trimEnd}|'
            '${c.offset}|${c.volume}|${c.speed}|${c.fadeIn}|${c.fadeOut}|'
            // 調色也要記：有調色就得退回舊路徑（系統影片圖層疊不上
            // Flutter 的濾鏡），不記的話調了色也不會換引擎
            '${c.scale}|${c.px}|${c.py}|${c.reverse}|${c.color.hasColor}',
  ].join(';');

  String? _lastCompSig;
  String? _lastCompEditSig;

  void _compRefreshIfChanged() {
    if (!Diag.compPlayer.value || !mounted) return;
    final sig = _compSig();
    if (sig == _lastCompSig) return;
    // 使用者真的改了東西＝立刻重烘；只有素材路徑變（某一支工作檔轉好了）
    // ＝等全部轉完再一次換
    final editSig = _compSig(withPaths: false);
    if (editSig == _lastCompEditSig && !_allWorkFilesReady) return;
    _lastCompSig = sig;
    _lastCompEditSig = editSig;
    _compDirty = true;
    unawaited(_ensureComp());
  }

  Future<void> _saveDraftNow() async {
    // Web 也存：同一次瀏覽內可以繼續剪；重新整理後素材連結會失效，
    // 還原時由 _loadDraft 剔除並提示
    final map = _projectJson();
    // 編碼丟到背景執行緒：整包 JSON 含 Logo 的 base64，在主執行緒要好
    // 幾毫秒——而存草稿是每個編輯動作都會走到的，那幾毫秒正好落在使用者
    // 手指還在動的時候。Web 沒有背景執行緒，照原本的做
    String text;
    try {
      text = kIsWeb ? jsonEncode(map) : await compute(jsonEncode, map);
    } catch (_) {
      text = jsonEncode(map);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kDraftKey, text);
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
    // 解析度選項從「原始／4K／1080P」改成畫質等級後索引語意變了。
    // 舊草稿沒有 resV 標記，照舊語意換算過來（4K 當年算出來就等於原始），
    // 不換的話使用者的草稿會被悄悄降成更低的畫質
    final rawRes = (j['res'] ?? 0) as int;
    final resIdx = ((j['resV'] ?? 1) as int) >= 2
        ? rawRes
        : switch (rawRes) {
            1 => 0, // 4K → 最高畫質
            2 => 1, // 1080P → 高畫質
            _ => 0,
          };
    _resolution =
        ExportResolution.values[resIdx % ExportResolution.values.length];
    _quality = ExportQuality
        .values[((j['quality'] ?? 0) as int) % ExportQuality.values.length];
    // 舊草稿沒這個欄位：當成使用者選過，不要回頭改動他存好的設定
    _qualityAuto = (j['qualityAuto'] ?? false) as bool;
    if (j['wm'] != null) {
      final wm = WatermarkSettings.fromJson(
        Map<String, dynamic>.from(j['wm'] as Map),
      );
      _settings.copyMarksFrom(wm);
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
        } else {
          // Web 也要剔除：那邊讀不回位元組（blob 連結活不過重新整理），
          // 留著會變成「時間軸看得到、畫面上卻不存在」的幽靈素材——
          // 預覽畫不出來，也就點不到、選不了、刪不掉
          deadSources.add(i);
        }
      } else if (!kIsWeb && !await fileExists(s.path)) {
        // Web 沒辦法驗檔案還在不在，直接嘗試載入
        deadSources.add(i);
      } else if (s.kind == ClipKind.video) {
        // 草稿裡記的工作檔可能已經被清掉（或是舊草稿根本沒有），
        // 沒有就先用原檔，等下面的 _prepAllWorkFiles 在背景補
        if (s.workPath != null && !await fileExists(s.workPath!)) {
          s.workPath = null;
        }
        _thumbStrip(s.previewPath, s.duration).then((t) {
          if (mounted && t.isNotEmpty) setState(() => _thumbs[i] = t);
        });
        _ensureScrubSlots(i, s.duration);
      }
    }
    _droppedOnLoad = _tl.clips
        .where((c) => deadSources.contains(c.sourceIndex))
        .length;
    _tl.clips.removeWhere((c) => deadSources.contains(c.sourceIndex));
    for (final c in _tl.clips) {
      _ensureCtrlFor(c);
    }
    // 簡易倒轉的片段（沒轉成倒轉檔的那種）預覽只能吃密集快取幀，
    // 那幾支素材照舊整條抽；其他素材都改成滑到哪抽到哪
    for (final i in {
      for (final c in _tl.clips)
        if (c.reverse) c.sourceIndex,
    }) {
      final s = _tl.sources[i];
      _makeScrubCache(i, s.previewPath, s.duration);
    }
    // 沒有工作檔的素材在背景補上（進場不等它）
    unawaited(_prepAllWorkFiles());
    unawaited(_ensureComp());
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
    // 量「誰在卡」：UI 執行緒、合成執行緒、還是影片本身。
    // 這三種的處理方式完全不同，沒有數字就只能猜
    Diag.watchFrames();
    // 音訊 session 先啟用起來：不先付這筆錢的話，第一次按播放時
    // iOS 會在那當下跟音訊伺服器協商（典型 100~300ms），
    // 使用者感覺到的就是「按下去要等一下畫面才動」
    unawaited(Diag.activateAudio());
    _ticker = createTicker(_onTick);
    _tlScroll.addListener(_onTimelineScroll);
    _loadMosaicShader();
    // 上次做到一半就被系統收掉的話講一聲——最常見的是匯出時記憶體
    // 撞上限，使用者只看到 App 消失，不講他不會知道發生了什麼事
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || Diag.crumbFromLastRun == null) return;
      showHint(
        context,
        Diag.lastRunDiedExporting
            ? '上次匯出被系統中斷了（記憶體不足）。長按標題可以看診斷'
            : '上次沒有正常結束。長按標題可以看診斷',
        duration: const Duration(seconds: 6),
      );
    });
    _loadSnapPref(); // 記住上次磁吸開還關
    _loadTidyPref(); // 記住上次自動整理開還關
    if (widget.draft != null) {
      _loadDraft(widget.draft!).then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        unawaited(_measureSrcKbps());
        if (_droppedOnLoad > 0) {
          showHint(
            context,
            '有 $_droppedOnLoad 段素材已找不到，已從專案中移除',
            duration: const Duration(seconds: 5),
          );
        }
      });
    } else if (widget.blank) {
      // 空白專案：沒有素材可載，直接開工。
      // 不跳提示——空軌上就寫著「點我加入…」而且點下去就會開，
      // 再彈一句浮在上面只是擋住那行字
      _ready = true;
    } else {
      // 一支或一整批都走同一條路：照順序接在第一軌上。
      // 每一支進來就先能播（工作檔在背景備），不會卡在載入畫面
      final list = widget.videoPaths ?? [widget.videoPath!];
      () async {
        for (final path in list) {
          try {
            await _importVideoFromPath(path, track: 0);
          } catch (_) {
            // 某一支讀不進來不該讓整批進不去
          }
          if (!mounted) return;
          setState(() => _ready = true);
        }
        _saveDraft();
      }();
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
    if (_compOn) {
      // 合成播放器接手時，畫面直接由它出：手指每動一次就把最新位置送
      // 過去（原生端只追最新的那個目標，不會排隊塞車），停手再補一發
      // 精準的。不抽幀、不疊快取幀、不動底下那幾顆播放器——那些在這條
      // 路徑上全是跟合成播放器搶解碼器的多餘工作
      _compSeek();
      _scrubEndTimer?.cancel();
      _scrubEndTimer = Timer(const Duration(milliseconds: 220), _tryEndScrub);
      _prepEscapeTimer?.cancel();
    _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(
        const Duration(milliseconds: 120),
        () => _compSeek(exact: true),
      );
      return;
    }
    _requestScrubFrames();
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

  /// 自動整理開關（記住上次的選擇）。開著的時候，只要有編輯讓某一軌
  /// 出現空隙（修剪變短、刪片段、改速度），就自動把後面的素材接上來
  bool _autoTidy = false;
  static const _kTidyPrefKey = 'timeline_auto_tidy';

  Future<void> _loadTidyPref() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_kTidyPrefKey) ?? false;
    if (mounted && v != _autoTidy) setState(() => _autoTidy = v);
  }

  Future<void> _toggleAutoTidy() async {
    setState(() => _autoTidy = !_autoTidy);
    if (_autoTidy) {
      // 打開的當下就先整理一次：使用者按這顆多半是「現在就想接齊」，
      // 讓他還要再做一次編輯才看到效果很怪
      _closeGaps();
    } else {
      showHint(context, '自動整理已關閉');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTidyPrefKey, _autoTidy);
  }

  /// 一次編輯做完之後補空隙（自動整理開著才做）。
  ///
  /// 不另外拍 undo：這是跟著剛才那次編輯一起發生的，按一次上一步
  /// 應該連同整理一起退回去，而不是退成「整理前但已經剪短」的半套狀態
  void _autoTidyIfOn({int? track}) {
    if (!_autoTidy || _tl.clips.isEmpty) return;
    final t =
        track ?? _selClip?.track ?? (_selTrack >= 0 ? _selTrack : null);
    final removed = _tl.closeGaps(track: t);
    if (removed < 0.001) return;
    setState(() {});
    _resyncPlayback();
    _saveDraft();
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
    final snapped = _tl.snapTime(t, _pxPerSec, radiusPx: 12);
    return (snapped - t).abs() > 0.0005 ? snapped : null;
  }

  /// 上一發 seek 還在解碼中就不發新的：
  /// seek 疊 seek 會在解碼器裡排隊，是拖曳卡頓的主因
  bool _seekInFlight = false;

  void _compSeek({bool exact = false}) {
    if (_compOn && !_playing) {
      unawaited(_comp!.seek(_position, exact: exact));
    }
  }

  void _scrubSeek({bool force = false}) {
    // force＝使用者停手了，這一發才需要對準那一格
    _compSeek(exact: force);
    // 合成播放器接手時，畫面就是它一顆在出：底下那三顆 4K 播放器不用
    // 也不該跟著 seek。它們跟著動的話是三份 4K 解碼在跟合成播放器搶
    // 解碼器，拖曳當然追不上
    if (_compOn) return;
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

    _thumbStrip(path, dur).then((t) {
      if (mounted && t.isNotEmpty) setState(() => _thumbs[srcIndex] = t);
    });
    _ensureScrubSlots(srcIndex, dur);
    unawaited(_measureSrcKbps());
    // 排進轉檔佇列（遮罩會蓋著等它做完）
    _enqueuePrep(srcIndex);
  }

  // ===== 素材工作檔 =====
  //
  // iPhone 預設錄 4K HLG。拿原檔直接用的話，每個片段都要養一顆 4K HDR
  // 解碼器（三段就是三顆同時活著，預熱時還會有兩顆在解），拖曳抽幀也是
  // 從 4K 解起——那就是「播放超 LAG、左右滑動不順」的來源。
  //
  // 解法是剪輯 App 的標準做法：進場先用原檔（不能讓使用者等），背景用
  // 系統的硬體管線轉一份 1080p SDR 的工作檔，轉好了再換過去。換過去之後
  // 播放、抽幀、縮圖都只碰 1080p SDR，而且顏色是系統轉的，跟匯出一致

  /// 正在備工作檔的素材（全部備完才把合成換成工作檔版）
  final Set<int> _prepping = {};

  /// 還沒開始備的素材，以及「這一批總共幾支、做完幾支」。
  ///
  /// 使用者要的是「先等一下，然後進去就都好了」，不是「進去之後閃東
  /// 閃西」——所以轉檔排成一批做完，期間畫面上蓋一層遮罩擋住互動。
  /// 一支一支各自開跑的話，遮罩會閃三次，比等一次還煩
  final List<int> _prepQueue = [];
  bool _prepBusy = false;
  int _prepDone = 0;
  int _prepTotal = 0;

  /// 正在轉的每一支各做到哪（0~1），素材索引 → 進度。
  ///
  /// 沒有它的話百分比只會跳 33、67、100，三支素材的畫面上那個大數字
  /// 大半時間是停著的。同時可能有兩支在轉，所以是一張表不是一個值
  final Map<int, double> _prepCur = {};

  /// 這一刻的整體進度（0~1）
  double get _prepFraction {
    if (_prepTotal <= 0) return 0;
    final inFlight = _prepCur.values.fold(0.0, (a, b) => a + b);
    return ((_prepDone + inFlight) / _prepTotal).clamp(0.0, 1.0);
  }

  /// 使用者按了「先進去編輯」——遮罩收掉，轉檔繼續在背景跑
  bool _prepSkipped = false;

  /// 幾秒之後才給退路：一開始就給的話，正常的兩秒等待也會被當成卡住
  Timer? _prepEscapeTimer;
  bool _prepEscapeReady = false;

  /// 這一刻要不要蓋讀取遮罩
  bool get _prepGate => _prepBusy && !_prepSkipped;

  void _enqueuePrep(int srcIndex) {
    if (srcIndex < 0 || srcIndex >= _tl.sources.length) return;
    final src = _tl.sources[srcIndex];
    if (src.kind != ClipKind.video || src.workPath != null) return;
    if (_prepQueue.contains(srcIndex) || _prepping.contains(srcIndex)) return;
    _prepQueue.add(srcIndex);
    _prepTotal = _prepDone + _prepQueue.length + _prepping.length;
    unawaited(_drainPrep());
  }

  Future<void> _drainPrep() async {
    if (_prepBusy) return;
    if (!await MediaPrep.available) {
      _prepQueue.clear();
      return;
    }
    if (!mounted) return;
    setState(() {
      _prepBusy = true;
      _prepSkipped = false;
      _prepEscapeReady = false;
      _prepDone = 0;
      _prepCur.clear();
      _prepTotal = _prepQueue.length;
    });
    // 轉檔偶爾會卡在某一支（硬體編碼器被佔住、素材有問題）。這一頁擋著
    // 整個編輯器，沒有退路的話使用者只能關掉 App 重來
    _prepEscapeTimer?.cancel();
    _prepEscapeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _prepBusy) setState(() => _prepEscapeReady = true);
    });
    // 全部一起送出去，同時跑幾支由 MediaPrep 控（現在是兩支）。
    // 一支做完就送下一支進去，硬體編碼器不會有空檔。
    //
    // 外面這層 while 不能省：轉檔進行中還會有素材被排進來（多選匯入是
    // 一支一支加的），只撈一次的話那些會留在佇列裡沒人理——上一版就是
    // 這樣，五支素材只轉好一支，其他全程用 4K 原檔播
    while (_prepQueue.isNotEmpty && mounted) {
      final jobs = <Future<void>>[];
      while (_prepQueue.isNotEmpty) {
        final i = _prepQueue.removeAt(0);
        jobs.add(
          _prepWorkFile(i).then((_) {
            if (!mounted) return;
            setState(() {
              _prepDone++;
              _prepCur.remove(i);
            });
          }),
        );
      }
      await Future.wait(jobs);
      if (!mounted) return;
      // 這一批做完之後可能又進來新的，總數要跟著長
      setState(() => _prepTotal = _prepDone + _prepQueue.length);
    }
    if (!mounted) return;
    _prepEscapeTimer?.cancel();
    setState(() {
      _prepBusy = false;
      _prepEscapeReady = false;
      _prepCur.clear();
    });
    // 這時候才組合成：全部素材都是工作檔，方向與編碼一致，
    // 合成器不會被叫醒，而且之後不必再重烘一次
    _compDirty = true;
    unawaited(_ensureComp());
  }

  /// 影片素材是不是全部都有工作檔了。
  ///
  /// 不能用 _prepping.isEmpty 判斷：轉檔是一支接一支排隊做的，第一支
  /// 做完的瞬間第二支還沒進佇列，_prepping 是空的——上一版就是這樣
  /// 每轉好一支就重烘一次合成，畫面重載了三次
  bool get _allWorkFilesReady =>
      _tl.sources.every((s) => !s.isVideo || s.workPath != null);

  Future<void> _prepWorkFile(int srcIndex) async {
    if (srcIndex < 0 || srcIndex >= _tl.sources.length) return;
    final src = _tl.sources[srcIndex];
    if (src.kind != ClipKind.video || src.workPath != null) return;
    if (!await MediaPrep.available) return;
    if (!mounted) return;
    _prepping.add(srcIndex);
    // 進度只在讀取遮罩蓋著的時候收。那時候畫面上只有遮罩本身，
    // 重建一次很便宜；遮罩收掉之後就不再理它（以前那個回呼是每
    // 250ms 重建一次整頁編輯器）
    final made = await WorkFiles.ensure(
      src.path,
      onProgress: (v) {
        if (!mounted || !_prepBusy) return;
        setState(() => _prepCur[srcIndex] = v.clamp(0.0, 1.0));
      },
    );
    if (!mounted) return;
    _prepping.remove(srcIndex);
    _prepCur.remove(srcIndex);
    if (made == null || srcIndex >= _tl.sources.length) return;
    src.workPath = made;
    // 播放中絕對不換媒體。換播放器會 pause→重建→play，合成重組會換掉
    // AVPlayerItem——兩個都會把畫面重設回 seek 的位置，看起來就是
    // 「一進去點播放就跳回去」。真正的剪輯 App 不會在播放中抽換媒體，
    // 排到暫停後再一次做完
    _pendingSwaps.add(srcIndex);
    // 全部轉完才動合成：每好一支就重烘的話畫面會重載好幾次
    if (!_playing && _allWorkFilesReady) _flushPendingSwaps();
    _saveDraft();
  }

  /// 這份素材的播放器全部換成吃工作檔的新播放器
  /// 等著換成工作檔的素材（播放中先排隊，暫停後才換）
  final Set<int> _pendingSwaps = {};

  /// 播放中發生過、被推遲的合成重組
  bool _pendingCompRebuild = false;

  /// 沖洗中（_swapToWorkFile 內部會再呼叫一次 _pause，別讓它遞迴進來
  /// 重組第二次合成）
  bool _flushing = false;

  /// 暫停之後把排隊的媒體抽換一次做完
  void _flushPendingSwaps() {
    if (_playing || _flushing) return;
    _flushing = true;
    final todo = _pendingSwaps.toList();
    _pendingSwaps.clear();
    for (final i in todo) {
      if (i >= 0 && i < _tl.sources.length) _swapToWorkFile(i);
    }
    _flushing = false;
    // 全部素材都備好了才把合成換成工作檔版：每好一支就重組的話
    // 畫面會重載好幾次
    if (todo.isNotEmpty && _allWorkFilesReady) _pendingCompRebuild = true;
    if (_pendingCompRebuild) {
      _pendingCompRebuild = false;
      _compDirty = true;
      unawaited(_ensureComp());
    }
  }

  void _swapToWorkFile(int srcIndex) {
    final was = _playing;
    if (was) _pause();
    for (final c in _tl.clips) {
      if (c.sourceIndex != srcIndex) continue;
      _ctrls.remove(c.id)?.dispose();
      // 合成播放器接手時畫面不由這些播放器出，開回來只是白佔解碼資源
      if (!_compOn) _ensureCtrlFor(c);
    }
    _wasActive.clear();
    _preRolled.clear();
    _warmed.clear();
    // 抽幀快取是從原檔抽的，換素材之後要重抽（工作檔解得快得多）
    _scrubFrames.remove(srcIndex);
    _scrubDecoders.remove(srcIndex)?.dispose();
    _ensureScrubSlots(srcIndex, _tl.sources[srcIndex].duration);
    _thumbStrip(_tl.sources[srcIndex].previewPath, _tl.sources[srcIndex].duration)
        .then((t) {
      if (mounted && t.isNotEmpty) setState(() => _thumbs[srcIndex] = t);
    });
    if (mounted) setState(() {});
    _resyncPlayback();
    if (was) _play();
  }

  /// 讀草稿之後補做：草稿裡記的工作檔可能已經被清掉了
  Future<void> _prepAllWorkFiles() async {
    if (!await MediaPrep.available) return;
    for (var i = 0; i < _tl.sources.length; i++) {
      final src = _tl.sources[i];
      if (src.kind != ClipKind.video) continue;
      if (src.workPath != null && await fileExists(src.workPath!)) continue;
      src.workPath = null;
      _enqueuePrep(i);
      if (!mounted) return;
    }
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

  /// 時間軸縮圖帶：先問系統解碼器（顏色跟播放一致、還會自動轉正），
  /// 拿不到才退 FFmpeg。拖曳預覽早就走原生了，縮圖帶不跟上的話
  /// 就會出現「預覽顏色對、時間軸顏色錯」的分裂
  Future<List<Uint8List>> _thumbStrip(String path, double dur) async {
    if (!kIsWeb) {
      final t = await nativeStrip(path, dur, 10, maxH: 200);
      if (t.isNotEmpty) return t;
    }
    return engine.makeThumbnails(path, dur, 10, fastDecode: true);
  }

  /// 配好某個素材的快取幀格子（不抽任何幀）。
  /// 滑動時由原生解碼器把滑到的那幾格按需填進來（_nfPump）；
  /// 只有簡易倒轉需要整條密集抽（_makeScrubCache）
  void _ensureScrubSlots(int srcIndex, double dur) {
    if (dur <= 0 || _scrubFrames.containsKey(srcIndex)) return;
    final n = (dur * _scrubFps).ceil().clamp(4, 2400);
    _scrubFrames[srcIndex] = List<Uint8List?>.filled(n, null);
  }

  /// 按需抽幀：滑到哪、跟系統的硬體解碼器要哪一格。
  /// 一次只飛一個請求，永遠抽「最新想要的」那格——手指比解碼快時，
  /// 中間滑過的格子直接跳過，不排隊（排了也只是顯示過期的畫面）
  final List<({int src, int fi, double t, String path})> _nfWant = [];
  bool _nfBusy = false;

  /// 每個素材「最近抽到的一格」。滑動顯示以它為底：格子快取是
  /// 慢慢累積的，手指快的時候沿路都是空格，等格子＝畫面卡住不動；
  /// 最新一格永遠跟著手指（頂多慢一個解碼的時間）
  final Map<int, Uint8List> _nfLatest = {};

  void _requestScrubFrames() {
    if (kIsWeb || !Diag.scrubPrefetch.value) return;
    // 播放中不要跟播放器搶解碼器：抽幀是給拖曳用的，
    // 播放的時候一格都不需要
    if (_playing) {
      Diag.count('播放中還在抽幀（已擋下）');
      return;
    }
    _nfWant.clear();
    for (final c in _tl.videosAt(_position)) {
      if (c.reverse) continue; // 簡易倒轉走密集快取
      final src = _tl.sourceOf(c);
      if (src.duration <= 0) continue;
      _ensureScrubSlots(c.sourceIndex, src.duration);
      final slots = _scrubFrames[c.sourceIndex]!;
      final t = c.sourceTimeAt(_position);
      final fi = (t / src.duration * slots.length).floor().clamp(
        0,
        slots.length - 1,
      );
      if (slots[fi] != null) continue;
      _nfWant.add((src: c.sourceIndex, fi: fi, t: t, path: src.previewPath));
    }
    unawaited(_nfPump());
  }

  Future<void> _nfPump() async {
    if (_nfBusy) return;
    _nfBusy = true;
    try {
      while (_nfWant.isNotEmpty && mounted) {
        final w = _nfWant.removeLast();
        final sw = Stopwatch()..start();
        final bytes = await nativeFrameAt(w.path, w.t, maxH: _scrubLongSide);
        PlaybackTrace.instance.log(
          '原生抽幀 ${sw.elapsedMilliseconds}ms（素材 ${w.src} 格 ${w.fi}）'
          '${bytes == null ? '＝拿不到' : ''}',
        );
        if (!mounted) return;
        final slots = _scrubFrames[w.src];
        if (bytes != null) {
          _nfLatest[w.src] = bytes;
          if (slots != null && w.fi < slots.length && slots[w.fi] == null) {
            slots[w.fi] = bytes;
          }
          // 主動重繪：手指停住時，剛抽好的幀才會立刻出現
          if (_scrubbing && mounted) setState(() {});
        }
      }
    } finally {
      _nfBusy = false;
    }
  }

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
      PlaybackTrace.instance.log('開始背景抽幀（素材 $srcIndex，$count 格）');
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
        PlaybackTrace.instance.log('背景抽幀結束（素材 $srcIndex）');
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
      // 格子沒鋪到沒關係，有「最新一格」一樣能顯示——判成沒蓋到
      // 的話會退回「每個手勢事件都去 seek 播放器」，那才是滑動卡的
      // 主因（4K HDR 的精準 seek 一次幾百毫秒）
      if (!found && _nfLatest[c.sourceIndex] == null) return false;
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

  /// 這個檔是影片嗎。優先看 mimeType，拿不到就退回看副檔名
  ///（相簿匯出的檔案不一定帶 mime）
  static bool _isVideoFile(XFile f) {
    final mime = f.mimeType;
    if (mime != null && mime.isNotEmpty) return mime.startsWith('video/');
    final ext = f.name.toLowerCase().split('.').last;
    return const {
      'mp4',
      'mov',
      'm4v',
      'avi',
      'mkv',
      'webm',
      '3gp',
      'ts',
      'mts',
    }.contains(ext);
  }

  /// 一次選多部時問：接成一段，還是各自一軌疊起來。
  /// 回傳 true＝同一軌、false＝各自一軌、null＝取消
  Future<bool?> _askSameTrack(int n) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('加入 $n 部影片'),
      contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      content: SizedBox(
        width: 270,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            optionRow(
  context: context,
              title: '接在同一軌',
              subtitle: '照選取順序頭尾相接，變成一段長影片',
              selected: false,
              first: true,
              onTap: () => Navigator.pop(context, true),
            ),
            optionRow(
  context: context,
              title: '各自一軌',
              subtitle: '每個影片開一個新軌道',
              selected: false,
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _pickVideo(int track) async {
    // 相簿沒有「只挑影片、而且可以多選」的介面，只能用混合媒體的
    // 多選器再自己濾掉照片——照片有自己的入口（而且長度規則不一樣）
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty || !mounted) return;
    final vids = picked.where(_isVideoFile).toList();
    if (vids.isEmpty) {
      showHint(context, '這裡只能加影片，照片請用「圖片」那一項');
      return;
    }

    var sameTrack = true;
    if (vids.length > 1) {
      final ans = await _askSameTrack(vids.length);
      if (ans == null || !mounted) return; // 取消
      sameTrack = ans;
    }

    _pause();
    _pushUndo();
    for (var i = 0; i < vids.length; i++) {
      // 各自一軌時，第二部以後每部都開一條新的空軌；
      // usedTracks 每加一部就長一格，所以這裡每輪重新算
      final t = (sameTrack || i == 0) ? track : _tl.usedTracks;
      await _importVideoFromPath(vids[i].path, track: t, name: vids[i].name);
      if (!mounted) return;
    }
    setState(() {});
    // 挑到照片的那幾個直接跳過，但要講一聲，不然會以為漏加了
    final skipped = picked.length - vids.length;
    if (skipped > 0) {
      showHint(context, '有 $skipped 個不是影片，已略過');
    }
    _saveDraft(); // 加完立刻落草稿
  }

  Future<void> _pickAudio(int track) async {
    // 音樂來源：音樂檔，或從自己的影片提取聲音（只取音軌）
    final fromVideo = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
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
      unawaited(_play()); // 影片跟著跑，才能對著畫面講
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

  /// 素材選單。
  ///
  /// 八個項目分成三類：自己做的覆蓋物、從裝置匯入的檔案、軌道相關。
  /// 不分組的話八列長得一模一樣，看不出它們其實不是同一種東西
  Future<_AddKind?> _askKind({String? title}) {
    Widget item(
      BuildContext context,
      IconData icon,
      String label,
      _AddKind kind,
    ) {
      return InkWell(
        onTap: () => Navigator.pop(context, kind),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 20, color: kAmber),
              const SizedBox(width: 15),
              Text(label, style: const TextStyle(fontSize: 13.5, color: kText)),
            ],
          ),
        ),
      );
    }

    Widget group(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 3),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          letterSpacing: 1.4,
          color: kTextDim,
        ),
      ),
    );

    return showModalBottomSheet<_AddKind>(
      context: context,
      showDragHandle: true,
      // 分組之後比不分組更高，預設的 9/16 會塞不下（最後一項會被切掉）
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              group('加在畫面上'),
              item(context, Icons.title, '文字', _AddKind.text),
              item(context, Icons.branding_watermark, '浮水印', _AddKind.wm),
              item(context, Icons.blur_on, '馬賽克', _AddKind.mosaic),
              group('從裝置匯入'),
              item(context, Icons.videocam_outlined, '影片', _AddKind.video),
              item(context, Icons.image_outlined, '圖片', _AddKind.image),
              item(context, Icons.music_note, '音樂', _AddKind.audio),
              group('其他'),
              item(context, Icons.mic, '錄旁白', _AddKind.record),
              item(context, Icons.playlist_add, '空白軌道', _AddKind.blankTrack),
              const SizedBox(height: 10),
            ],
          ),
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
        // 多畫一條空軌，之後可以貼上或拖片段進去。
        // 選取直接落在新那條上：原本只設了 _selTrack，但片段的選取優先
        // 度比它高（見 _dispatchAdd 的 track 判斷），舊的選取還在的話
        // 「加素材／貼上」會跑回舊軌道，剛開的那條等於白開
        setState(() {
          _extraBlankTracks++;
          _sel = -1;
          _wmSel = false;
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
    // 可一次多選：選多張就自動排成連續的幻燈片（每張 3 秒、頭尾相接），
    // 想做「多張圖片串成影片」不用一張一張加
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) return;
    _pause();
    _pushUndo();
    var at = _position;
    var firstId = -1;
    for (final img in picked) {
      final bytes = await img.readAsBytes();
      // 解出圖片尺寸，之後縮放定位要用
      var imgW = 0, imgH = 0;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        imgW = frame.image.width;
        imgH = frame.image.height;
        frame.image.dispose();
      } catch (_) {}
      final srcIndex = _tl.sources.length;
      _tl.sources.add(
        MediaSource(
          path: img.path,
          name: img.name,
          kind: ClipKind.image,
          duration: 3600, // 靜態素材，長度隨便拉
          w: imgW,
          h: imgH,
        ),
      );
      _thumbs[srcIndex] = [bytes];
      final len = picked.length == 1 ? 4.0 : 3.0;
      final clip = TimelineClip(
        id: _tl.nextId(),
        sourceIndex: srcIndex,
        trimStart: 0,
        trimEnd: len,
        offset: at,
        track: track,
      );
      if (firstId == -1) firstId = clip.id;
      _tl.clips.add(clip);
      at += len;
    }
    setState(() => _sel = firstId);
    _resyncPlayback();
    _saveDraft(); // 加完立刻落草稿
    if (picked.length > 1 && mounted) {
      showHint(context, '已加入 ${picked.length} 張圖片，每張 3 秒頭尾相接');
    }
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
      showDragHandle: true,
      isScrollControlled: true,
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
                  width: kSliderLabelW,
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
                SizedBox(
                  width: kSliderValueW,
                  child: Text(
                    '${(v * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: kTextDim),
                  ),
                ),
              ],
            ),
          );

          Future<void> pickC(
            Color initial,
            void Function(int argb) apply,
          ) async {
            final picked = await pickColor(context, initial);
            final ok = picked != null;
            final color = Color(picked ?? 0);
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
                            final picked = await pickColor(context, st.color);
                            final ok = picked != null;
                            final color = Color(picked ?? 0);
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
                            width: kSliderLabelW,
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
                    // 設定面板裡的「選項」一律白框白字＋亮底
                    decoration: BoxDecoration(
                      color: on ? kPanelHi : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: on ? kAmber : kClipBorder,
                        width: on ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                        color: kText,
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
                        width: kSliderLabelW,
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
                        width: kSliderLabelW,
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
                          width: kSliderLabelW,
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
                          width: kSliderLabelW,
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
                            width: kSliderLabelW,
                            child: Text(
                              '柔邊',
                              style: TextStyle(fontSize: 12, color: kTextDim),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: st.feather,
                              onChanged: (v) => change(() => st.feather = v),
                            ),
                          ),
                          SizedBox(
                            width: kSliderLabelW,
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
                              final picked = await pickColor(
                                context,
                                Color(st.color),
                              );
                              final ok = picked != null;
                              final color = Color(picked ?? 0);
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
                                border: Border.all(color: kBorder, width: 1.5),
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
    PlaybackTrace.instance.tick(dt);
    if (dt > 0.05) Diag.count('掉格');
    // 時間軸位置以原速計；播放速度反映在實際前進速率上
    _position += dt * _speed;
    if (_position >= _tl.duration) {
      _position = _tl.duration;
      _pause();
    }
    // 合成播放器是唯一的時鐘來源：位置以它為準，Dart 這邊只在兩次
    // 回報之間補間。原本的做法是 App 自己算時間再回頭校正播放器，
    // 那個校正每次都會讓畫面停一下
    if (_compOn) {
      _syncFromComp();
      return;
    }
    _syncMedia();
    _followPlayhead();
    // 不做 setState：位置相關 UI 由 _posVN 各自小範圍重繪
  }

  /// 自動排查：依序把每個可疑的東西關掉各播一輪，最後直接說是哪個。
  ///
  /// 一輪一個假設地問使用者，一次來回就是一天。這裡把四種設定一次跑完，
  /// 每一輪都在同一支專案、同一段時間上量同一組數字，最後比出來——
  /// 唯一可靠的比較方式是「同一支手機、同一個當下、只差一個變因」
  bool _selfTesting = false;

  /// 上一次自動排查的結論（複製報告時一起帶出去）
  String? _selfTestResult;

  Future<String> _runSelfTest() async {
    if (_tl.clips.isEmpty) return '時間軸是空的，先放點素材再測';
    final was = (
      Diag.preheat.value,
      Diag.driftFix.value,
      Diag.scrubPrefetch.value,
      Diag.singlePlayer.value,
    );
    _selfTesting = true;
    await Diag.readDeviceState();

    // 每一輪播幾秒：太短量不到交界，太長使用者會等到不耐煩
    final dur = math.min(8.0, math.max(3.0, _tl.duration));
    final rounds =
        <({String name, bool pre, bool drift, bool fetch, bool single})>[
          (
            name: '現況（全開）',
            pre: true,
            drift: true,
            fetch: true,
            single: false,
          ),
          (
            name: '關掉交界預熱',
            pre: false,
            drift: true,
            fetch: true,
            single: false,
          ),
          (
            name: '關掉脫節校正',
            pre: true,
            drift: false,
            fetch: true,
            single: false,
          ),
          (
            name: '三個都關',
            pre: false,
            drift: false,
            fetch: false,
            single: false,
          ),
          (
            name: '只養一顆播放器',
            pre: false,
            drift: false,
            fetch: false,
            single: true,
          ),
        ];
    final results =
        <({String name, int stalls, int samples, int jankB, int jankR})>[];

    for (final r in rounds) {
      Diag.preheat.value = r.pre;
      Diag.driftFix.value = r.drift;
      Diag.scrubPrefetch.value = r.fetch;
      Diag.singlePlayer.value = r.single;
      _pause();
      setState(() => _position = 0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final before = Diag.snapshot();
      await _play();
      await Future<void>.delayed(
        Duration(milliseconds: (dur * 1000).round()),
      );
      _pause();
      final d = Diag.since(before);
      results.add((
        name: r.name,
        stalls: d.stalls,
        samples: d.samples,
        jankB: d.jankB,
        jankR: d.jankR,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    Diag.preheat.value = was.$1;
    Diag.driftFix.value = was.$2;
    Diag.scrubPrefetch.value = was.$3;
    Diag.singlePlayer.value = was.$4;
    _selfTesting = false;
    if (!mounted) return '（已離開畫面）';
    setState(() => _position = 0);

    // 結論：拿「影格落後的比例」比，比不出來就看是不是整台機器都在慢
    final b = StringBuffer()..writeln('=== 自動排查 ===');
    b.writeln('每輪播 ${dur.toStringAsFixed(0)} 秒，同一段素材');
    double rate(({String name, int stalls, int samples, int jankB, int jankR}) r) =>
        r.samples == 0 ? 0 : r.stalls / r.samples;
    for (final r in results) {
      b.writeln(
        '  ${r.name}：影格落後 ${r.stalls}/${r.samples} 次'
        '（${(rate(r) * 100).round()}%）'
        '／UI 超時 ${r.jankB}／合成超時 ${r.jankR}',
      );
    }
    final base = results.first;
    final best = results.reduce((a, c) => rate(c) < rate(a) ? c : a);
    b.writeln('--- 結論 ---');
    if (base.samples == 0) {
      b.writeln('沒量到東西（可能太短或沒播起來），再測一次');
    } else if (rate(base) < 0.08) {
      b.writeln(
        '這一輪播放本身是順的（落後 ${(rate(base) * 100).round()}%）。'
        '如果你看畫面還是覺得卡，那不是影格沒送上來的問題，'
        '請連同「裝置狀態」與「畫面」兩段一起回報',
      );
    } else if (identical(best, base) ||
        rate(best) > rate(base) * 0.6) {
      b.writeln(
        '關掉哪一個都沒有明顯變好（最好的一輪還有 '
        '${(rate(best) * 100).round()}%）——'
        '問題不在這三個機制，而在播放引擎或裝置本身。'
        '${Diag.thermal.contains('過熱') ? '注意：裝置正在過熱降頻，先讓它涼下來再測一次。' : ''}'
        '下一步請用診斷面板裡的「純播放測試」比原檔與工作檔',
      );
    } else {
      b.writeln(
        '「${best.name}」明顯比較順（'
        '${(rate(base) * 100).round()}% → ${(rate(best) * 100).round()}%），'
        '元凶就是被關掉的那個機制',
      );
    }
    _selfTestResult = b.toString();
    return _selfTestResult!;
  }

  // ===== 合成播放器 =====
  //
  // 整條時間軸組成一份 AVComposition 交給系統的一顆播放器。條件不符
  // （子母畫面、變速、倒轉、縮放位移、還沒轉好工作檔）就退回原本
  // 「一片段一顆播放器」的路徑——硬塞的話畫面會對不上，比卡頓更難查

  CompPlayer? _comp;
  String? _compWhyNot;

  /// 時間軸改過就要重組（換素材、剪過、搬過都算）
  bool _compDirty = true;

  /// 合成播放器不在了（關掉、資格不符、組不起來）就要把逐片段播放器
  /// 開回來。
  ///
  /// 合成接手時那些播放器是被主動放掉的（見 _trimPlayers），沒人開回來
  /// 的話畫面上就只剩浮水印——使用者說的「按下切割後預覽黑掉，只剩下
  /// 浮水印」正是這個：合成組不起來、舊的又早就沒了
  void _restoreClipPlayers() {
    for (final c in _tl.clips) {
      _ensureCtrlFor(c);
    }
    _resyncPlayback();
    if (mounted) setState(() {});
  }

  Future<void> _ensureComp() async {
    if (!Diag.compPlayer.value) {
      if (_comp != null) {
        await _comp!.dispose();
        if (mounted) setState(() => _comp = null);
        _restoreClipPlayers();
      }
      return;
    }
    if (_comp != null && !_compDirty) return;
    // 播放中一律不動合成：重組＝換掉 AVPlayerItem＝畫面重設回 seek 的
    // 位置；而就算是第一次組好，接手的那一刻畫面也會從舊圖層切到合成
    // 圖層，合成那顆卻還沒開始播。兩種都是「一進去點播放就跳」。
    // 排到暫停之後再做
    if (_playing) {
      _pendingCompRebuild = true;
      return;
    }
    final why = CompPlayer.whyNot(_tl);
    _compWhyNot = why;
    if (why != null) {
      Diag.note('合成播放器用不了：$why');
      if (_comp != null) {
        await _comp!.dispose();
        if (mounted) setState(() => _comp = null);
      }
      _restoreClipPlayers();
      return;
    }
    // 用系統影片圖層顯示時不要另外出一份材質：那份沒有人看，
    // 卻是每一格都在複製一張 4K 畫面，等於跟解碼搶頻寬
    final made = await CompPlayer.build(_tl, texture: !Diag.playerLayer.value);
    _compDirty = false;
    if (!mounted) {
      await made?.dispose();
      return;
    }
    if (made == null) {
      Diag.note(
        '合成播放器組不起來：${CompPlayer.lastError ?? '沒有回報原因'}（退回原本的路徑）',
      );
      // 舊的那顆不能留著：畫面上的影片圖層已經指到別處，繼續當它還在
      // 就是一片黑。放掉它，讓預覽退回逐片段播放器那條路
      if (_comp != null) {
        await _comp!.dispose();
        if (mounted) setState(() => _comp = null);
      }
      _restoreClipPlayers();
      return;
    }
    Diag.note('合成播放器就緒：${made.duration.toStringAsFixed(1)} 秒');
    // 這一版烘的就是現在的值，兩份指紋一起同步
    _lastCompSig = _compSig();
    _lastCompEditSig = _compSig(withPaths: false);
    setState(() => _comp = made);
    // 合成接手了，舊的那幾顆播放器立刻放掉（見 _trimPlayers）
    _trimPlayers();
    await made.seek(_position);
  }

  /// 現在這一刻是不是真的走合成播放器
  bool get _compOn => Diag.compPlayer.value && _comp != null;

  /// 播放中比對「時鐘」與「播放器實際位置」的取樣器。
  ///
  /// 有一種卡頓在 Flutter 這邊完全看不到：影格根本沒從解碼器送上來。
  /// UI 與合成執行緒都很閒，但畫面就是不動——只有直接問播放器位置
  /// 才分得出來，而那正是「輸出的檔案很順、App 裡就是卡」的形狀
  Timer? _playProbe;

  void _startPlayProbe() {
    _playProbe?.cancel();
    final wall = Stopwatch()..start();
    var basePlayer = -1;
    Object? baseCtrl;
    _playProbe = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      if (!_playing || !mounted) return;
      final callSw = Stopwatch()..start();
      int? pos;
      Object? who;
      if (_compOn) {
        pos = ((await _comp!.position()) * 1000).round();
        who = _comp;
      } else {
        final c = _ctrls[_tl.videoAt(_position)?.id ?? -1];
        if (c == null || !c.value.isInitialized) return;
        pos = (await c.positionNow())?.inMilliseconds;
        who = c;
      }
      callSw.stop();
      if (pos == null) return;
      final c = who;
      // 跨過交界會換一顆播放器，兩顆的位置本來就不連續——
      // 不重新起算的話那一次會被記成「落後好幾秒」的假訊號
      if (basePlayer < 0 || !identical(baseCtrl, c)) {
        baseCtrl = c;
        basePlayer = pos;
        wall.reset();
        return;
      }
      Diag.notePlaybackSample(
        wall.elapsedMilliseconds,
        pos - basePlayer,
        callSw.elapsedMilliseconds,
      );
      basePlayer = pos;
      wall.reset();
    });
  }

  /// 跟合成播放器對時：每 200ms 問一次真正的位置，中間用 ticker 補間
  DateTime _lastCompSync = DateTime.fromMillisecondsSinceEpoch(0);

  void _syncFromComp() {
    final now = DateTime.now();
    if (now.difference(_lastCompSync).inMilliseconds < 200) return;
    _lastCompSync = now;
    unawaited(
      _comp!.position().then((p) {
        if (!mounted || !_playing) return;
        // 差太多才拉回去：每次都硬設會讓播放頭一直微跳
        if ((p - _position).abs() > 0.12) _position = p;
      }),
    );
  }

  /// 起步：先把「現在該播的那幾段」seek 到位、等解碼器準備好，
  /// 再開時鐘。
  ///
  /// 原本是按下去就開時鐘，然後才在 _syncMedia 裡 seek——解碼器
  /// 轉起來要時間，這段期間時鐘已經在跑而畫面還停在上一格，
  /// 所以每次按播放開頭都頓一下。播放途中的段落交界不會有這個問題，
  /// 因為那些是提早 1.2 秒預先對位過的（見 _syncMedia 的 pre-roll）
  Future<void> _play() async {
    if (_tl.duration <= 0) return;
    if (_position >= _tl.duration - 0.01) _position = 0;
    final tr = PlaybackTrace.instance..start();

    // 拖曳收尾排在後面的那幾件事，按下播放的當下全部取消：
    // 120ms 的補送 seek、220ms 的收尾（裡面還會再送一次 seek）。
    // 使用者的順序就是「拖到某一格 → 按播放」，這些 seek 常常剛好在
    // 按下去的那一刻進行中，而 seek 跑完之前播放器的 rate 壓在 0，
    // 畫面就是不會動。
    // 同時立刻離開拖曳模式——拖曳中預覽是「快取幀疊在影片上面」，
    // 不收掉的話影片已經在跑也還是看到那張蓋著的靜止圖
    _scrubSettleTimer?.cancel();
    _scrubEndTimer?.cancel();
    _seekInFlight = false;
    if (_scrubbing) setState(() => _scrubbing = false);

    // 合成播放器接手時，整條時間軸就是它一顆在播：舊的逐片段播放器
    // 一個都不要碰。上一版兩邊同時在播——兩倍解碼、兩份聲音，
    // 而且「快不快」也就比不出來了
    if (_compOn) {
      setState(() => _playing = true);
      // 已經停在該在的位置就不要 seek——這正是我在舊路徑上剛修掉的
      // 同一個坑：seek 沒跑完之前播放器的 rate 壓在 0，畫面不會動。
      // 真的要移動時也用寬容 seek，反正接下來就要滾過去了
      final now = await _comp!.position();
      if ((now - _position).abs() <= 0.15) {
        // 播放器已經在附近（chase 的寬容度是 0.1，別跟它打架）：
        // 一發 seek 都不送，時間軸直接對齊播放器——它本來就是唯一的時鐘
        _position = now;
      } else {
        await _comp!.seek(_position);
      }
      await _comp!.setRate(_speed);
      final st = await _comp!.play();
      tr.log('呼叫 play()（合成播放器，狀態：${st ?? '？'}）');
      final sw = Stopwatch()..start();
      final p0 = now;
      while (mounted && sw.elapsedMilliseconds < 250) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final p = await _comp!.position();
        if ((p - p0).abs() > 0.001) {
          tr.log('影格開始滾動（合成播放器）');
          break;
        }
      }
      Diag.notePlayLatency(sw.elapsedMilliseconds);
      if (!mounted) return;
      _lastTick = Duration.zero;
      _ticker.start();
      tr.log('◀ 時間軸開始走');
      return;
    }
    final waits = <Future<void>>[];
    for (final clip in _tl.clips) {
      final k = _tl.sourceOf(clip).kind;
      if (k != ClipKind.video && k != ClipKind.audio) continue;
      if (!clip.covers(_position)) continue;
      if (_wasActive.contains(clip.id)) continue; // 已經對好了
      final c = _ctrls[clip.id];
      if (c == null || !c.value.isInitialized) continue;
      _wasActive.add(clip.id); // 標記已進場，_syncMedia 不再 seek 一次
      final want = clip.sourceTimeAt(_position);
      // 已經停在該在的位置就不要 seek。暫停後再按播放、或播完一段
      // 再按，播放器本來就在正確的地方——多送一次 seek 只是讓
      // 「按下去」到「畫面開始動」中間多一次來回。
      // 80ms 的容差：位置回報本來就有誤差，比對太嚴等於白加。
      // web 的 position 是 async 往返，問了反而多一次等待
      final now = kIsWeb ? null : await c.positionNow();
      tr.log('查位置完成（片段 ${clip.id}）現在=${now?.inMilliseconds}ms '
          '目標=${(want * 1000).round()}ms');
      if (now != null && (now.inMilliseconds / 1000 - want).abs() < 0.08) {
        tr.log('位置已對，跳過 seek');
        continue;
      }
      tr.log('送出 seek（片段 ${clip.id}）');
      waits.add(c.seekTo(Duration(milliseconds: (want * 1000).round())));
    }
    if (waits.isNotEmpty) {
      // 上限 400ms：seek 卡住的話寧可頓一下，也不能讓播放鍵沒反應
      await Future.any([
        Future.wait(waits).then((_) {}),
        Future<void>.delayed(const Duration(milliseconds: 400)),
      ]);
      tr.log('seek 等待結束（${waits.length} 個）');
      if (!mounted) return;
    }
    setState(() => _playing = true);
    // 先叫「現在該播的」影片動起來，盯著它的位置真的前進了才開
    // 時間軸的錶。位置一定要用 positionNow()（直接問引擎）——
    // 上一版盯的是 value.position，那是 video_player 每 500ms 才
    // 更新一次的快取，在等待窗口內根本不會動，於是每次都白白
    // 燒滿上限才開錶，播放鍵反而更延遲。
    // 上限 250ms，起不來寧可照舊也不能讓播放鍵卡住
    PlayerX? lead;
    for (final clip in _tl.clips) {
      if (!clip.covers(_position)) continue;
      if (_tl.sourceOf(clip).kind != ClipKind.video) continue;
      final c = _ctrls[clip.id];
      if (c == null || !c.value.isInitialized) continue;
      final want = _speed * clip.speed;
      if ((_lastSpeed[clip.id] ?? -1) != want) {
        _lastSpeed[clip.id] = want;
        c.setPlaybackSpeed(want);
      }
      unawaited(c.play());
      tr.log('呼叫 play()（片段 ${clip.id}）');
      lead ??= c;
    }
    if (lead != null && !kIsWeb) {
      final p0 = await lead.positionNow();
      final sw = Stopwatch()..start();
      var sawBuffering = false;
      // 一格問一次就夠。20ms 一次的平台往返是在播放器最忙的時候一直
      // 插隊，等於自己拖慢自己
      while (mounted && sw.elapsedMilliseconds < 250) {
        await Future<void>.delayed(const Duration(milliseconds: 33));
        if (lead.value.isBuffering) sawBuffering = true;
        final p = await lead.positionNow();
        if (p != null && p != p0) {
          tr.log('影格開始滾動（位置從 ${p0?.inMilliseconds} 變成 '
              '${p.inMilliseconds}ms）');
          break;
        }
      }
      // 「按下播放到畫面真的動」——使用者說的「撥放延遲」就是這個數字。
      // 記成第一級的統計，才比得出改動有沒有效
      Diag.notePlayLatency(sw.elapsedMilliseconds, buffering: sawBuffering);
      if (sw.elapsedMilliseconds >= 250) {
        tr.log('⚠ 等了 250ms 影格還沒動，直接開錶');
      }
      if (!mounted) return;
    }
    _lastTick = Duration.zero;
    _ticker.start();
    _startPlayProbe();
    tr.log('◀ 時間軸開始走');
    _syncMedia();
  }

  void _pause() {
    _playProbe?.cancel();
    _playProbe = null;
    if (_comp != null) unawaited(_comp!.pause());
    if (_ticker.isActive) _ticker.stop();
    for (final c in _ctrls.values) {
      if (c.value.isPlaying) c.pause();
    }
    // 預熱中的播放器也一起停了，下次播放要重新預熱
    _warmed.clear();
    if (_playing) setState(() => _playing = false);
    // 播放中推遲掉的媒體抽換，現在補做
    if (_pendingSwaps.isNotEmpty || _pendingCompRebuild) {
      _flushPendingSwaps();
    }
  }

  /// 音量快取：值沒變就不打擾播放器（每格呼叫 setVolume 會卡）
  final Map<int, double> _lastVol = {};

  /// 片段「剛變成作用中」的追蹤：只在進場那一刻 seek 一次
  final Set<int> _wasActive = {};

  /// 已預先對位（快進場時先 seek 到起點）的片段
  final Set<int> _preRolled = {};

  /// 已經「預熱開播」的片段：進場前就用極慢速靜音跑著，
  /// 讓解碼／送影格的管線先轉起來（見 _syncMedia 的 pre-roll）
  final Set<int> _warmed = {};

  /// 時間軸的「時間→內容」對應被改動（移動/修剪/變速/刪除/復原）後
  /// 一定要呼叫：清掉進場狀態，下次播放每個片段重新對位。
  /// 不清的話進場 seek 被跳過，1 秒內的錯位永遠不會被修正
  void _resyncPlayback() {
    _wasActive.clear();
    _preRolled.clear();
    _warmed.clear();
    _lastDriftFix.clear();
  }

  /// [clip] 是不是「切割出來的後段」——也就是同一軌、同一素材、
  /// 頭尾相接且速度相同的前一段。是的話它進場時會直接接走前段的
  /// 播放器，不必自己 seek 或預熱。回傳那個前段（沒有就 null）
  TimelineClip? _handoffFrom(TimelineClip clip) {
    for (final prev in _tl.clips) {
      if (identical(prev, clip) ||
          prev.sourceIndex != clip.sourceIndex ||
          prev.track != clip.track) {
        continue;
      }
      if ((prev.end - clip.offset).abs() > 0.05 ||
          (prev.trimEnd - clip.trimStart).abs() > 0.05 ||
          (prev.speed - clip.speed).abs() > 0.001) {
        continue;
      }
      return prev;
    }
    return null;
  }

  /// 播放診斷：長按標題打開。記錄按下播放之後每一段花了多久、
  /// 交界有沒有命中預熱、背景抽幀跟卡頓的時間點對不對得上
  void _openTrace() {
    final tr = PlaybackTrace.instance;
    // 素材規格填進環境區，看報告時不用再回頭問
    final src = _tl.sources.firstWhere(
      (s) => s.isVideo,
      orElse: () => MediaSource(
        path: '',
        name: '',
        kind: ClipKind.text,
        duration: 0,
      ),
    );
    if (src.isVideo) {
      tr.env('素材', '${src.w}x${src.h}');
      unawaited(
        engine.probeVideoInfo(src.path).then((i) {
          tr.env('編碼', '${i.codec} ${i.fps.toStringAsFixed(2)}fps');
        }),
      );
    }
    tr.env('片段數', '${_tl.clips.length}');
    unawaited(engine.hdrChainName().then((n) => tr.env('HDR 轉換', n)));
    // 工作檔到底有沒有生效：這一格對不對，決定了「順不順」是不是
    // 還在原檔上跑
    final vids = _tl.sources.where((s) => s.isVideo).toList();
    final ready = vids.where((s) => s.workPath != null).length;
    tr.env('工作檔', '${vids.length} 支素材，$ready 支已轉好'
        '${_prepping.isEmpty ? '' : '（${_prepping.length} 支轉檔中）'}');
    unawaited(
      MediaPrep.available.then(
        (v) => tr.env('轉檔通道', v ? '可用' : '沒接上（一律用原檔）'),
      ),
    );
    // 實際在播的那份檔到底長什麼樣。關鍵幀間隔那一欄直接決定拖曳順不順，
    // 以前只能從「有沒有轉好」猜，猜錯過很多次
    for (var i = 0; i < vids.length; i++) {
      final src = vids[i];
      unawaited(
        MediaPrep.probe(src.previewPath).then((m) {
          if (m == null) return;
          tr.env(
            '在播的檔 ${i + 1}${src.workPath == null ? '（原檔！）' : ''}',
            MediaPrep.describe(m),
          );
        }),
      );
    }
    unawaited(Diag.readDeviceState());
    tr.env(
      '合成播放器',
      _comp != null
          ? '使用中${Diag.playerLayer.value ? '（系統影片圖層）' : '（Flutter 材質）'}'
          : (_compWhyNot ?? (Diag.compPlayer.value ? '組不起來' : '沒開')),
    );
    // 換圖間隔＝畫面實際更新的節奏，judder 的唯一證據
    if (_comp != null) {
      if (Diag.playerLayer.value) {
        // 畫面走系統影片圖層，根本沒有材質可量——上一版這行印的是
        // 「沒有人在看的那份材質」的節奏，看了只會誤判
        tr.env('換圖節奏', '系統影片圖層模式：畫面不經過材質，量不到');
      } else {
        unawaited(_comp!.gaps().then((g) => tr.env('換圖節奏', g)));
      }
    }
    if (_comp != null) {
      unawaited(_comp!.health().then((h) => tr.env('播放器回報', h)));
    }
    unawaited(
      Diag.memoryMb().then(
        (mb) => tr.env(
          '記憶體',
          mb == null
              ? '讀不到'
              : '現在 $mb MB／峰值 ${Diag.peakMb} MB'
                    '／系統還剩 ${Diag.lastFreeMb} MB',
        ),
      ),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                value: tr.enabled,
                onChanged: (v) => setSheet(() {
                  tr.enabled = v;
                  if (v) tr.clear();
                }),
                title: const Text('記錄播放診斷'),
                subtitle: const Text('打開後按播放跑一次，再回來看'),
              ),
              // 一鍵自動排查：四種設定各播一輪，直接說是哪個。
              // 一輪一個假設地問使用者，一次來回就是一天
              ListTile(
                leading: _selfTesting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kAmber,
                        ),
                      )
                    : const Icon(Icons.troubleshoot, color: kAmber),
                title: Text(_selfTesting ? '排查中…請不要離開這一頁' : '一鍵自動排查'),
                subtitle: const Text('四種設定各播一輪，直接告訴你是哪個機制'),
                enabled: !_selfTesting,
                onTap: () async {
                  setSheet(() => _selfTesting = true);
                  final r = await _runSelfTest();
                  if (!context.mounted) return;
                  setSheet(() {});
                  await showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('排查結果'),
                      content: SingleChildScrollView(
                        child: Text(
                          r,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: r));
                            Navigator.pop(context);
                          },
                          child: const Text('複製'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('關閉'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              // 現場實驗開關：關掉一個東西再播一次，卡頓有沒有消失
              // 當場就知道，不用等下一版
              for (final t in [
                (
                  '交界預熱（多開一顆播放器）',
                  '關掉試試：iOS 上兩顆 AVPlayer 同時解碼可能就是那個頓',
                  Diag.preheat,
                ),
                (
                  '脫節校正（播放中自動 seek）',
                  '關掉試試：每次校正都會讓畫面停一下',
                  Diag.driftFix,
                ),
                ('背景抽幀', '關掉試試：抽幀會跟播放搶硬體解碼器', Diag.scrubPrefetch),
                (
                  '只養一顆播放器',
                  '打開試試：三顆 AVPlayer 一起養，系統會在它們之間排隊',
                  Diag.singlePlayer,
                ),
                (
                  '合成播放器（整條時間軸交給系統）',
                  '預設開。關掉＝退回一片段一顆播放器的舊路徑',
                  Diag.compPlayer,
                ),
                (
                  '系統影片圖層（要先開合成播放器）',
                  '預設開。關掉＝影格複製一份進 Flutter 材質再合成',
                  Diag.playerLayer,
                ),
              ])
                SwitchListTile(
                  value: t.$3.value,
                  onChanged: (v) {
                    setSheet(() => t.$3.value = v);
                    // 圖層開關也要重組：材質那份是在組的時候決定要不要
                    // 出的，切了不重組等於什麼都沒變
                    if (identical(t.$3, Diag.compPlayer) ||
                        identical(t.$3, Diag.playerLayer)) {
                      _pause();
                      _compDirty = true;
                      unawaited(_ensureComp());
                    }
                  },
                  title: Text(t.$1, style: const TextStyle(fontSize: 13.5)),
                  subtitle: Text(
                    t.$2,
                    style: const TextStyle(fontSize: 11, color: kTextDim),
                  ),
                  dense: true,
                ),
              const Divider(height: 1),
              // 同一支影片裸播一次：沒有時間軸、沒有 ticker、沒有圖層。
              // 這裡順而編輯器卡＝編輯器的問題；這裡也卡＝引擎或裝置。
              // 進去還能切「原檔／工作檔」再比一次，範圍一次縮到最小
              ListTile(
                leading: const Icon(Icons.play_circle_outline, color: kAmber),
                title: const Text('純播放測試'),
                subtitle: const Text('裸播一支影片，比對原檔與工作檔'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    this.context,
                    MaterialPageRoute(
                      builder: (_) => const PlaybackTestScreen(),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    tr.report(),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: secondaryAction(
                        label: '清除',
                        onPressed: () => setSheet(tr.clear),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: primaryAction(
                        label: '複製報告',
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text:
                                  '${tr.report()}\n${Diag.report()}'
                                  '\n${_selfTestResult ?? ''}',
                            ),
                          );
                          showHint(context, '已複製，貼給開發者就好');
                        },
                      ),
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

  /// 片段此刻該有的音量（還沒夾在 0~1，可能大於 1）
  double _rawVolOf(TimelineClip clip) {
    final trackMute = _mutedTracks.contains(clip.track) ? 0.0 : 1.0;
    // 倒轉的片段預覽時靜音：播放器只會正著播，聲音是反的內容，
    // 放出來只會干擾（匯出時會用 areverse 正確倒過來）
    final revMute = clip.reverse ? 0.0 : 1.0;
    return clip.volume * trackMute * revMute * clip.fadeFactorAt(_position);
  }

  /// 每個播放器上次設過的速度。重複設同一個值不是沒事——暫停狀態下
  /// 設速度會讓插件重跑一次 pause+preroll，把剛熱好的解碼管線打掉
  final Map<int, double> _lastSpeed = {};

  /// 每個片段上次大幅校正的時間（防連發）
  final Map<int, DateTime> _lastDriftFix = {};
  DateTime _lastVolSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// 讓每個素材的播放狀態跟上播放頭。
  /// 重要：Android 的 video_player 回報位置每 ~500ms 才更新一次，
  /// 拿過期位置對時鐘會誤判脫節 → seek 風暴＝跳針。
  /// 所以播放中只在「進場那一刻」seek 一次，之後放手讓解碼器自己跑，
  /// 除非真的大幅脫節（>1 秒）才校正、且同片段 2 秒內不重複校正。
  int _syncSampleTick = 0;
  DateTime _lastTrim = DateTime.fromMillisecondsSinceEpoch(0);

  /// 只養一顆播放器（實驗開關）：不是「現在這一段」也不是「快進場」的
  /// 播放器整顆放掉。
  ///
  /// iOS 上每顆 AVPlayer 都佔一組解碼與影格輸出資源；三顆一起養的時候
  /// 系統會在它們之間排隊，畫面就會不定時頓一下。聲音的播放器不動——
  /// 那個要整段對位，中途放掉會斷
  void _trimPlayers() {
    // 合成播放器接手時，整條時間軸就是它一顆在出畫面——舊的那幾顆
    // 一顆都不需要留。閒置的 AVPlayer 不是免費的：每顆都佔一組解碼與
    // 影格輸出資源，系統會在它們之間排隊。相簿播影片只有一顆播放器，
    // 我們要一樣順就不能多養
    if (_compOn) {
      if (_ctrls.isEmpty) return;
      final n = _ctrls.length;
      for (final c in _ctrls.values) {
        c.dispose();
      }
      _ctrls.clear();
      _wasActive.clear();
      _preRolled.clear();
      _warmed.clear();
      _lastVol.clear();
      _lastSpeed.clear();
      Diag.count('放掉閒置播放器', n);
      return;
    }
    if (!Diag.singlePlayer.value) return;
    final now = DateTime.now();
    if (now.difference(_lastTrim).inMilliseconds < 400) return;
    _lastTrim = now;
    final keep = <int>{};
    final cur = _tl.videoAt(_position);
    if (cur != null) keep.add(cur.id);
    for (final c in _tl.clips) {
      if (_tl.sourceOf(c).kind == ClipKind.audio) {
        keep.add(c.id);
        continue;
      }
      // 快進場的留著：交界才現場開一顆的話，會頓得比現在更明顯
      final lead = c.offset - _position;
      if (lead > 0 && lead < 1.5) keep.add(c.id);
    }
    var dropped = 0;
    for (final id in _ctrls.keys.toList()) {
      if (keep.contains(id)) continue;
      _ctrls.remove(id)?.dispose();
      _wasActive.remove(id);
      _preRolled.remove(id);
      _warmed.remove(id);
      dropped++;
    }
    if (dropped > 0) Diag.count('放掉閒置播放器', dropped);
    // 該留的還沒開就補開（放掉之後又滑回來的情況）
    for (final c in _tl.clips) {
      if (keep.contains(c.id)) _ensureCtrlFor(c);
    }
  }

  void _syncMedia() {
    _trimPlayers();
    final sw = (++_syncSampleTick % 30 == 0) ? (Stopwatch()..start()) : null;
    _syncMediaBody();
    if (sw != null) {
      Diag.noteSync(sw.elapsedMicroseconds);
      var live = 0, playing = 0;
      for (final c in _ctrls.values) {
        if (!c.value.isInitialized) continue;
        live++;
        if (c.value.isPlaying) playing++;
      }
      Diag.notePlayers(live, playing);
    }
  }

  void _syncMediaBody() {
    final now = DateTime.now();
    // 預熱／進場會直接改速度，記回來讓 _play 的比對是準的
    for (final e in _warmed) {
      _lastSpeed.remove(e);
    }
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
      // 進場準備，兩段式：
      //
      // 一、提早 1.2 秒 seek 到自己的起點，交界時第一幀已經解好。
      //
      // 二、光是解好第一幀還不夠。iOS 走 AVPlayer，從暫停狀態
      // play() 到真的開始送影格有明顯延遲，交界時畫面就停在那第一幀
      // 「頓一下」——這就是每段開頭都頓的原因。所以再往前一步：
      // 進場前 0.35 秒用極慢速靜音開播，讓整條解碼與送影格的管線先
      // 轉起來；交界時只要把速度換回正常，對一個已經在跑的播放器
      // 來說那是很便宜的操作。0.35 秒 × 0.05 只吃掉 17 毫秒的內容，
      // 而且那時它的圖層還是近乎透明的（見預覽的暖身掛載），看不到
      for (final clip in _tl.clips) {
        final k = _tl.sourceOf(clip).kind;
        if (k != ClipKind.video && k != ClipKind.audio) continue;
        final c = _ctrls[clip.id];
        if (c == null || !c.value.isInitialized) continue;
        final lead = clip.offset - _position;
        if (lead <= 0 || lead > 2.0) {
          _preRolled.remove(clip.id);
          // 滑遠了才把預熱中的播放器收回來。lead<=0 是「正要進場」，
          // 旗標要留給進場那一段消化（它靠這個旗標換回正常速度）——
          // 之前在這裡就把旗標吃掉，進場後速度永遠卡在慢速
          if (lead > 0 && _warmed.remove(clip.id) && c.value.isPlaying) {
            c.pause();
          }
          continue;
        }
        if (_wasActive.contains(clip.id)) continue;
        // 切割出來的後段不要預熱。它進場時會直接接走前段正在播的
        // 播放器（見上面的「換手」），根本不需要自己起步；先預熱的話
        // 換手當下兩顆播放器對調，圖層底下的貼圖跟著換一顆，
        // 就是「切割後片段之間閃一下」的來源
        if (_handoffFrom(clip) != null) continue;
        if (lead < 1.2 && _preRolled.add(clip.id)) {
          c.seekTo(
            Duration(
              milliseconds: (clip.sourceTimeAt(clip.offset) * 1000).round(),
            ),
          );
        }
        // 預熱只在裝置端做。Web 播的是瀏覽器的 <video>，它自己會
        // 緩衝、起步本來就快，沒有 AVPlayer 那種起轉延遲；在 web 上
        // 多開一個元素同時解碼只會讓畫面更卡、交界更容易閃黑
        if (!kIsWeb &&
            Diag.preheat.value &&
            _playing &&
            lead < 0.35 &&
            !_warmed.contains(clip.id)) {
          PlaybackTrace.instance.log('預熱開播（片段 ${clip.id}，'
              '距離進場 ${(lead * 1000).round()}ms）');
        }
        if (!kIsWeb &&
            Diag.preheat.value &&
            _playing &&
            lead < 0.35 &&
            _warmed.add(clip.id)) {
          Diag.count('預熱：兩顆播放器同時在解');
          _lastVol[clip.id] = 0;
          c.setVolume(0);
          // 素材在 trimStart 之前還有畫面可用時（修剪、切割過的片段
          // 都有），直接用正常速度「助跑」：從 trimStart 往前倒一點
          // 開播，到交界剛好走到 trimStart，進場只是把透明度打開，
          // 完全沒有起步這回事。trimStart=0（整支直接匯入）沒有前段
          // 可倒，退回極慢速讓解碼管線轉著，進場再換速度
          final backSrc = math.min(lead * clip.speed, clip.trimStart);
          if (backSrc > 0.02) {
            c.seekTo(
              Duration(
                milliseconds: ((clip.trimStart - backSrc) * 1000).round(),
              ),
            );
            c.setPlaybackSpeed(_speed * clip.speed);
          } else {
            c.setPlaybackSpeed(0.05);
          }
          unawaited(c.play());
        }
      }
    }
    // 兩趟：第一趟處理進場與繼續播的，第二趟才處理離場的暫停。
    // 合成一趟的話，因為 clips 是按時間排的、離場的那段排在前面，
    // 交界那一格會先把上一段停掉、下一段還沒開始，中間空一格
    for (var pass = 0; pass < 2; pass++) {
      for (final clip in _tl.clips) {
        final c = _ctrls[clip.id];
        if (c == null || !c.value.isInitialized) continue;
        final active = clip.covers(_position);
        if (active != (pass == 0)) continue;
        if (!active) {
          _wasActive.remove(clip.id);
          // 預熱中的不能在這裡按停——它就是要在進場前先跑著。
          // 之前這裡把剛開始預熱的播放器當場暫停，每一格都是
          // 「開播→立刻按停」，預熱從來沒真的發生過，交界照樣頓。
          // 預熱的收回由上面 pre-roll 那段管（滑遠了才停）
          if (_warmed.contains(clip.id)) continue;
          if (c.value.isPlaying) c.pause();
          continue;
        }
        final want = clip.sourceTimeAt(_position);
        final justEntered = !_wasActive.contains(clip.id);
        if (justEntered) {
          // 進場：對準起點，之後不再打擾。
          // 已經預先對位過就不再 seek（見上面的 pre-roll）
          _wasActive.add(clip.id);
          if (!_preRolled.remove(clip.id)) {
            c.seekTo(Duration(milliseconds: (want * 1000).round()));
          }
        } else if (_playing) {
          final actual = c.value.position.inMilliseconds / 1000.0;
          // 門檻隨播放速度放大：Android 位置回報有 ~500ms 延遲，
          // 2 倍速以上光是延遲就會超過 1 秒，會被誤判成脫節狂 seek
          final driftThr = math.max(1.0, _speed * clip.speed);
          if (Diag.driftFix.value &&
              (actual - want).abs() > driftThr &&
              now
                      .difference(
                        _lastDriftFix[clip.id] ??
                            DateTime.fromMillisecondsSinceEpoch(0),
                      )
                      .inMilliseconds >
                  2000) {
            _lastDriftFix[clip.id] = now;
            // 播放中的每一次 seek 都會讓畫面停一下。以前完全沒有紀錄，
            // 所以「卡頓」到底是不是自己 seek 出來的無從分辨
            Diag.count('播放中校正 seek');
            PlaybackTrace.instance.log(
              '⚠ 脫節校正 seek（片段 ${clip.id}，'
              '差 ${((actual - want) * 1000).round()}ms）',
            );
            c.seekTo(Duration(milliseconds: (want * 1000).round()));
          }
        }
        // 音量最多 10 次/秒（fade 中每格打 method channel 也會卡）。
        // 進場那一格一定要更新：預熱時是靜音的，等節流輪到它會慢
        // 100 毫秒，聽起來就像每段開頭都淡入
        if (volDue || justEntered) {
          final vol = _rawVolOf(clip).clamp(0.0, 1.0);
          if ((vol - (_lastVol[clip.id] ?? -1)).abs() > 0.02) {
            _lastVol[clip.id] = vol;
            c.setVolume(vol);
          }
        }
        if (_playing) {
          final rate = _speed * clip.speed;
          if (!c.value.isPlaying) {
            c.setPlaybackSpeed(rate);
            c.play();
          } else if (_warmed.remove(clip.id)) {
            // 預熱時掛的是極慢速，進場換回真正的速度
            c.setPlaybackSpeed(rate);
            PlaybackTrace.instance.log('進場：預熱命中（片段 ${clip.id}）');
          }
        } else if (c.value.isPlaying) {
          c.pause();
        }
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
    if (_compOn) {
      // 合成播放器接手時，畫面直接由它出：手指每動一次就把最新位置送
      // 過去（原生端只追最新的那個目標，不會排隊塞車），停手再補一發
      // 精準的。不抽幀、不疊快取幀、不動底下那幾顆播放器——那些在這條
      // 路徑上全是跟合成播放器搶解碼器的多餘工作
      _compSeek();
      _scrubEndTimer?.cancel();
      _scrubEndTimer = Timer(const Duration(milliseconds: 220), _tryEndScrub);
      _scrubSettleTimer?.cancel();
      _scrubSettleTimer = Timer(
        const Duration(milliseconds: 120),
        () => _compSeek(exact: true),
      );
      return;
    }
    _requestScrubFrames();
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
      // 同一軌不讓素材互相覆蓋：蓋住的那段等於憑空消失，時間軸上還
      // 看不出來。想放的位置有人佔著就滑到最近的空位（見
      // Timeline.freeOffsetOnTrack）。插入新軌不用判，那條軌是空的
      final want = newOffset.clamp(0.0, 1e6);
      clip.offset = insert ? want : _tl.freeOffsetOnTrack(clip, want, t);
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
      if (insert) {
        // 插入時 t 以下的軌整批往下移一格，靜音要跟著搬
        //（不然靜音會掉到別軌，匯出時那一軌的聲音也會被寫成 0）
        final moved = _mutedTracks.map((k) => k >= t ? k + 1 : k).toSet();
        _mutedTracks
          ..clear()
          ..addAll(moved);
      }
      if (insert || t < oldUsed) _remapMuted(_tl.compactTracks());
      // 插入/收斂會重編軌號，選取的軌道指不準了——直接清掉
      if (insert) _selTrack = -1;
    });
    _resyncPlayback();
  }

  /// 點畫面上的浮水印時，叫下面的面板捲到對應的設定區塊
  final _wmPanelCtrl = WatermarkPanelController();

  /// 預覽區每個圖層畫在哪（由下往上收集，畫的時候順手記下來）。
  /// -2 代表全域浮水印，其餘是片段 id
  final List<({int id, Rect rect})> _hitBoxes = [];

  /// 全域浮水印用的假 id
  static const int _kWmId = -2;

  /// 上一次點預覽的位置：同一點再點一次就往下鑽一層
  Offset? _cycleAt;

  /// 「還有下一層」的提示最多講幾次（手勢看不見，但也不能一直嘮叨）
  int _cycleHintLeft = 2;

  /// 點預覽區：選取這個點上最上面的東西。
  ///
  /// 同一點連續點擊會往下鑽一層。完全被蓋住的素材在畫面上本來
  /// 永遠選不到（只能去時間軸點），這是唯一能選到它的方法
  void _tapSelectAt(Offset p) {
    // _hitBoxes 是由下往上收集的，倒過來就是由上往下
    final hits = <int>[];
    for (var i = _hitBoxes.length - 1; i >= 0; i--) {
      final b = _hitBoxes[i];
      if (b.rect.contains(p) && !hits.contains(b.id)) hits.add(b.id);
    }
    if (hits.isEmpty) {
      _cycleAt = null;
      setState(() {
        _sel = -1;
        _wmSel = false;
      });
      return;
    }
    // 手指不可能點在同一個像素上，給 24px 的容忍
    final same = _cycleAt != null && (_cycleAt! - p).distance <= 24;
    final cur = _wmSel ? _kWmId : _sel;
    var next = hits.first;
    if (same) {
      final at = hits.indexOf(cur);
      if (at >= 0) next = hits[(at + 1) % hits.length];
    }
    _cycleAt = p;
    setState(() {
      _wmSel = next == _kWmId;
      _sel = next == _kWmId ? -1 : next;
    });
    // 選到浮水印就跳去浮水印分頁（跟以前點浮水印一樣）。
    // 循環途中不跳，不然每點一下分頁就被拉走一次
    if (!same) {
      final isWm =
          next == _kWmId ||
          (_selClipById(next) != null &&
              _tl.sourceOf(_selClipById(next)!).kind == ClipKind.wm);
      if (isWm) {
        _tabs.animateTo(1);
        _wmPanelCtrl.scrollTo(WmPart.text);
      }
    }
    if (!same && hits.length > 1 && _cycleHintLeft > 0) {
      _cycleHintLeft--;
      showHint(context, overlapHint(hits.length));
    }
  }

  /// 浮水印圖層回報自己畫在哪（在 build 裡呼叫，只能存不能 setState）。
  /// 圖片可以有很多張，每一張都要能點得到
  void _addWmHit(int id, Rect? text, List<Rect?> logos) {
    if (text != null) _hitBoxes.add((id: id, rect: text));
    for (final r in logos) {
      if (r != null) _hitBoxes.add((id: id, rect: r));
    }
  }

  /// 上一刻修剪把手有沒有吸住（吸住的瞬間震一下，才有磁鐵的感覺）
  bool _trimSnapped = false;

  /// 這次修剪手勢「未吸附」的邊緣位置。
  /// 把手回報的是增量：若每步都從「已吸附」的邊緣起算，
  /// 每一小步都落在吸附半徑內、又被吸回原點，把手就永遠拖不動——
  /// 片段相接時起點本身就是吸附點，等於一開磁吸就完全不能修剪。
  /// 位移改累計在這個原始值上，拖超過吸附半徑自然脫離
  double? _trimRawEdge;

  /// 修剪手勢開始：拍復原快照、重置原始邊緣
  void _trimGestureStart() {
    _trimRawEdge = null;
    _pushUndo();
  }

  void _trimClip(int id, double dSec, bool fromLeft) {
    if (_tlPinching) return; // 雙指縮放中不修剪
    setState(() {
      for (final c in _tl.clips) {
        if (c.id != id) continue;
        final src = _tl.sourceOf(c);
        final curEdge = fromLeft ? c.offset : c.end;
        // 磁吸：手指的「累計」位置吸附到鄰近片段邊緣／播放頭／0
        // 之後，再換算回實際的位移量——接片段才能剛好無縫貼齊
        final raw = (_trimRawEdge ?? curEdge) + dSec;
        _trimRawEdge = raw;
        final snapped = _snapOn ? _tl.snapEdge(c, raw, _pxPerSec) : raw;
        // 剛吸上去的那一下震動回饋
        final on = (snapped - raw).abs() > 0.0005;
        if (on != _trimSnapped) {
          _trimSnapped = on;
          if (on) HapticFeedback.selectionClick();
        }
        dSec = snapped - curEdge;
        // 把手拖的是「時間軸秒」，變速片段要換算回素材秒
        final dSrc = dSec * c.speed;
        // clamp 的上下限一旦反轉（極短片段），Dart 會直接丟例外，
        // 所以上限先確保不小於下限。
        // 倒轉片段的時間軸左緣對應素材尾端，兩端要對調著修，
        // 不然畫面上縮短的是左邊、實際被切掉的卻是尾巴
        if (!c.reverse) {
          if (fromLeft) {
            final hi = math.max(0.0, c.trimEnd - 0.3);
            final ns = (c.trimStart + dSrc).clamp(0.0, hi);
            // offset 位移用時間軸秒（素材差 ÷ 速度）
            c.offset = (c.offset + (ns - c.trimStart) / c.speed).clamp(
              0.0,
              1e6,
            );
            c.trimStart = ns;
          } else {
            final lo = math.min(c.trimStart + 0.3, src.duration);
            c.trimEnd = (c.trimEnd + dSrc).clamp(lo, src.duration);
          }
        } else {
          // 倒轉：時間軸左緣對應素材尾端，兩端對調著修
          if (fromLeft) {
            final lo = math.min(c.trimStart + 0.3, src.duration);
            final ne = (c.trimEnd - dSrc).clamp(lo, src.duration);
            c.offset = (c.offset + (c.trimEnd - ne) / c.speed).clamp(0.0, 1e6);
            c.trimEnd = ne;
          } else {
            final hi = math.max(0.0, c.trimEnd - 0.3);
            c.trimStart = (c.trimStart - dSrc).clamp(0.0, hi);
          }
        }
        // 撞到最短長度／素材端點被夾住時，原始值跟回實際邊緣：
        // 不跟的話反向拖回來會有一段空行程
        final newEdge = fromLeft ? c.offset : c.end;
        if ((newEdge - snapped).abs() > 0.001) _trimRawEdge = newEdge;
      }
    });
    _resyncPlayback();
  }

  /// 浮水印範圍的修剪。跟片段共用 _trimRawEdge 那套「位移累計在未吸附的
  /// 原始邊緣上」的做法——浮水印預設從 0 秒開始，而 0 秒本身就是吸附點，
  /// 每一小步都從已吸附的位置起算的話會被吸回去，等於一開磁吸就拉不動
  void _trimWatermark(double d, bool fromLeft) {
    if (_tlPinching) return; // 雙指縮放中不修剪
    setState(() {
      final cur = fromLeft ? _wmStart : _wmEndEff;
      final raw = (_trimRawEdge ?? cur) + d;
      _trimRawEdge = raw;
      final snapped = _snapOn ? _tl.snapTime(raw, _pxPerSec) : raw;
      final on = (snapped - raw).abs() > 0.0005;
      if (on != _trimSnapped) {
        _trimSnapped = on;
        if (on) HapticFeedback.selectionClick();
      }
      // clamp 的上下限反轉會直接丟例外，先夾好界線
      if (fromLeft) {
        _wmStart = snapped.clamp(0.0, math.max(0.0, _wmEndEff - 0.3));
      } else {
        _wmEnd = snapped.clamp(
          math.min(_wmStart + 0.3, _tl.duration),
          _tl.duration,
        );
      }
      // 被夾住時原始值跟回實際邊緣，不然反向拖回來會有一段空行程
      final newEdge = fromLeft ? _wmStart : _wmEndEff;
      if ((newEdge - snapped).abs() > 0.001) _trimRawEdge = newEdge;
    });
  }

  /// 用清單調整同一軌素材的先後順序，確定後照新順序頭尾相接。
  ///
  /// 多支影片接在一起時，想換順序只能一段一段拖到旁邊再拖回來，
  /// 位置還很難對準——這裡直接給一張可以上下拖的清單
  Future<void> _openReorderSheet() async {
    // 目標軌：選了東西就排那一軌，沒選就挑素材最多的那一軌
    var track = _selClip?.track ?? (_selTrack >= 0 ? _selTrack : -1);
    if (track < 0) {
      var bestN = 0;
      for (var t = 0; t < _tl.usedTracks; t++) {
        final n = _tl.onTrack(t).length;
        if (n > bestN) {
          bestN = n;
          track = t;
        }
      }
    }
    if (track < 0) {
      showHint(context, '時間軸還是空的');
      return;
    }
    // onTrack 回傳的是照時間排好的新清單，直接拿來當排序的暫存
    final order = _tl.onTrack(track);
    if (order.length < 2) {
      showHint(context, '第 ${track + 1} 軌只有一段素材，不用排順序');
      return;
    }
    // 重排的起點沿用原本第一段的位置，不會整條跳到 0
    final start = order.first.offset;
    _pause();


    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 標題置中、完成靠右。沒有「取消」——往下滑或點外面就是
              // 取消，而且不按完成本來就不會動到時間軸，多一顆按鈕
              // 只是讓人多想一次
              Padding(
                // 左右內距要一樣，標題才會真的置中在表單正中間
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(
                      _tl.usedTracks > 1
                          ? '調整片段順序（第 ${track + 1} 軌）'
                          : '調整片段順序',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kText,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text(
                          '完成',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '按住卡片左右拖曳換順序',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: kTextDim),
                ),
              ),
              // 橫排縮圖：一眼看得到「哪一段在哪個位置」。
              // 直排清單要靠序號慢慢對，橫排就是成品的順序本身
              SizedBox(
                height: 132,
                child: ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: order.length,
                  // 關掉內建的拖曳把手。橫向清單它會在每張卡正下方
                  // 放一個 ☰ 圖示（桌機／網頁才顯示，手機不會），
                  // 剛好卡在長度旁邊像個亂碼。我們自己的觸發器是
                  // 「按住整張卡」，本來就不需要那個把手
                  buildDefaultDragHandles: false,
                  // onReorderItem（不是舊的 onReorder）給的索引
                  // 已經扣掉搬走的那一格，直接插就對
                  onReorderItem: (from, to) => setSheet(() {
                    order.insert(to, order.removeAt(from));
                  }),
                  // 按住成立就震一下，讓人知道已經按夠久了
                  onReorderStart: (_) => HapticFeedback.mediumImpact(),
                  // 浮起來那張卡的外觀。
                  //
                  // 不能靠 setState 去改卡片自己的邊框：浮起來的那張是
                  // 「按住成立當下」把 widget 複製走的，之後父層再怎麼
                  // rebuild 都不會反映到它身上——琥珀框會畫在底下那張
                  // 看不見的卡上，浮著的還是原本的灰框。
                  //
                  // 預設的 proxyDecorator 會加陰影，在深色底上看起來就是
                  // 一團黑，所以整個換掉：只留琥珀框和一點點放大
                  proxyDecorator: (child, i, anim) => AnimatedBuilder(
                    animation: anim,
                    builder: (context, _) {
                      final t = Curves.easeOut.transform(anim.value);
                      return Transform.scale(
                        scale: 1 + 0.05 * t,
                        child: Material(
                          type: MaterialType.transparency,
                          child: Stack(
                            children: [
                              child,
                              // right: 8 讓框只圈住卡片本身，
                              // 不把卡片之間的間距一起圈進去
                              Positioned(
                                left: 0,
                                top: 0,
                                bottom: 0,
                                right: 8,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(
                                        kCardRadius,
                                      ),
                                      border: Border.all(
                                        color: kSelect.withValues(alpha: t),
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  itemBuilder: (context, i) {
                    final c = order[i];
                    final src = _tl.sourceOf(c);
                    // 優先用拖曳快取幀（長邊 540），不夠再退回時間軸的
                    // 縮圖（高 200）。卡片在 3 倍螢幕上是 336×396 實體
                    // 像素，200 的縮圖放上去糊成一片
                    final slots = _scrubFrames[c.sourceIndex];
                    final thumb =
                        (slots != null
                            ? _nearestFrame(
                                slots,
                                (c.trimStart * _scrubFps).round(),
                              )
                            : null) ??
                        (_thumbs[c.sourceIndex] ?? const []).firstOrNull;
                    // 卡片本身不標任何選取狀態：排序不需要先選誰，
                    // 亮框會被讀成「這張被選起來了」。唯一該亮的是
                    // 正在拖的那張，那個由 proxyDecorator 畫
                    //
                    // 按住就能拖：橫排清單本身也要能左右捲，
                    // 一按下去就拖的話會跟捲動打架
                    return _HoldToDragListener(
                      key: ValueKey(c.id),
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Container(
                          width: 112,
                          decoration: BoxDecoration(
                            color: kPanelHi,
                            borderRadius: BorderRadius.circular(kCardRadius),
                            border: Border.all(color: kBorder),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (thumb != null)
                                Image.memory(
                                  thumb,
                                  fit: BoxFit.cover,
                                  // 放大時的取樣：預設的 low 會有明顯
                                  // 鋸齒，medium 才平順
                                  filterQuality: FilterQuality.medium,
                                  gaplessPlayback: true,
                                )
                              else
                                Center(
                                  child: Icon(
                                    src.kind == ClipKind.audio
                                        ? Icons.music_note
                                        : Icons.movie,
                                    size: 22,
                                    color: kTextDim,
                                  ),
                                ),
                              // 底部壓一層漸層，白字才讀得到
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  height: 38,
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x00000000),
                                        Color(0xB3000000),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 5,
                                top: 5,
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(
                                      kTagRadius,
                                    ),
                                  ),
                                  child: Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 7,
                                bottom: 6,
                                child: Text(
                                  '${c.length.toStringAsFixed(1)}s',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;

    _pushUndo();
    setState(() {
      var at = start;
      for (final c in order) {
        c.offset = at;
        at += c.length;
      }
      // 清單順序也照排：同軌重疊時後面的會蓋在上面，
      // 不跟著排的話疊放順序跟看到的對不起來
      _tl.clips.removeWhere(order.contains);
      _tl.clips.addAll(order);
    });
    _resyncPlayback();
    _saveDraft();
    showHint(context, '已照新的順序接好');
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
      // 被刪那一軌的靜音狀態要拿掉，下面遞補上來的軌則跟著搬
      _mutedTracks.remove(track);
      _remapMuted(_tl.removeTrack(track));
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
      // 靜音也是綁軌號的，同樣要跟著搬
      _remapMuted(map);
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
      // 整組換成空的：多張圖片也一起清掉
      _settings.copyMarksFrom(WatermarkSettings(text: TextMark(text: '')));
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
    final track = c.track;
    setState(() {
      _tl.clips.remove(c);
      _sel = -1;
    });
    _resyncPlayback();
    // 刪掉會留一個洞，自動整理開著就補起來。
    // 軌號要先存：這時候選取已經清掉，問不到是哪一軌了
    _autoTidyIfOn(track: track);
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
      // 調好位置大小的疊圖會跳回置中原尺寸、倒轉的片段會變正播
      speed: cb.speed,
      reverse: cb.reverse,
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
    // 草稿還有沒落地的併批寫入：離開前補存，不能讓最後幾秒的編輯蒸發
    if (_draftSaveTimer?.isActive ?? false) {
      _draftSaveTimer!.cancel();
      _saveDraftNow();
    }
    _frameSettle?.cancel();
    _playProbe?.cancel();
    unawaited(Diag.deactivateAudio());
    unawaited(_comp?.dispose() ?? Future<void>.value());
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
    // 空專案匯出＝叫 FFmpeg 產一支 0 秒的黑畫布，只會拿到一串
    // 看不懂的錯誤訊息。直接講人話擋下來
    if (_tl.clips.isEmpty) {
      showHint(context, '時間軸還是空的，先用「加素材」放點東西進來', error: true);
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
          crf: _qualityEff.crf,
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
      // 成功的訊息交給下面的「輸出完成」視窗講，這裡只處理失敗／取消。
      // 取消是使用者自己的決定，用中性提示就好，不當錯誤
      if (!ok) {
        showHint(
          context,
          message,
          error: !cancelled,
          duration: Duration(seconds: cancelled ? 3 : 8),
        );
      }
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
        _ensureScrubSlots(i, s.duration);
      }
    }
    for (final i in {
      for (final c in _tl.clips)
        if (c.reverse) c.sourceIndex,
    }) {
      final s = _tl.sources[i];
      _makeScrubCache(i, s.path, s.duration);
    }
    // 問下一步一定要放在所有清理之後：選了回主畫面這頁就收掉，
    // 圖片快取上限沒還原的話整個 App 的快取會一直是關著的
    if (ok && mounted) {
      final home = await askAfterExport(context, message) == 'home';
      // popUntil 不經過 PopScope，不會再跳一次「要不要留草稿」——
      // 草稿本來就一直有存，這裡直接走
      if (home && mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
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
          constraints: const BoxConstraints(maxWidth: kDialogWidth),
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
      // 離開前要真的落地，不能等併批計時器（頁面要關了）
      _draftSaveTimer?.cancel();
      await _saveDraftNow();
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
        appBar: AppBar(
          // 長按標題＝打開播放診斷。藏在這裡是刻意的：一般使用者
          // 不會誤觸，要用的時候講一聲就找得到
          title: GestureDetector(
            onLongPress: _openTrace,
            child: const Text('影片編輯'),
          ),
        ),
        // 素材還在備就整頁擋著等它做完。使用者的原話是「既然一定要跑
        // 讀取，那請改成先跑一下讀取再進入，比進入後閃東閃西讀取還好」
        body: !_ready || _prepGate
            ? _buildPrepGate()
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
                              controller: _wmPanelCtrl,
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
              onPressed: () {
                if (_playing) {
                  _pause();
                } else {
                  unawaited(_play());
                }
              },
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
                  tooltip: '上一步',
                  color: _undoStack.isEmpty ? kTextDim : kText,
                  icon: const Icon(Icons.undo),
                  onPressed: _undoStack.isEmpty ? null : _undoAction,
                ),
                IconButton(
                  iconSize: 20,
                  tooltip: '重做',
                  color: _redoStack.isEmpty ? kTextDim : kText,
                  icon: const Icon(Icons.redo),
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
          color: kPreviewBg,
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
                                  // 點擊判定用的位置表，跟著畫面一起重建
                                  _hitBoxes.clear();
                                  Rect? selRect;
                                  TimelineClip? selVisual;

                                  // 圖層的上下關係一律照時間軸的軌道來：
                                  // track 大的是下層、先畫。影片與圖片／文字
                                  // 混在同一條 z 序裡排——以前是「所有影片
                                  // 先畫、圖片文字永遠疊在上面」，時間軸上
                                  // 把圖片搬到影片下面也沒有用
                                  //
                                  // 兩張表分別對應 children 前段與 _hitBoxes，
                                  // 用同一個規則插入，畫面順序跟點擊順序才會一致
                                  //（_hitBoxes 由後往前找＝由上往下）
                                  final layerTracks = <int>[];
                                  final hitTracks = <int>[];
                                  int slotIn(List<int> tracks, int track) {
                                    var i = 0;
                                    while (i < tracks.length &&
                                        tracks[i] >= track) {
                                      i++;
                                    }
                                    return i;
                                  }

                                  void addLayer(int track, Widget w) {
                                    final i = slotIn(layerTracks, track);
                                    children.insert(i, w);
                                    layerTracks.insert(i, track);
                                  }

                                  void addHit(int track, int id, Rect rect) {
                                    final i = slotIn(hitTracks, track);
                                    _hitBoxes.insert(i, (id: id, rect: rect));
                                    hitTracks.insert(i, track);
                                  }

                                  // 暖身用的隱形影片永遠壓在最底下（見下面的
                                  // 預掛載），馬賽克永遠在最上面——它是對
                                  // 「合成後的畫面」做的效果，匯出端也是最後
                                  // 才套，跟著軌道排的話會糊不到上層的東西
                                  const warmTrack = 999;
                                  const mosaicTrack = -999;

                                  // 影片圖層（由下層往上疊 = 真 PiP）
                                  final vids = _tl.videosAt(_position);
                                  // 播放中：快進場的影片先以幾乎看不見
                                  // 的透明度掛在最底層——材質先附著、
                                  // 第一幀先畫上去，跨過交界只是變回
                                  // 不透明。到交界才掛材質的話，
                                  // 掛上到第一幀之間就是那個黑閃
                                  final warmIds = <int>{};
                                  if (_playing) {
                                    for (final c in _tl.clips) {
                                      if (!_tl.sourceOf(c).isVideo) continue;
                                      final lead = c.offset - _position;
                                      if (lead <= 0 || lead > 1.2) continue;
                                      final ct = _ctrls[c.id];
                                      if (ct == null ||
                                          !ct.value.isInitialized) {
                                        continue;
                                      }
                                      warmIds.add(c.id);
                                      vids.insert(0, c);
                                    }
                                  }
                                  // 合成播放器接手時，畫面就是它那一張材質
                                  //（整條時間軸都在裡面），不再逐片段疊圖層
                                  if (_compOn) {
                                    final cur = _tl.videoAt(_position);
                                    final rect = Rect.fromLTWH(0, 0, w, h);
                                    if (cur != null) {
                                      addHit(cur.track, cur.id, rect);
                                      // 選中的影片片段要在預覽上有框。
                                      // 逐片段圖層被整批換成一層合成畫面時，
                                      // 只搬了畫面沒搬選取框——框是在那個
                                      // 迴圈裡設的，而合成這條路不會跑到它
                                      if (cur.id == _sel) {
                                        final s = _tl.sourceOf(cur);
                                        selRect = layerBox(cur, s.aspect);
                                        selVisual = cur;
                                      }
                                    }
                                    addLayer(
                                      cur?.track ?? 0,
                                      Positioned.fromRect(
                                        rect: rect,
                                        // 兩條路：系統的影片圖層（跟相簿
                                        // 播放同一條，零複製）或 Flutter
                                        // 材質（影格要複製一次再合成）
                                        child: Diag.playerLayer.value
                                            ? const UiKitView(
                                                viewType: 'markcut/player_view',
                                              )
                                            : FittedBox(
                                                fit: BoxFit.contain,
                                                child: SizedBox(
                                                  width: _comp!.width,
                                                  height: _comp!.height,
                                                  child: Texture(
                                                    textureId:
                                                        _comp!.textureId,
                                                  ),
                                                ),
                                              ),
                                      ),
                                    );
                                    vids.clear();
                                  }
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
                                        // 這條路走的是「播放器還沒好」，
                                        // 暖身片段一定有播放器，不會到這裡
                                        addHit(c.track, c.id, rf);
                                        addLayer(
                                          c.track,
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
                                    final warm = warmIds.contains(c.id);
                                    final vTrack = warm ? warmTrack : c.track;
                                    addHit(vTrack, c.id, r);
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
                                        //
                                        // 合成播放器接手時不疊快取幀：畫面
                                        // 直接來自系統影片圖層，追時 seek
                                        // 本來就跟得上手指。再疊一層抽幀
                                        // 反而是拿「現抽 4K 原檔」蓋掉它，
                                        // 那才是拖曳變成一格一格的原因
                                        ((_scrubbing && !_compOn) ||
                                            c.reverse ||
                                            (_colorMode && kIsWeb))
                                        ? _scrubFrames[c.sourceIndex]
                                        : null;
                                    addLayer(
                                      vTrack,
                                      Positioned.fromRect(
                                        // 整層掛 key：交界那一格上一段會從
                                        // children 裡消失，後面每一層的索引
                                        // 都往前推一格。沒有 key 的話 Flutter
                                        // 是按位置配對的，這些層會被當成
                                        // 「換了個東西」重建——影片圖層一重建
                                        // 就要重新掛貼圖，那就是交界的閃爍。
                                        // 有 key 就認得出是同一層，只是換位置
                                        key: ValueKey('vidlayer${c.id}'),
                                        // 暖身的隱形圖層只畫 1 像素。它的
                                        // 用途是「先把材質掛上、把第一幀解
                                        // 出來」好讓交界不閃黑，那跟畫多大
                                        // 無關；以前是整面畫著只是幾乎全
                                        // 透明，等於交界前那 350ms 合成
                                        // 執行緒都在多畫一整張影片材質。
                                        // 只改大小不改結構：元件樹一樣，
                                        // 材質不會被拆掉重掛（那才會閃）
                                        rect: warm
                                            ? const Rect.fromLTWH(0, 0, 1, 1)
                                            : r,
                                        child: _tinted(
                                          c,
                                          Opacity(
                                            opacity: warm
                                                ? 0.006
                                                : c.fadeFactorAt(_position),
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
                                                        final f =
                                                            _nearestFrame(
                                                              frames,
                                                              fi,
                                                            ) ??
                                                            _nfLatest[c
                                                                .sourceIndex];
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
                                                // （預掛的隱形影片不收點擊）
                                                if (!warm)
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
                                    if (c.id == _sel && !warm) {
                                      selRect = r;
                                      selVisual = c;
                                    }
                                  }

                                  // 圖片 / 文字圖層（插進上面那條 z 序，
                                  // 位置由自己的軌道決定）
                                  for (final c in _tl.overlaysAt(_position)) {
                                    final src = _tl.sourceOf(c);
                                    if (src.kind == ClipKind.mosaic) {
                                      final r = layerBox(c, 1.0);
                                      addHit(mosaicTrack, c.id, r);
                                      addLayer(
                                        mosaicTrack,
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
                                                  // 柔邊：6 圈同心疊加,
                                                  // 中心累積較糊、邊緣輕,
                                                  // 看不出圈與圈的階梯
                                                  //（跟匯出的漸進圈同思路）
                                                  final sg =
                                                      (4.0 + 16 * ms.strength) *
                                                      0.4;
                                                  final step =
                                                      ms.feather *
                                                      0.07 *
                                                      math.min(
                                                        r.width,
                                                        r.height,
                                                      );
                                                  Widget ring(
                                                    double i,
                                                  ) => Positioned(
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
                                                            const SizedBox.expand(),
                                                      ),
                                                    ),
                                                  );
                                                  return Stack(
                                                    children: [
                                                      for (
                                                        var i = 0;
                                                        i < 6;
                                                        i++
                                                      )
                                                        ring(step * i),
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
                                                    filter = ui
                                                        .ImageFilter.shader(sh);
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
                                                    child:
                                                        const SizedBox.expand(),
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
                                    if (src.kind == ClipKind.image) {
                                      final r = layerBox(c, src.aspect);
                                      addHit(c.track, c.id, r);
                                      final bytes = _thumbs[c.sourceIndex];
                                      final hasBytes =
                                          bytes != null && bytes.isNotEmpty;
                                      addLayer(
                                        c.track,
                                        Positioned.fromRect(
                                          rect: r,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              if (hasBytes)
                                                _tinted(
                                                  c,
                                                  Opacity(
                                                    opacity: c.fadeFactorAt(
                                                      _position,
                                                    ),
                                                    child: Image.memory(
                                                      bytes[0],
                                                      fit: BoxFit.fill,
                                                      gaplessPlayback: true,
                                                    ),
                                                  ),
                                                )
                                              else
                                                // 讀不到圖片位元組時也要畫個東西：
                                                // 什麼都不畫的話這段素材在畫面上
                                                // 等於不存在，使用者點不到也刪不掉
                                                Container(
                                                  color: kPanelHi.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: const Text(
                                                    '圖片讀不到了',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: kTextDim,
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
                                      addLayer(
                                        c.track,
                                        Positioned.fill(
                                          child: Opacity(
                                            opacity: c.fadeFactorAt(_position),
                                            child: WatermarkLayer(
                                              settings: st,
                                              onChanged: () => setState(() {}),
                                              onDragStart: _pushUndo,
                                              time: pos,
                                              onHitBox: (t, l) =>
                                                  _addWmHit(c.id, t, l),
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
                                                _wmPanelCtrl.scrollTo(
                                                  WmPart.logo,
                                                );
                                              },
                                              // 點文字＝面板直接捲到
                                              // 文字設定，不用自己找
                                              onTapText: () {
                                                setState(() {
                                                  _sel = c.id;
                                                  _wmSel = false;
                                                });
                                                _tabs.animateTo(1);
                                                _wmPanelCtrl.scrollTo(
                                                  WmPart.text,
                                                );
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
                                      addHit(c.track, c.id, r);
                                      addLayer(
                                        c.track,
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

                                  // 中央點擊判定層：疊在所有素材之上，
                                  // 統一決定點到的是哪一層（各素材自己的
                                  // onTap 只有在這層之上才輪得到）。
                                  // translucent＝只搶點擊，拖曳照樣傳給下面
                                  children.add(
                                    Positioned.fill(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onTapUp: (d) =>
                                            _tapSelectAt(d.localPosition),
                                      ),
                                    ),
                                  );

                                  // 選取中的圖層：細白框＋四角把手 + 拖曳移動 / 雙指縮放
                                  if (selRect != null && selVisual != null) {
                                    final sc = selVisual;
                                    children.add(
                                      Positioned.fromRect(
                                        rect: selRect,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          // 選取框疊在別的素材上面，這裡也要走
                                          // 同一套判定——不然被選中的那層會把
                                          // 重疊處整個吃掉，再也切不到下面那層
                                          onTapUp: (d) => _tapSelectAt(
                                            selRect!.topLeft + d.localPosition,
                                          ),
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
                                        onHitBox: (t, l) =>
                                            _addWmHit(_kWmId, t, l),
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
                                        // 點浮水印 Logo＝選取＋切到浮水印
                                        // 分頁，面板捲到圖片設定
                                        onTap: () {
                                          setState(() {
                                            _wmSel = true;
                                            _sel = -1;
                                          });
                                          _tabs.animateTo(1);
                                          _wmPanelCtrl.scrollTo(WmPart.logo);
                                        },
                                        // 點浮水印文字＝切到浮水印分頁並
                                        // 捲到文字設定。不直接跳鍵盤——
                                        // 要改字在面板裡改
                                        onTapText: () {
                                          setState(() {
                                            _wmSel = true;
                                            _sel = -1;
                                          });
                                          _tabs.animateTo(1);
                                          _wmPanelCtrl.scrollTo(WmPart.text);
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
                                            _rtStartFocal = d.focalPoint;
                                            _rtArmed = false;
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
                                            // 起手門檻：手指移超過 6px
                                            // 才開始搬。點一下要選取、
                                            // 或抬手時的一點點位移，
                                            // 都不該把素材推歪幾個像素
                                            if (!_rtArmed) {
                                              if (d.pointerCount < 2 &&
                                                  (d.focalPoint - _rtStartFocal)
                                                          .distance <
                                                      6) {
                                                _routerLast = d.focalPoint;
                                                return;
                                              }
                                              _rtArmed = true;
                                              // 起算點移到「越過門檻的這
                                              // 一刻」，不然會憑空跳 6px
                                              _gestureStartFocal = d.focalPoint;
                                              _routerLast = d.focalPoint;
                                            }
                                            // 抬手那一下的小位移不在這裡濾，
                                            // 已經在事件進手勢辨識之前擋掉了
                                            //（見 SteadyPointerBinding）
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
                                                // 圖片可以有很多張，
                                                // 整組一起搬
                                                final live = [
                                                  for (final l
                                                      in wmClipStyle.logos)
                                                    if (l.enabled && !l.tiled)
                                                      l,
                                                ];
                                                final tAlive =
                                                    t2.enabled &&
                                                    !t2.tiled &&
                                                    t2.text.trim().isNotEmpty;
                                                if (tAlive || live.isNotEmpty) {
                                                  _routerPushUndoIfNeeded();
                                                  moved = true;
                                                  if (_rtRawX == null) {
                                                    _rtRawX = tAlive
                                                        ? t2.x
                                                        : live.first.x;
                                                    _rtRawY = tAlive
                                                        ? t2.y
                                                        : live.first.y;
                                                    _rtRawLogos = [
                                                      for (final l in live)
                                                        Offset(l.x, l.y),
                                                    ];
                                                  }
                                                  _rtRawX = (_rtRawX! + ddx)
                                                      .clamp(0.0, 1.0);
                                                  _rtRawY = (_rtRawY! + ddy)
                                                      .clamp(0.0, 1.0);
                                                  for (
                                                    var i = 0;
                                                    i < _rtRawLogos.length;
                                                    i++
                                                  ) {
                                                    final r = _rtRawLogos[i];
                                                    _rtRawLogos[i] = Offset(
                                                      (r.dx + ddx).clamp(
                                                        0.0,
                                                        1.0,
                                                      ),
                                                      (r.dy + ddy).clamp(
                                                        0.0,
                                                        1.0,
                                                      ),
                                                    );
                                                  }
                                                  final sx = _snapC(_rtRawX!);
                                                  final sy = _snapC(_rtRawY!);
                                                  final cx = sx - _rtRawX!;
                                                  final cy = sy - _rtRawY!;
                                                  // 領頭吸中線，其餘的加同一個
                                                  // 修正量，相對位置不會被吸歪。
                                                  // 沒有文字時領頭是第一張圖
                                                  final from = tAlive ? 0 : 1;
                                                  if (tAlive) {
                                                    t2.x = sx;
                                                    t2.y = sy;
                                                  } else {
                                                    live.first.x = sx;
                                                    live.first.y = sy;
                                                  }
                                                  for (
                                                    var i = from;
                                                    i < live.length &&
                                                        i < _rtRawLogos.length;
                                                    i++
                                                  ) {
                                                    live[i].x =
                                                        (_rtRawLogos[i].dx + cx)
                                                            .clamp(0.0, 1.0);
                                                    live[i].y =
                                                        (_rtRawLogos[i].dy + cy)
                                                            .clamp(0.0, 1.0);
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
                                  // 置中輔助線（路由拖曳吸到中線時）。
                                  // 無條件插入，跟照片／工作室同一種寫法：
                                  // 用 if 增減會把後面圖層的索引推掉、
                                  // 手勢層被重建＝拖曳中斷。目前它排在最後
                                  // 所以剛好沒事，但下次有人往後再加一層就會踩到
                                  children.add(
                                    Positioned.fill(
                                      child: CenterGuides(
                                        vertical: _rtGuideV,
                                        horizontal: _rtGuideH,
                                      ),
                                    ),
                                  );

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
              // 工作檔在背景備，不出現在畫面上：進場就能剪，
              // 好了自己換過去。別家剪輯 App 也沒有那個讀取條
            ],
          ),
        ),
      ),
    );
  }

  // ===== 預覽區雙指縮放（選取中的浮水印或片段）=====
  final Map<int, Offset> _pvPts = {};

  /// 預覽拖曳的起手門檻用：這次手勢按下去的位置，以及「已經越過
  /// 門檻、可以開始搬」的旗標（見 onScaleUpdate）
  Offset _rtStartFocal = Offset.zero;
  bool _rtArmed = false;

  /// 選取路由的上一個拖曳點（算增量用）
  Offset _routerLast = Offset.zero;

  // ===== 選取路由的置中吸附（跟 WatermarkLayer 內建拖曳同手感）=====
  /// 未吸附的原始座標（吸附只作用在顯示值上，不然吸上就拖不出來）
  double? _rtRawX, _rtRawY;

  /// 浮水印片段整組移動時，每一張圖片的未吸附原始座標
  List<Offset> _rtRawLogos = [];

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
  /// 進場的讀取畫面（元件在 widgets/prep_gate_view.dart）
  Widget _buildPrepGate() => PrepGateView(
    done: _prepDone,
    total: _prepTotal,
    fraction: _prepFraction,
    ready: _ready,
    onSkip: _prepEscapeReady
        ? () => setState(() => _prepSkipped = true)
        : null,
  );

  Widget _canvasHint() {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(kTagRadius),
          onTap: _openRatioSheet,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(kTagRadius),
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
  /// 工具列群組分隔線（剪輯｜樣式｜工具）
  Widget _toolDivider() => Container(
    width: 1,
    height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 5),
    color: kBorder,
  );

  Widget _toolBtn(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    String? tip,
    // 按鈕灰掉時點下去的提示——沒提示的話新手不知道為什麼不能按
    String? disabledHint,
    int quarterTurns = 0,
    // 開關型按鈕開啟時的顏色（磁吸、整理）。null＝一般按鈕
    Color? color,
  }) {
    final on = onTap != null;
    color ??= on ? kText : kTextDim.withValues(alpha: 0.4);
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
                                onTrimStart: _trimGestureStart,
                                onTrimEnd: _autoTidyIfOn,
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
                                  // 時間軸還沒有素材時長度是 0，這時把終點
                                  // 寫死等於把「跟到結尾」變成 0 長度
                                  _wmEnd = len <= 0 ? null : s + len;
                                }),
                                onTrimWmStart: _trimGestureStart,
                                onTrimWm: _trimWatermark,
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
                      _toolDivider(),
                      // 直向的 compress 轉 90°＝把左右的空隙擠掉。
                      // 跟磁吸一樣是開關：開著就自動接齊
                      _toolBtn(
                        Icons.compress,
                        '整理',
                        _toggleAutoTidy,
                        tip: _autoTidy
                            ? '自動整理：開（剪短後自動接齊，點一下關掉）'
                            : '自動整理：關（點一下打開，並立刻接齊一次）',
                        quarterTurns: 1,
                        color: _autoTidy ? kSelect : null,
                      ),
                      _toolBtn(
                        Icons.swap_vert,
                        '排序',
                        _openReorderSheet,
                        tip: '用清單調整素材的先後順序',
                      ),
                      _snapToolBtn(),
                      _toolBtn(Icons.add, '加素材', _addMediaChoice),
                      _toolDivider(),
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
                      // 音量／效果分開兩顆：以前擠在同一張表裡，
                      // 想調音量的人得先看懂「效果」是什麼
                      _toolBtn(
                        Icons.volume_up,
                        '音量',
                        (sel == null || !_clipHasAudio(sel))
                            ? null
                            : () => _openVolumeSheet(sel),
                        tip: '這段的音量',
                        disabledHint: sel == null ? '先在時間軸點選一個片段' : '這個素材沒有聲音',
                      ),
                      _toolBtn(
                        Icons.gradient,
                        '效果',
                        sel == null ? null : () => _openFadeSheet(sel),
                        tip: '淡入淡出',
                        disabledHint: '先在時間軸點選一個片段',
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
                    return optionRow(
  context: context,
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
                  const Icon(Icons.open_in_full, size: 18, color: kAmber),
                  const SizedBox(width: 8),
                  const Text(
                    '大小',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
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

  /// 這個素材有沒有聲音可以調
  bool _clipHasAudio(TimelineClip c) {
    final k = _tl.sourceOf(c).kind;
    return k == ClipKind.video || k == ClipKind.audio;
  }

  /// 兩張設定表共用的滑桿列
  Widget _optRow({
    required String label,
    required double value,
    required double max,
    required String suffix,
    required ValueChanged<double> onChanged,
    Widget? leading,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child:
              leading ??
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: kTextDim),
              ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0, max),
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: kSliderValueW,
          child: Text(
            suffix,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, color: kTextDim),
          ),
        ),
      ],
    );
  }

  /// 設定表的外框（標題＋內容）
  Future<void> _optSheet(
    String title,
    Widget Function(StateSetter setSheet) body,
  ) {
    _pushUndo();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                body(setSheet),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(_saveDraft);
  }

  /// 音量：滑桿＋一鍵靜音＋套用到全部
  void _openVolumeSheet(TimelineClip clip) {
    // 按靜音之前的音量，再按一次原音量回來
    var lastVol = clip.volume > 0 ? clip.volume : 1.0;
    final audioCount = _tl.clips.where(_clipHasAudio).length;
    _optSheet('音量', (setSheet) {
      void setVol(double v) {
        setSheet(() {});
        setState(() {
          clip.volume = v;
          _ctrls[clip.id]?.setVolume(v.clamp(0.0, 1.0));
        });
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _optRow(
            label: '音量',
            value: clip.volume,
            // 上限就是 100%（原始音量）。放大要靠 FFmpeg 重算取樣，
            // 預覽的播放器做不到，開放了只會讓預覽跟成品對不起來
            max: 1,
            suffix: '${(clip.volume * 100).round()}%',
            onChanged: setVol,
            // 喇叭圖示可以點＝快速靜音／取消靜音
            leading: InkWell(
              onTap: () {
                if (clip.volume > 0) {
                  lastVol = clip.volume;
                  setVol(0);
                } else {
                  setVol(lastVol);
                }
              },
              child: Row(
                children: [
                  Icon(
                    clip.volume > 0 ? Icons.volume_up : Icons.volume_off,
                    size: 16,
                    color: clip.volume > 0 ? kTextDim : kSelect,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    '音量',
                    style: TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ],
              ),
            ),
          ),
          // 一段一段調太累：一鍵套到所有有聲音的素材
          if (audioCount > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    for (final c in _tl.clips) {
                      if (!_clipHasAudio(c)) continue;
                      c.volume = clip.volume;
                      _ctrls[c.id]?.setVolume(c.volume.clamp(0.0, 1.0));
                    }
                  });
                  showHint(
                    context,
                    '全部 $audioCount 個素材都設成 '
                    '${(clip.volume * 100).round()}%',
                  );
                },
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('套用到全部素材', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      );
    });
  }

  /// 效果：進場／退場的淡化（畫面與聲音一起）
  void _openFadeSheet(TimelineClip clip) {
    _optSheet('效果', (setSheet) {
      Widget row(String label, double value, ValueChanged<double> set) =>
          _optRow(
            label: label,
            value: value,
            max: 3,
            suffix: '${value.toStringAsFixed(1)}s',
            onChanged: (v) {
              setSheet(() {});
              setState(() => set(v));
            },
          );

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('淡入', clip.fadeIn, (v) => clip.fadeIn = v),
          row('淡出', clip.fadeOut, (v) => clip.fadeOut = v),
          Padding(
            padding: const EdgeInsets.only(left: 56, top: 2),
            child: Text(
              _clipHasAudio(clip) ? '畫面與聲音一起淡' : '這個素材沒有聲音，只淡畫面',
              style: const TextStyle(fontSize: 10.5, color: kTextDim),
            ),
          ),
        ],
      );
    });
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
      // 簡易倒轉的預覽只能吃密集快取幀，這支素材照舊整條抽
      if (!kIsWeb) _makeScrubCache(c.sourceIndex, src.path, src.duration);
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
      final s2 = _tl.sourceOf(cur);
      _makeScrubCache(cur.sourceIndex, s2.path, s2.duration);
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
    _thumbStrip(made, segLen).then((t) {
      if (mounted && t.isNotEmpty) setState(() => _thumbs[newIdx] = t);
    });
    _ensureScrubSlots(newIdx, segLen);
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
    ).whenComplete(() {
      // 變速會改變片段長度＝可能留下空隙。改在關掉選單時整理，
      // 而不是每動一次滑桿就整理——拖的過程中後面的素材會一直跳
      _autoTidyIfOn();
      _saveDraft();
    });
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

  /// 這個專案用某一檔畫質匯出大概多大（MB）。
  /// 照引擎實際會下的位元率算（kbpsFor），不再另外維護一套估算公式
  /// ——舊公式用固定 0.09bpp 乘倍率，跟編碼器拿到的 -b:v 是兩回事，
  /// 「高畫質」估 15MB 實際會出 26MB。音訊 AAC 256k ≈ 32KB/s
  double _estMb(ExportQuality q) {
    final (w, h) = computeCanvasSize(_tl, _resolution, _canvasRatio);
    final dur = _tl.duration / _speed;
    final kbps = q.kbpsFor(w, h, fps: outputFps(_srcFps, w, h));
    return (kbps * 125.0 + 32000) * dur / (1024 * 1024);
  }

  /// 匯出頁（使用者選定 B 款極簡設定列）：

  /// 資訊列（比例／解析度／畫質）＋預估一行＋匯出鈕
  Widget _buildExportTab() {
    final (outW, outH) = computeCanvasSize(_tl, _resolution, _canvasRatio);
    final dur = _tl.duration / _speed;
    final mb = _estMb(_qualityEff);

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
              const SizedBox(width: 12),
              // 值比標籤小一階也更淡：標籤是「這一列在講什麼」，
              // 值是內容。兩者一樣大的話整頁沒有主次，掃不動
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: kTextDim,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 3),
                const Icon(Icons.chevron_right, size: 13, color: kIcon),
              ],
            ],
          ),
        ),
      );
    }

    // 內容垂直置中；空間不夠（大字級、小螢幕）才變成可以捲。
    // 這一頁只有三列加一顆鈕，靠上排會在下面留一大塊空白
    return LayoutBuilder(
      builder: (context, cons) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: cons.maxHeight - 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row('畫面比例', _canvasRatio.label, _openRatioSheet),
              row(
                '解析度',
                '${_resolution.label}·$outW×$outH',
                _openResolutionSheet,
              ),
              // 自動挑的時候標出來：不講的話，同一支 App 在不同素材上
              // 預設值不一樣會像壞掉
              row(
                '畫質',
                _qualityAuto && _srcKbps > 0
                    ? '${_qualityEff.label}·推薦'
                    : _qualityEff.label,
                _openQualitySheet,
                divider: false,
              ),
              const SizedBox(height: 22),
              // 預估貼在匯出鈕正上方。它唯一的用途就是讓人在按下去之前
              // 決定要不要回頭改設定，放在最靠近手指的地方最有用。
              // 匯出時間跑過一次之後才是「這台機器」的實測值，
              // 第一次只能粗估，標示清楚不要讓人以為很準
              FutureBuilder<(double, bool)>(
                future: _estimateExport(outW, outH, dur),
                builder: (context, snap) {
                  final d = snap.data;
                  final t = d == null
                      ? '計算中…'
                      : '需要約 ${fmtDuration(d.$1)}${d.$2 ? '' : '（粗估）'}';
                  return Text(
                    '約 ${mb.toStringAsFixed(0)} MB·$t',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: kTextDim,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              // 跟照片／批次／拼圖同一顆（膠囊、46 高、圖示 18）。
              // 這一頁的「結構」維持分頁不變，只有按鈕外觀對齊
              primaryAction(
                label: '匯出',
                onPressed: _exporting ? null : _export,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 畫質：置中彈窗。副標拿掉，改成右邊直接列這個專案各檔位的檔案大小——
  /// 「極高」跟「最高」用形容詞永遠比不出來，數字一眼就分得出
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
              for (final (i, q) in qualityOrder.indexed)
                optionRow(
  context: context,
                  title: q.label,
                  subtitle: q.note,
                  // 自動挑到的那一檔＝壓到看不出跟原素材有差的點。
                  // 不寫「視覺無損」是因為素材超過上限時會停在極高，
                  // 那時它並不是無損，但仍然是這裡最該選的一檔
                  badge: _qualityAuto && _srcKbps > 0 && _qualityEff == q
                      ? '推薦'
                      : null,
                  trailing:
                      '約 ${_estMb(q).clamp(1, 1e9).toStringAsFixed(0)} MB',
                  selected: _qualityEff == q,
                  first: i == 0,
                  onTap: () {
                    setState(() {
                      _quality = q;
                      _qualityAuto = false; // 手動選過就不再自動改
                    });
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
                    final (ow, oh) = computeCanvasSize(
                      _tl,
                      ExportResolution.original,
                      _canvasRatio,
                    );
                    // 素材本身就比這一級小的時候，縮不下去＝跟原片同尺寸，
                    // 這種情況直接講白，不要讓人以為選了沒反應
                    final same =
                        r != ExportResolution.original && w == ow && h == oh;
                    return optionRow(
  context: context,
                      title: r.label,
                      subtitle: same ? '$w×$h·原片就這麼大，不會再縮' : '$w×$h·${r.hint}',
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
/// 預覽上的選取框。
///
/// 琥珀不用白：這個框疊的是使用者的照片／影片，白框落在白色縮圖或
/// 亮背景上會整個看不見
class _SelectionFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = kSelect,
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
