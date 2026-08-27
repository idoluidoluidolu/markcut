import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
// XFile 也是從這裡再匯出的，不用另外 import image_picker
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import '../services/media_prep.dart';
import '../services/native_frames.dart';
import '../services/photo_saver.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../services/watermark_renderer.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';
import '../widgets/edge_back.dart';

/// 批次浮水印：一次選多個檔案（照片/影片混合），
/// 批次浮水印的草稿鍵（個人頁「未完成的批次」讀這裡）
const kBatchDraftKey = 'batch_draft_v1';

/// 統一調一組浮水印，整批匯出到相簿
class BatchWatermarkScreen extends StatefulWidget {
  final List<XFile> files;

  /// 從草稿續作：整批共用設定與各張的單張覆寫（見 kBatchDraftKey）
  final Map<String, dynamic>? restore;

  /// 進場時要顯示的提示（例如「已略過 N 個非影片檔案」）。
  /// 在前一頁 show 的話會被這頁蓋住，根本看不到
  final String? initialHint;

  const BatchWatermarkScreen({
    super.key,
    required this.files,
    this.initialHint,
    this.restore,
  });

  @override
  State<BatchWatermarkScreen> createState() => _BatchWatermarkScreenState();
}

/// 批次清單裡的一個檔案（縮圖與尺寸載入後補上）
///
/// 這裡只留「小縮圖」——原檔 bytes 一律不留，要用的時候（大預覽、匯出）
/// 才回頭讀。一張 12MP 照片解出來是 48MB 的點陣圖，全部留著幾十張就爆了
/// 上一步的一筆：itemIndex >= 0 代表這一步改的是那一張的單張設定，
/// -1 代表改的是整批共用設定
class _UndoStep {
  final int itemIndex;
  final String json;

  const _UndoStep(this.itemIndex, this.json);
}

class _BatchItem {
  final XFile file;
  Uint8List? thumb;
  (int, int)? dims;

  /// 檔案大小估計用的快取：影片長度（秒）與原檔位元數。
  /// 問過一次就記住，畫質視窗重開不用重探
  double? durSec;
  int? byteLen;

  /// 單張模式：這張有自己的浮水印設定（在預覽上調過就會建立），
  /// null＝跟著整批的設定走
  WatermarkSettings? override;
  _BatchItem(this.file);
}

class _BatchWatermarkScreenState extends State<BatchWatermarkScreen> {
  final _settings = WatermarkSettings();
  int _previewIndex = 0;

  /// 被選浮水印部件的框（畫在裁切外，拖出畫面也看得到位置）
  final _wmFrameInfo = ValueNotifier<WmFrameInfo?>(null);

  late final List<_BatchItem> _items = widget.files
      .map(_BatchItem.new)
      .toList();

  bool _exporting = false;
  bool _stopRequested = false;

  /// 整批共用的畫質。影片吃它的位元率檔位，照片存 JPEG 時吃
  /// [_jpegQuality]——一頁只問一次「畫質」，不要影片照片各一套。
  /// 預設「標準」跟以前寫死的值一致（影片 crf 17、照片 JPEG 92），
  /// 沒動過設定的人輸出結果不會變
  ExportQuality _quality = ExportQuality.standard;

  int get _jpegQuality => switch (_quality) {
    ExportQuality.low => 78,
    ExportQuality.standard => 92,
    ExportQuality.ultra => 96,
    ExportQuality.lossless => 100,
  };

  bool _isVideo(XFile f) {
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

  /// 「有沒有改過」的基準快照：進來時拍一次，匯出成功後重設
  late String _initialJson;

  /// 匯出畫布比例（原始＝跟素材一樣）。照片：黑底補到比例、像素
  /// 不縮水；影片：contain 進畫布（跟單支編輯器同一套數學）。
  /// 右上角那顆跟影片編輯器同一個位置（使用者指定）
  CanvasRatio _canvasRatio = CanvasRatio.original;
  CanvasRatio _initialRatio = CanvasRatio.original;

  /// 預覽放大：只留預覽、其他全收（跟影片編輯器右上角那顆一樣）
  bool _fsPreview = false;

  @override
  void initState() {
    super.initState();
    // 草稿續作：先還原設定，再拍基準（沒再改動就不會被問保留）
    final r = widget.restore;
    if (r != null) {
      try {
        _settings.copyMarksFrom(
          WatermarkSettings.fromJson(
            Map<String, dynamic>.from(r['settings'] as Map),
          ),
        );
        final ov = r['overrides'];
        if (ov is Map) {
          ov.forEach((k, v) {
            final i = int.tryParse('$k') ?? -1;
            if (i >= 0 && i < _items.length && v is Map) {
              try {
                _items[i].override = WatermarkSettings.fromJson(
                  Map<String, dynamic>.from(v),
                );
              } catch (_) {}
            }
          });
        }
        final ri = r['ratio'];
        if (ri is int && ri >= 0 && ri < CanvasRatio.values.length) {
          _canvasRatio = CanvasRatio.values[ri];
        }
      } catch (_) {}
    }
    _initialJson = jsonEncode(_settings.toJson());
    _initialRatio = _canvasRatio;
    // web：大預覽跟縮圖列同時各開一個 <video> 解同一支影片，
    // 其中一邊常常等不到（timeout 回空）而且永遠不重試——縮圖列
    // 就整排空白。錯開：先把大預覽讀完，再慢慢補縮圖。
    // 手機的抽幀走原生的單一工作緒，本來就不會互相搶
    if (kIsWeb) {
      _loadPreviewFull().then((_) {
        if (mounted) _loadPreviews();
      });
    } else {
      _loadPreviews();
      _loadPreviewFull();
    }
    final hint = widget.initialHint;
    if (hint != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showHint(context, hint);
      });
    }
  }

  // 匯出成功會把基準點重設（見 _exportAll），不能一匯出就永遠關掉保護
  /// 單張調整也算「改過」：只在預覽上拖過浮水印就離開，
  /// 原本會一聲不吭直接丟掉
  bool get _dirty =>
      jsonEncode(_settings.toJson()) != _initialJson ||
      _canvasRatio != _initialRatio ||
      _items.any((it) => it.override != null);

  /// 離開保護：調過浮水印但整批還沒匯出就問一下
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    // 跟影片、照片一樣可以保留草稿（實測回報：批次無法進入草稿）。
    // 存的是檔案路徑＋整批設定＋各張覆寫；下次從個人頁「未完成的
    // 批次」續作
    final act = await showLeaveChoice(
      context,
      title: '這批還沒匯出',
      // 全 App 統一的說法（使用者指定）
      message: '可以在個人頁面的「草稿」繼續未完成的編輯',
      keepLabel: '保留草稿',
    );
    if (!mounted) return;
    if (act == 'keep') {
      await _saveBatchDraft();
      if (mounted) Navigator.of(context).pop();
    } else if (act == 'discard') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBatchDraftKey);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _saveBatchDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kBatchDraftKey,
        jsonEncode({
          'files': [for (final it in _items) it.file.path],
          'settings': _settings.toJson(),
          'ratio': _canvasRatio.index,
          'overrides': {
            for (var i = 0; i < _items.length; i++)
              if (_items[i].override != null)
                '$i': _items[i].override!.toJson(),
          },
          'savedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  // ===== 選取（選了圖片就鎖定圖片：拖曳/縮放都只動它）=====
  /// 這頁本來完全沒有選取的概念：沒有白框、捏合永遠把文字和 Logo
  /// 一起縮（調好的搭配會被弄壞）、拖文字時手指滑過 Logo 會把 Logo
  /// 一起拖走。其他三個編輯畫面都有，這裡補齊
  WmPart _wmPart = WmPart.none;

  /// 被選部件還活著嗎（存在、非平鋪）；不活一律當沒選
  WmPart get _wmPartAlive {
    final st = _editTarget;
    final t = st.text;
    final lg = st.logo;
    return switch (_wmPart) {
      WmPart.text when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
        WmPart.text,
      WmPart.logo when lg.enabled && !lg.tiled => WmPart.logo,
      _ => WmPart.none,
    };
  }

  // ===== 上一步／重做（改壞了可以救；連續滑桿拖動 0.7 秒內併成一步）=====
  final List<_UndoStep> _undoStack = [];
  final List<_UndoStep> _redoStack = [];
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _sync = 0; // 通知面板同步內部狀態

  /// 點預覽上的浮水印時，叫下面的面板捲到對應的設定區塊
  final _wmPanelCtrl = WatermarkPanelController();

  /// 換一張預覽就清掉選取：那一張的部件不見得存在，
  /// 選取殘留會讓拖曳整個卡住
  void _clearWmSel() {
    if (_wmPart != WmPart.none) setState(() => _wmPart = WmPart.none);
  }

  void _pushUndo() {
    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < 700) return;
    _lastPush = now;
    // 連同「這一步是改哪一份設定」一起記：單張模式的上一步要還原到
    // 那一張的 override，還原到共用設定的話畫面完全沒反應
    final target = _singleNow ? _previewIndex : -1;
    _undoStack.add(_UndoStep(target, jsonEncode(_editTarget.toJson())));
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    _redoStack.clear(); // 改了新的東西，原本的重做路線就斷了
    setState(() {}); // 讓上一步鈕亮起來
  }

  /// 目前這一刻的快照（撤銷前先存起來，才回得去）
  _UndoStep get _snapshot => _UndoStep(
    _singleNow ? _previewIndex : -1,
    jsonEncode(_editTarget.toJson()),
  );

  /// 把一筆快照套回去
  void _applyStep(_UndoStep step) {
    final wm = WatermarkSettings.fromJson(
      jsonDecode(step.json) as Map<String, dynamic>,
    );
    // 那張後來被移除的話就跳過這一步
    if (step.itemIndex >= _items.length) return;
    final dst = step.itemIndex < 0
        ? _settings
        : (_items[step.itemIndex].override ??= _settings.copy());
    setState(() {
      if (step.itemIndex >= 0) _previewIndex = step.itemIndex;
      dst.copyMarksFrom(wm);
      _sync++;
    });
  }

  void _undoLast() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot);
    _applyStep(_undoStack.removeLast());
  }

  void _redoLast() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot);
    _applyStep(_redoStack.removeLast());
  }

  /// 條列縮圖的長邊：條列格子只有 56dp，160px 在高 DPR 螢幕也夠銳利
  static const _thumbLongSide = 160;

  /// 只讀檔頭拿長寬，不解整張圖
  static Future<(int, int)?> _dimsOf(Uint8List bytes) async {
    ui.ImmutableBuffer? buf;
    ui.ImageDescriptor? desc;
    try {
      buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      desc = await ui.ImageDescriptor.encoded(buf);
      return (desc.width, desc.height);
    } catch (_) {
      // web 的 ImageDescriptor 會丟例外——整段被外層 catch 吞掉、
      // 尺寸永遠量不到，畫布退到 16:9 預設（實測回報：批次的
      // 直片畫布永遠是橫的）。退回逐格解碼，每個平台都通
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final fr = await codec.getNextFrame();
        final d = (fr.image.width, fr.image.height);
        fr.image.dispose();
        codec.dispose();
        return d;
      } catch (_) {
        return null;
      }
    } finally {
      desc?.dispose();
      buf?.dispose();
    }
  }

  /// 解成小圖再重新編碼，這樣留在記憶體的是縮圖不是原檔
  static Future<Uint8List?> _shrink(Uint8List src, int longSide) async {
    ui.ImmutableBuffer? buf;
    ui.ImageDescriptor? desc;
    try {
      buf = await ui.ImmutableBuffer.fromUint8List(src);
      desc = await ui.ImageDescriptor.encoded(buf);
      final w = desc.width, h = desc.height;
      if (w == 0 || h == 0) return null;
      final long = w > h ? w : h;
      if (long <= longSide) return src; // 本來就夠小，不用多做一手
      final scale = longSide / long;
      final codec = await desc.instantiateCodec(
        targetWidth: (w * scale).round().clamp(1, longSide),
        targetHeight: (h * scale).round().clamp(1, longSide),
      );
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return png?.buffer.asUint8List();
    } catch (_) {
      // web 的 ImageDescriptor 會炸（跟 _dimsOf 同一個洞）：
      // 縮圖列因此整排空白。退回逐格解碼縮小，各平台都通
      try {
        final codec = await ui.instantiateImageCodec(
          src,
          targetWidth: longSide,
        );
        final frame = await codec.getNextFrame();
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        frame.image.dispose();
        codec.dispose();
        return png?.buffer.asUint8List() ?? src;
      } catch (_) {
        // 連解碼都不行就直接用原圖當縮圖：寧可肥一點也不能空白
        return src;
      }
    } finally {
      desc?.dispose();
      buf?.dispose();
    }
  }

  /// 一次把每個檔案的小縮圖備好；原檔讀完就丟。
  /// 迭代快照，不直接迭代 _items——載入中長按移除一張會讓
  /// 迭代器丟 ConcurrentModificationError，剩下的縮圖全載不出來
  /// 縮圖列最後那格「＋」：中途再加檔案進這一批。
  /// 相簿混選（影片照片都收），加進來直接套整批的浮水印設定
  Widget _addTile() {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: _exporting ? null : _addMoreFiles,
      child: Container(
        width: 40,
        decoration: BoxDecoration(
          color: kPanelHi,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kBorder),
        ),
        child: const Icon(Icons.add, size: 20, color: kIcon),
      ),
    );
  }

  Future<void> _addMoreFiles() async {
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty || !mounted) return;
    final added = picked.map(_BatchItem.new).toList();
    setState(() => _items.addAll(added));
    showHint(context, '已加入 ${added.length} 個檔案');
    // 縮圖與尺寸背景補上，跟進場時同一條路
    unawaited(_loadPreviews(only: added));
  }

  /// [only] 給了就只載那幾個（中途加進來的新檔案），不重抽整批
  Future<void> _loadPreviews({List<_BatchItem>? only}) async {
    final snapshot = List.of(only ?? _items);
    for (final item in snapshot) {
      if (!mounted) return;
      if (!_items.contains(item)) continue; // 中途被移除就跳過
      final f = item.file;
      try {
        if (_isVideo(f)) {
          // 條列用的小格，抽小的就好（大預覽另外抽 720p）
          var t = kIsWeb
              ? const <Uint8List>[]
              : await nativeStrip(f.path, 1, 1, maxH: 240);
          if (t.isEmpty) {
            t = await engine.makeThumbnails(f.path, 1, 1, height: 240);
          }
          if (t.isEmpty) {
            // web 的 <video> 抽格偶爾等不到（跟別的解碼搶），
            // 喘口氣再試一次，不要一翻車就整排空白
            await Future<void>.delayed(const Duration(milliseconds: 400));
            t = await engine.makeThumbnails(f.path, 1, 1, height: 240);
          }
          if (t.isNotEmpty) item.thumb = t.first;
          // 尺寸問影片本身（像素數精確），但「方向」以縮圖為準：
          // 縮圖兩條抽取路都套過旋轉、一定是顯示方向；probe 的
          // 旋轉旗標讀歪時畫布會轉 90 度，影片看起來超出畫布
          //（實測回報）。方向對不上就把 probe 的長寬對調。
          // 每一步各自 try：任何一步炸掉都不能讓「尺寸賦值」
          // 被跳過——以前整段一個 catch，炸在中途畫布就永遠 16:9
          (int, int)? d;
          (int, int)? td;
          try {
            final info = await engine.probeVideoInfo(f.path);
            if (info.w > 0 && info.h > 0) d = (info.w, info.h);
          } catch (_) {}
          try {
            if (t.isNotEmpty) td = await _dimsOf(t.first);
          } catch (_) {}
          if (d != null && td != null && td.$1 > 0 && td.$2 > 0) {
            final probePortrait = d.$1 < d.$2;
            final thumbPortrait = td.$1 < td.$2;
            final probeSquare = (d.$1 / d.$2 - 1).abs() < 0.02;
            if (!probeSquare && probePortrait != thumbPortrait) {
              d = (d.$2, d.$1);
            }
          }
          var dims = d ?? td;
          if (dims == null) {
            // 最後保底：跟單支編輯器同一招——開一顆播放器問尺寸
            //（它回報的一定是顯示方向），問完即丟
            try {
              final c = makeVideoController(f.path, system: true);
              try {
                await c.initialize();
                final s = c.value.size;
                if (s.width > 0 && s.height > 0) {
                  dims = (s.width.round(), s.height.round());
                }
              } finally {
                c.dispose();
              }
            } catch (_) {}
          }
          item.dims = dims;
        } else {
          final bytes = await f.readAsBytes();
          item.dims = await _dimsOf(bytes);
          item.thumb = await _shrink(bytes, _thumbLongSide);
          // bytes 到這裡就沒人參考了，交給 GC
        }
      } catch (_) {}
      if (mounted) setState(() {});
    }
  }

  /// 拿來呼叫面板的「存成範本」（按鈕搬到底部那一排了）
  final _panelKey = GlobalKey<WatermarkPanelState>();

  /// 左緣返回手勢的畫布排除區（見 EdgeBack）
  final _edgeCanvasKey = GlobalKey();

  // 大預覽只留「目前這一張」的高解析度，換張就換掉
  Uint8List? _previewBytes;
  int _previewLoadedFor = -1;

  Future<void> _loadPreviewFull() async {
    final i = _previewIndex;
    if (i < 0 || i >= _items.length) return;
    // 已經讀好同一張就不重讀；讀失敗過的（bytes 是 null）要能重試，
    // 不然那張永遠停在模糊縮圖
    if (i == _previewLoadedFor && _previewBytes != null) return;
    _previewLoadedFor = i;
    final f = _items[i].file;
    Uint8List? bytes;
    try {
      if (_isVideo(f)) {
        var t = kIsWeb
            ? const <Uint8List>[]
            : await nativeStrip(f.path, 1, 1, maxH: 720);
        if (t.isEmpty) {
          t = await engine.makeThumbnails(f.path, 1, 1, height: 720);
        }
        if (t.isNotEmpty) bytes = t.first;
      } else {
        bytes = await f.readAsBytes();
      }
    } catch (_) {}
    if (!mounted || _previewIndex != i) return;
    setState(() => _previewBytes = bytes);
  }

  void _selectPreview(int i) {
    // 點的就是目前這張：不要清掉已經讀好的大圖。
    // 清掉之後 _loadPreviewFull 會因為索引沒變而早退，
    // 預覽就永遠停在模糊的小縮圖
    if (i == _previewIndex && _previewBytes != null) return;
    setState(() {
      _previewIndex = i;
      _previewBytes = null; // 先清掉舊的，別讓兩張同時佔記憶體
      _sync++; // 換張＝面板換綁另一份設定，內部狀態要同步
      // 換一張的部件不見得存在，選取殘留會讓拖曳卡住
      _wmPart = WmPart.none;
    });
    _loadPreviewFull();
  }

  /// 長按縮圖＝從批次移除（要單獨處理的先踢出去）
  void _removeItem(int i) {
    if (_items.length <= 1) return;
    setState(() {
      _items.removeAt(i);
      // 移除的是前面那張時索引整個往前位移，
      // 不跟著減的話預覽會跳到隔壁張，使用者接著調的就是別張
      if (i < _previewIndex) {
        _previewIndex--;
      } else if (_previewIndex >= _items.length) {
        _previewIndex = _items.length - 1;
      }
      _previewBytes = null;
      _previewLoadedFor = -1; // 索引整個位移了，大預覽要重讀
    });
    _loadPreviewFull();
  }

  /// 這張實際生效的設定（有單張覆寫用覆寫，否則整批共用）
  WatermarkSettings _effectiveOf(int i) => _items[i].override ?? _settings;

  /// 編輯範圍開關：true＝現在調的是「這一張」（前提是它有 override）。
  /// 跟「有沒有 override」拆開：切回整批不會丟掉單張的覆寫
  ///（使用者指定「更動不會改掉、整批就調整剩下其他的」），
  /// 只是編輯目標換回共用設定
  bool _editSingle = false;

  /// 這一刻是不是真的在單張模式（有覆寫且開關開著）
  bool get _singleNow => _editSingle && _items[_previewIndex].override != null;

  /// 目前編輯的目標（面板、預覽拖曳、捏合都綁它）
  WatermarkSettings get _editTarget =>
      _singleNow ? _items[_previewIndex].override! : _settings;

  /// 切成「單張模式」：把目前生效的設定複製成這張自己的，
  /// 之後怎麼調都不影響其他張。只由預覽下方的範圍開關觸發——
  /// 以前預覽上一動手就自動切，使用者以為在調整批（實測回報）
  void _ensureOverride() {
    final item = _items[_previewIndex];
    item.override ??= _settings.copy();
    setState(() {
      _editSingle = true;
      _sync++; // 面板換綁到 override，內部狀態要重新同步
    });
    showHint(context, '已切換為單張調整，只影響這一張');
  }

  /// 範圍開關：整批 ↔ 單張。切回整批「不會」丟掉這張的單獨調整
  ///（使用者指定），只是之後的編輯落到共用設定（影響其他張）
  Future<void> _toggleScope() async {
    if (!_singleNow) {
      _ensureOverride();
      return;
    }
    setState(() {
      _editSingle = false;
      _sync++;
    });
    showHint(context, '回到整批調整（這張的單獨調整保留）');
  }

  // ===== 預覽區雙指縮放浮水印（跟照片編輯同一套）=====
  final Map<int, Offset> _pvPts = {};
  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;

  void _pinchDown(PointerDownEvent e) {
    _pvPts[e.pointer] = e.position;
    if (_pvPts.length != 2) return;
    final p = _pvPts.values.toList();
    final d = (p[0] - p[1]).distance;
    if (d <= 20) return;
    _pvBaseDist = d;
    // 一定要先切單張模式再拍快照：_pushUndo 會記「這一步屬於誰」，
    // 還沒 override 時記成 -1（整批共用設定），但捏合改的是 override，
    // 按上一步就會把值寫回共用設定＝預覽完全沒反應
    // 不再自動切單張：沒開開關就是調整批（見 _toggleScope）
    _btUndoPending = true; // 真的縮到才拍（見 _btPushUndoIfNeeded）
    final eff = _editTarget;
    _pvBaseText = eff.text.sizeFrac;
    _pvBaseLogo = eff.logo.sizeFrac;
  }

  /// 這次手勢還沒拍過快照（一按下就拍會把重做/選取狀態白白吃掉一步）
  bool _btUndoPending = false;

  // ===== 置中吸附與輔助線（跟影片／照片／工作室同一套手感）=====
  //
  // 拖曳時記「未吸附」的原始座標：直接把吸完的值當下一刻的起點，
  // 單次手指位移永遠小於吸附半徑，就再也拖不出中線了
  double? _btRawX, _btRawY;
  bool _btGuideV = false, _btGuideH = false;
  bool _btSnapped = false;

  double _snapC(double v) => (v - 0.5).abs() < 0.015 ? 0.5 : v;

  void _btSetGuides(double x, double y) {
    final v = x == 0.5, hh = y == 0.5;
    if (v != _btGuideV || hh != _btGuideH) {
      setState(() {
        _btGuideV = v;
        _btGuideH = hh;
      });
    }
    final on = v || hh;
    if (on != _btSnapped) {
      _btSnapped = on;
      if (on) HapticFeedback.selectionClick(); // 吸上去震一下
    }
  }

  void _btClearGuides() {
    _btRawX = null;
    _btRawY = null;
    _btSnapped = false;
    if (_btGuideV || _btGuideH) {
      setState(() {
        _btGuideV = false;
        _btGuideH = false;
      });
    }
  }

  void _btPushUndoIfNeeded() {
    if (!_btUndoPending) return;
    _btUndoPending = false;
    _pushUndo();
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    _btPushUndoIfNeeded(); // 真的縮到東西了才拍快照
    setState(() {
      final eff = _editTarget;
      final t = eff.text;
      final hasText = t.enabled && t.text.trim().isNotEmpty;
      final hasLogo = eff.logo.enabled;
      // 有選取就只縮被選的那個（跟其他三個畫面一致）；
      // 都沒選而且兩個都在才一起縮。以前永遠一起縮，
      // 調好的文字/Logo 搭配一捏就毀了
      final part = _wmPartAlive;
      final doText = hasText && (part != WmPart.logo || !hasLogo);
      final doLogo = hasLogo && (part != WmPart.text || !hasText);
      if (doText) t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
      if (doLogo) {
        eff.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
      }
    });
  }

  void _pinchUp(int pointer) {
    _pvPts.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) _pvBaseDist = null;
  }

  // ===== 批次匯出 =====

  /// 匯出前先問照片格式。批次動輒幾十張，PNG 大約是 JPEG 的 8 倍，
  /// 這裡反而是最需要選項的地方（單張編輯早就有了）
  Future<void> _confirmExportAll() async {
    if (_exporting) return;
    // 先問畫質（取消＝整個不匯）
    if (!await _askQuality() || !mounted) return;
    // 整批都是影片就不用問（影片不吃這個格式）
    final hasPhoto = _items.any((it) => !_isVideo(it.file));
    var jpeg = false;
    if (hasPhoto) {
      final fmt = await askPhotoFormat(context);
      if (fmt == null || !mounted) return;
      jpeg = fmt == 'jpg';
    }
    await _exportAll(jpeg: jpeg);
  }

  Future<void> _exportAll({bool jpeg = false}) async {
    if (_exporting) return;
    // Web 略過影片的說明放在結尾的結果訊息（skipped 計數），
    // 這裡先 show 會立刻被進度彈窗蓋住、根本看不到
    setState(() => _exporting = true);
    _stopRequested = false;

    final total = _items.length;
    final overall = ValueNotifier<double>(0);
    final label = ValueNotifier<String>('準備中…');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('批次匯出中…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: overall,
                builder: (context, v, _) => LinearProgressIndicator(value: v),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: label,
                builder: (context, s, _) => Text(
                  s,
                  style: const TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _stopRequested = true;
                engine.cancelExport();
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    // 整批跑很久，螢幕一關系統就可能凍結或回收 App，匯出會斷在中間
    await keepScreenAwake(true);

    var done = 0;
    var failed = 0;
    var skipped = 0;
    for (var i = 0; i < _items.length; i++) {
      if (_stopRequested) break;
      final item = _items[i];
      final f = item.file;
      // 不顯示檔名：使用者是照順序挑的，看到 IMG_4821.HEIC 也對不上
      // 是哪一張，那串字只是把「還剩幾個」擠掉
      label.value = '第 ${i + 1} / $total 個';
      try {
        if (_isVideo(f)) {
          if (!engine.videoExportSupported) {
            // 要計數＋推進度，不然進度條卡住、
            // 結尾還顯示「完成！已輸出 0 個」的成功樣式
            skipped++;
            overall.value = (i + 1) / total;
            continue;
          }
          final ok = await _exportVideo(f, _effectiveOf(i), (p) {
            overall.value = (i + p) / total;
          });
          ok ? done++ : failed++;
        } else {
          final bytes = await f.readAsBytes();
          var out = await WatermarkRenderer.renderPhotoComposite(
            bytes,
            _effectiveOf(i),
            // 畫布比例：照片置中、黑底補齊（跟預覽一致）
            canvasAspect: _canvasRatio.value,
          );
          var ext = 'png';
          if (jpeg) {
            try {
              out = await FlutterImageCompress.compressWithList(
                out,
                quality: _jpegQuality,
                format: CompressFormat.jpeg,
              );
              ext = 'jpg';
            } catch (_) {
              // 這台機器轉不了 JPEG 就照樣給 PNG，總比整批失敗好
            }
          }
          await savePhotoPng(
            out,
            'watermarker_${DateTime.now().millisecondsSinceEpoch}_$i',
            ext: ext,
          );
          done++;
        }
      } catch (_) {
        failed++;
      }
      overall.value = (i + 1) / total;
    }

    await keepScreenAwake(false);
    if (done > 0) {
      // 基準點重設到現在：之後又改了設定，離開一樣會問
      _initialJson = jsonEncode(_settings.toJson());
    }
    overall.dispose();
    label.dispose();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    var msg = _stopRequested
        ? '已取消，完成 $done 個'
        : (failed == 0 ? '完成！已匯出 $done 個檔案' : '完成 $done 個，$failed 個失敗');
    if (skipped > 0) msg += '（$skipped 部影片略過：此平台不支援）';
    setState(() => _exporting = false);
    // 全部成功才問下一步；有失敗或略過就用提示講清楚，
    // 這種時候把人送回主畫面等於把問題蓋掉
    if (_stopRequested || failed > 0 || skipped > 0) {
      showHint(
        context,
        msg,
        error: (failed > 0 || skipped > 0) && !_stopRequested,
      );
      return;
    }
    final home = await askAfterExport(context, msg) == 'home';
    // _initialJson 上面已經對齊現況，離開不會再問「要放棄嗎」
    if (home && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// 單支影片：原樣 + 浮水印，整段匯出
  Future<bool> _exportVideo(
    XFile f,
    WatermarkSettings wm,
    void Function(double) onProgress,
  ) async {
    final c = makeVideoController(f.path, system: true);
    try {
      await c.initialize();
    } catch (_) {
      c.dispose();
      return false;
    }
    final dur = c.value.duration.inMilliseconds / 1000.0;
    var w = c.value.size.width.round();
    var h = c.value.size.height.round();
    c.dispose();
    if (dur <= 0 || w == 0 || h == 0) return false;
    w -= w % 2;
    h -= h % 2;

    // 畫布比例：不足的邊補黑（影片 contain 進畫布，跟單支編輯器
    // 同一套數學；像素不縮水——影片貼滿的那一邊維持原尺寸）
    var ow = w, oh = h;
    final ra = _canvasRatio.value;
    if (ra != null && (ra - w / h).abs() > 0.001) {
      if (ra >= w / h) {
        oh = h;
        ow = ((h * ra) / 2).round() * 2;
      } else {
        ow = w;
        oh = ((w / ra) / 2).round() * 2;
      }
    }

    Uint8List? wmPng;
    if (wm.hasAnyMark) {
      wmPng = await WatermarkRenderer.renderOverlayPng(wm, ow, oh);
    }
    // 來源是 HDR 就保留 HDR（HEVC HLG，跟單支編輯器同一條原生路）
    //——以前批次一律走 SDR 色調映射，成品比原片淡（實測回報）
    final probe = await engine.probeVideoInfo(f.path);
    final src = MediaSource(
      path: f.path,
      name: f.name,
      kind: ClipKind.video,
      duration: dur,
      w: w,
      h: h,
    );
    final clip = TimelineClip(
      id: 0,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: dur,
      offset: 0,
      track: 0,
    );
    final result = await engine.exportVideoToGallery(
      ExportSpec(
        sources: [src],
        clips: [clip],
        timelineDuration: dur,
        speed: 1,
        watermarkPng: wmPng,
        outW: ow,
        outH: oh,
        wmAnimation: wm.animation,
        wmSpeed: wm.animSpeed,
        wmRange: wm.animRange,
        crf: _quality.crf,
        hdr: probe.hdr,
      ),
      onProgress: onProgress,
    );
    return result.ok;
  }

  /// 整批的檔案大小估計（每個畫質檔位一個總和，MB）。
  /// 影片照位元率模型（跟單支編輯器同一張表）×長度；照片粗估
  /// 原檔大小×檔位係數。探不到的（web、壞檔）就跳過；
  /// 一個都估不出來回 null，視窗就不顯示大小欄
  Future<Map<ExportQuality, double>?> _estimateMb() async {
    try {
      var any = false;
      final out = {for (final q in qualityOrder) q: 0.0};
      for (final it in _items) {
        if (_isVideo(it.file)) {
          if (it.durSec == null) {
            final m = await MediaPrep.probeLite(it.file.path);
            final d = (m?['durSec'] as num?)?.toDouble();
            if (d != null && d > 0) it.durSec = d;
          }
          final d = it.durSec ?? 0;
          final dims = it.dims;
          if (d <= 0 || dims == null || dims.$1 <= 0) continue;
          for (final q in qualityOrder) {
            final kbps = q.kbpsFor(dims.$1, dims.$2);
            out[q] = out[q]! + (kbps * 125.0 + 32000) * d / (1024 * 1024);
          }
          any = true;
        } else {
          it.byteLen ??= await it.file.length();
          final len = (it.byteLen ?? 0).toDouble();
          if (len <= 0) continue;
          for (final q in qualityOrder) {
            final k = switch (q) {
              ExportQuality.low => 0.6,
              ExportQuality.standard => 1.0,
              ExportQuality.ultra => 1.4,
              ExportQuality.lossless => 2.2,
            };
            out[q] = out[q]! + len * k / (1024 * 1024);
          }
          any = true;
        }
      }
      return any ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// 畫質：按下「匯出」時才問（畫質是匯出的參數，不是編輯的狀態）。
  /// 點一個選項＝選定並繼續；點外面＝取消整個匯出。
  /// 跟單支影片同一個長相（使用者指定統一）：右邊列整批的
  /// 大小估計、預設檔位掛「推薦」
  Future<bool> _askQuality() async {
    final est = await _estimateMb();
    if (!mounted) return false;
    final picked = await showDialog<ExportQuality>(
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
                  badge: q == ExportQuality.standard ? '推薦' : null,
                  trailing: est == null
                      ? null
                      : '約 ${est[q]!.clamp(1, 1e9).toStringAsFixed(0)} MB',
                  selected: _quality == q,
                  first: i == 0,
                  onTap: () => Navigator.pop(context, q),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return false;
    setState(() => _quality = picked);
    return true;
  }

  // ===== 畫面 =====

  /// 預覽右上角：放大＋畫布比例（跟影片編輯器同一款、同一個位置）
  Widget _previewCorner() => Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(kTagRadius),
            onTap: () => setState(() => _fsPreview = !_fsPreview),
            child: Container(
              padding: const EdgeInsets.all(5),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(kTagRadius),
              ),
              child: Icon(
                _fsPreview ? Icons.fullscreen_exit : Icons.fullscreen,
                size: 15,
                color: kIcon,
              ),
            ),
          ),
          InkWell(
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
        ],
      ),
    ),
  );

  /// 畫布比例：整批一起套（照片黑底補齊、影片 contain 進畫布）
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
              for (final (i, r) in ratioOrder.indexed)
                optionRow(
                  context: context,
                  title: r.label,
                  subtitle: r == CanvasRatio.original ? '跟素材一樣' : '不足的邊補黑',
                  selected: _canvasRatio == r,
                  first: i == 0,
                  onTap: () {
                    setState(() => _canvasRatio = r);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dims = _items[_previewIndex].dims;
    // 挑了固定比例＝畫布用它（不足的邊補黑，跟匯出一致）
    final aspect =
        _canvasRatio.value ??
        (dims == null ? 16 / 9 : dims.$1 / (dims.$2 == 0 ? 1 : dims.$2));
    // 鍵盤打開時把預覽、縮圖列、底欄全收起來：不收的話面板被擠成
    // 一條縫，文字輸入框整個藏在鍵盤後面（實測回報）
    final kbOpen = MediaQuery.of(context).viewInsets.bottom > 60;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 放大中按返回＝先退出放大，不是離開頁面
        if (_fsPreview) {
          setState(() => _fsPreview = false);
          return;
        }
        _confirmLeave();
      },
      child: EdgeBack(
        exclude: [_edgeCanvasKey],
        child: Scaffold(
          appBar: _fsPreview ? null : AppBar(),
          body: Column(
            children: [
              // 預覽：目前選中的檔案縮圖 + 浮水印圖層
              if (!kbOpen)
                Expanded(
                  flex: 4,
                  child: Listener(
                    // 雙指縮放浮水印（跟照片編輯同一套，用 Listener 不搶單指拖曳）
                    onPointerDown: _pinchDown,
                    onPointerMove: _pinchMove,
                    onPointerUp: (e) => _pinchUp(e.pointer),
                    onPointerCancel: (e) => _pinchUp(e.pointer),
                    child: Container(
                      key: _edgeCanvasKey,
                      color: kPreviewBg,
                      child: Stack(
                        children: [
                          Center(
                            // 換檔案時整個預覽子樹重建，浮水印圖層不會殘留舊狀態
                            child: KeyedSubtree(
                              key: ValueKey(_previewIndex),
                              child: AspectRatio(
                                aspectRatio: aspect,
                                child: Container(
                                  color: Colors.black,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    // 不裁切：浮水印選取框要能畫到畫面外
                                    clipBehavior: Clip.none,
                                    children: [
                                      // 大圖還在讀的時候先用小縮圖頂著，不要閃黑
                                      if (_previewBytes != null)
                                        Image.memory(
                                          _previewBytes!,
                                          fit: BoxFit.contain,
                                          cacheWidth: 1280,
                                          gaplessPlayback: true,
                                        )
                                      else if (_items[_previewIndex].thumb !=
                                          null)
                                        Image.memory(
                                          _items[_previewIndex].thumb!,
                                          fit: BoxFit.contain,
                                        ),
                                      WatermarkLayer(
                                        settings: _editTarget,
                                        // 選取框畫在裁切外（見 _wmFrameInfo）
                                        frameNotifier: _wmFrameInfo,
                                        onChanged: () => setState(() {}),
                                        // 拖曳落在目前生效的設定上：
                                        // 整批模式改整批、單張模式改這張（見開關）
                                        onDragStart: _pushUndo,
                                        selectedPart: _wmPartAlive,
                                        onSelectPart: (p) {
                                          setState(() => _wmPart = p);
                                          _wmPanelCtrl.scrollTo(p);
                                        },
                                        panLocked: () => _pvPts.length >= 2,
                                      ),
                                      // 置中輔助線。無條件插入、不要用 if 增減：
                                      // 線一出現會把後面手勢層的索引推掉，拖曳被
                                      // 中斷後又從已吸附的中線重新開始，就再也
                                      // 拖不出來了（其他三個編輯畫面同一種寫法）
                                      Positioned.fill(
                                        child: CenterGuides(
                                          vertical: _btGuideV,
                                          horizontal: _btGuideH,
                                        ),
                                      ),
                                      // 浮水印選取框：畫在真實位置（拖出畫面也看得到）
                                      Positioned.fill(
                                        child: WmFrameOverlay(_wmFrameInfo),
                                      ),
                                      // 選取路由：有部件被選取時，整個預覽的拖曳
                                      // 都只動被選的那個——手指滑過另一個部件
                                      // 才不會把它一起拖走
                                      if (_wmPartAlive != WmPart.none)
                                        Positioned.fill(
                                          child: LayoutBuilder(
                                            builder: (context, box) =>
                                                GestureDetector(
                                                  behavior: HitTestBehavior
                                                      .translucent,
                                                  // 點空白＝取消選取（不取消的話另一個
                                                  // 部件會永遠拖不動）
                                                  onTap: _clearWmSel,
                                                  onPanStart: (_) {
                                                    if (_pvPts.length >= 2) {
                                                      return;
                                                    }
                                                    _btUndoPending = true;
                                                    _btRawX = null;
                                                    _btRawY = null;
                                                  },
                                                  onPanUpdate: (d) {
                                                    if (_pvPts.length >= 2) {
                                                      return;
                                                    }
                                                    _btPushUndoIfNeeded();
                                                    final st = _effectiveOf(
                                                      _previewIndex,
                                                    );
                                                    final part = _wmPartAlive;
                                                    final mark =
                                                        part == WmPart.text
                                                        ? (
                                                            x: st.text.x,
                                                            y: st.text.y,
                                                          )
                                                        : (
                                                            x: st.logo.x,
                                                            y: st.logo.y,
                                                          );
                                                    if (part != WmPart.text &&
                                                        part != WmPart.logo) {
                                                      return;
                                                    }
                                                    // 累加在「未吸附」的原始座標上，
                                                    // 顯示值才吸中線
                                                    _btRawX ??= mark.x;
                                                    _btRawY ??= mark.y;
                                                    _btRawX =
                                                        (_btRawX! +
                                                                d.delta.dx /
                                                                    box.maxWidth)
                                                            .clamp(0.0, 1.0);
                                                    _btRawY =
                                                        (_btRawY! +
                                                                d.delta.dy /
                                                                    box.maxHeight)
                                                            .clamp(0.0, 1.0);
                                                    final sx = _snapC(_btRawX!);
                                                    final sy = _snapC(_btRawY!);
                                                    setState(() {
                                                      if (part == WmPart.text) {
                                                        st.text.x = sx;
                                                        st.text.y = sy;
                                                      } else {
                                                        st.logo.x = sx;
                                                        st.logo.y = sy;
                                                      }
                                                    });
                                                    _btSetGuides(sx, sy);
                                                  },
                                                  onPanEnd: (_) =>
                                                      _btClearGuides(),
                                                  onPanCancel: _btClearGuides,
                                                  child:
                                                      const SizedBox.expand(),
                                                ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 右上角：放大＋畫布比例（跟影片編輯器同款，
                          // 使用者指定批次也要有）
                          _previewCorner(),
                        ],
                      ),
                    ),
                  ),
                ),
              // 上一步／重做跟影片、照片同一個位置（預覽下方）。
              // 原本在標題列右上角，大螢幕手機拇指按不到
              if (!kbOpen && !_fsPreview)
                undoRedoBar(
                  onUndo: _undoStack.isEmpty ? null : _undoLast,
                  onRedo: _redoStack.isEmpty ? null : _redoLast,
                  leading: [
                    const SizedBox(width: 12),
                    // 範圍開關：預設整批；「單張」要在這裡特別切換
                    //（以前預覽上一動手就自動變單張，使用者以為在調整批）
                    GestureDetector(
                      onTap: _toggleScope,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _singleNow
                              ? kSelect.withValues(alpha: 0.15)
                              : kPanelHi,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _singleNow ? kSelect : kBorder,
                          ),
                        ),
                        child: Text(
                          _singleNow ? '單張調整' : '整批調整',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: _singleNow ? kSelect : kTextDim,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 提示這顆是開關（使用者指定）：點了在整批/單張
                    // 之間切換；單張的調整永遠保留
                    Text(
                      _singleNow ? '只調這張，點一下改回整批' : '點一下改為只調這張',
                      style: const TextStyle(fontSize: 10.5, color: kTextDim),
                    ),
                  ],
                ),
              // 檔案縮圖列：點了切換預覽、長按從批次移除。
              // 高 72：扣掉上下 8 的留白，縮圖是 56×56 正方形
              //（以前 56 高擠成 56×40 的橫式，使用者指定要正方形）
              if (!kbOpen && !_fsPreview)
                SizedBox(
                  height: 72,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    itemCount: _items.length + 1,
                    separatorBuilder: (_, i) => const SizedBox(width: 6),
                    itemBuilder: (context, i) => i == _items.length
                        ? _addTile()
                        : InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => _selectPreview(i),
                            onLongPress: () async {
                              HapticFeedback.mediumImpact(); // 長按成立的觸覺回饋
                              final hasOverride = _items[i].override != null;
                              final action = await showModalBottomSheet<String>(
                                context: context,
                                showDragHandle: true,
                                builder: (context) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(height: 8),
                                      if (hasOverride)
                                        ListTile(
                                          leading: const Icon(
                                            Icons.sync,
                                            color: kAmber,
                                          ),
                                          title: const Text('還原成整批設定'),
                                          subtitle: const Text(
                                            '丟掉這張的單獨調整',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              color: kTextDim,
                                            ),
                                          ),
                                          onTap: () =>
                                              Navigator.pop(context, 'reset'),
                                        ),
                                      ListTile(
                                        leading: const Icon(
                                          Icons.delete_outline,
                                          color: kAmber,
                                        ),
                                        title: const Text('從批次移除'),
                                        enabled: _items.length > 1,
                                        onTap: () =>
                                            Navigator.pop(context, 'remove'),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                  ),
                                ),
                              );
                              if (!mounted) return;
                              if (action == 'reset') {
                                setState(() => _items[i].override = null);
                                showHint(this.context, '已還原成整批設定');
                                return;
                              }
                              if (action != 'remove') return;
                              if (_items.length <= 1) {
                                showHint(
                                  this.context,
                                  '批次至少要留一個檔案',
                                  error: true,
                                );
                                return;
                              }
                              final ok = await showConfirm(
                                this.context,
                                title: '從批次移除這個檔案？',
                                message: _items[i].file.name,
                                action: '移除',
                              );
                              if (!ok || !mounted) return;
                              _removeItem(i);
                              showHint(this.context, '已從批次移除');
                            },
                            child: Container(
                              width: 56,
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: kPanelHi,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: kBorder, width: 1),
                              ),
                              // 選取框畫在前景，縮圖不位移
                              foregroundDecoration: i == _previewIndex
                                  ? BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: kSelect,
                                        width: 1.5,
                                      ),
                                    )
                                  : null,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (_items[i].thumb != null)
                                    Image.memory(
                                      _items[i].thumb!,
                                      fit: BoxFit.cover,
                                      cacheWidth: _thumbLongSide,
                                      gaplessPlayback: true,
                                    ),
                                  // 單張模式標記：左上角一顆琥珀小點
                                  if (_items[i].override != null)
                                    Align(
                                      alignment: Alignment.topLeft,
                                      child: Container(
                                        margin: const EdgeInsets.all(3),
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(
                                          color: kSelect,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  if (_isVideo(_items[i].file))
                                    const Align(
                                      alignment: Alignment.bottomRight,
                                      child: Padding(
                                        padding: EdgeInsets.all(2),
                                        child: Icon(
                                          Icons.videocam,
                                          size: 11,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
              if (!_fsPreview) Container(height: 1, color: kBorder),
              // 浮水印設定面板（跟編輯器同一套）；
              // 底部疊一段漸層淡出，內容是淡出去、不是被底欄硬切
              if (!_fsPreview)
                Expanded(
                  flex: 5,
                  child: Stack(
                    children: [
                      WatermarkPanel(
                        key: _panelKey,
                        // 手繪直接畫在目前這張的畫面上（畫在哪、印在哪）
                        grabFrame: () async =>
                            _previewBytes ?? _items[_previewIndex].thumb,
                        controller: _wmPanelCtrl,
                        // 面板內的「儲存範本」藏起來，改放底部那一排
                        //（跟照片編輯同一個位置、同一個樣式）
                        hideSaveButton: true,
                        // 綁「這張實際生效的設定」：單張模式下要改的是那張的
                        // override，綁 _settings 的話面板改了預覽不動、
                        // 其他張反而被改到
                        settings: _editTarget,
                        // 剛加的圖片直接選起來，可以馬上拖／縮放
                        onLogoAdded: () =>
                            setState(() => _wmPart = WmPart.logo),
                        onChanged: () => setState(() {}),
                        onBeforeChange: _pushUndo,
                        syncVersion: _sync,
                        // 有影片才顯示動畫選項
                        showAnimation: _items.any((it) => _isVideo(it.file)),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 32,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [kBg.withValues(alpha: 0), kBg],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // 底部那一排跟照片編輯完全一樣：存成範本（次要）＋輸出（主要）。
              // 畫質不放這裡：那是「輸出的參數」，按下輸出時才問（見
              // _confirmExportAll），編輯畫面上擺一顆常駐的只會讓人分心。
              // 打字中收起來，空間讓給輸入框
              if (!kbOpen && !_fsPreview)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: secondaryAction(
                            label: '存成範本',
                            onPressed: _exporting
                                ? null
                                : () => _panelKey.currentState?.savePreset(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: primaryAction(
                            label: '匯出',
                            onPressed: _exporting ? null : _confirmExportAll,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
