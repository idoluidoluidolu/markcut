import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
// XFile 由 image_picker 轉出來，不另外相依 cross_file
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/color_grade.dart';
import '../models/mosaic.dart';
import '../models/watermark_settings.dart';
import '../services/hdr_photo_export.dart';
import '../services/blob_store.dart';
import '../services/draft_assets.dart';
import '../services/face_detect.dart';
import '../services/photo_export.dart';
import '../services/rotation_snap.dart';
import '../theme.dart';
import '../services/mosaic_patch_painter.dart';
import '../services/watermark_renderer.dart';
import '../widgets/color_grade_panel.dart';
import '../widgets/font_picker.dart';
import '../widgets/library_tile_menu.dart';
import '../widgets/mosaic_outline.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

/// 預覽上一個可以點的東西：kind 0＝馬賽克、1＝主浮水印、2＝額外浮水印。
/// logo＝這一組的第幾張圖片（part 不是圖片時為 -1）
typedef _PhLayer = ({int kind, int index, WmPart part, int logo});

/// 照片草稿。影片的草稿是編輯過程中一直自動存；照片這邊只在
/// 「離開時使用者選擇保留」才存——照片編輯是一次性的工作，
/// 每次改動都寫一次反而會把上一次真的想留的東西蓋掉
const kPhotoDraftKey = 'photo_draft_v1';

class PhotoEditorScreen extends StatefulWidget {
  static Future<void> clearPhotoDraft({bool deleteAssets = false}) =>
      _PhotoEditorScreenState.clearPhotoDraft(deleteAssets: deleteAssets);
  final XFile photo;
  final WatermarkSettings? initialWatermark;

  /// 從草稿還原：整份編輯狀態的 JSON（見 _stateJson）
  final String? draft;

  /// 從首頁「馬賽克」進來：只做打碼——進來先自動找臉、全部碼上，
  /// 點臉切換碼／不碼；浮水印面板、範本、調色、畫布比例都收起來。
  /// 草稿會記住這個模式（見 _stateJson 的 mosaicMode）
  final bool mosaicMode;

  const PhotoEditorScreen({
    super.key,
    required this.photo,
    this.initialWatermark,
    this.draft,
    this.mosaicMode = false,
  });

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  // 馬賽克模式不放浮水印：預設那行「@我的浮水印」關掉
  late final WatermarkSettings _settings =
      widget.initialWatermark?.copy() ??
      (widget.mosaicMode
          ? (WatermarkSettings()..text.enabled = false)
          : WatermarkSettings());

  /// 見 [PhotoEditorScreen.mosaicMode]。草稿還原時從狀態 JSON 讀回來
  late bool _mosaicMode = widget.mosaicMode;

  /// 馬賽克模式下面那排選的樣式與形狀：改了就套到每一塊
  ///（臉、方框、筆畫），之後新加的也照這個。
  /// 濃度預設 0.85（一張臉橫向約 9 格）：一般區塊用的 0.5 是 16 格，
  /// 蓋在臉上眼睛鼻子還認得出來（截圖實測）
  final MosaicStyle _mzStyle = MosaicStyle(strength: 0.85);
  bool _mzOval = true;

  /// 下面那排的「大小」（全部一起）：1＝找臉／新加當下的大小。拉動＝每一塊
  /// 照自己現在的大小一起放大縮小（筆畫是粗細）；要單獨調哪一塊就兩指捏它
  double _mzSize = 1.0;

  /// 大小滑桿按下那一刻的值與每一塊的大小：拖動中一律照這份算倍率，
  /// 夾到上下限的那幾塊才不會越拉越歪
  double _mzSizeFrom = 1.0;
  List<double> _mzSizeBase = const [];

  /// 「亮一下」：剛加的、點到的那幾塊閃一圈白光就收。照片上的馬賽克不畫框
  ///（使用者指定），要認出是哪一塊只能靠這個
  Set<int> _flashIds = const {};
  int _flashToken = 0;

  /// 這一次兩指捏的是哪一塊（馬賽克模式：捏在哪塊上就縮放哪塊，臉也行）
  int _pinchMosaic = -1;

  /// 這一手出現過兩指：放開時那一下不算「點」（不然捏完臉會順便被切成不碼）
  bool _pinchHappened = false;

  /// 預覽畫布：手指的螢幕座標要換成畫布座標，才知道捏、按在哪一塊上
  final _canvasKey = GlobalKey();

  /// 上面那排馬賽克縮圖：加了新的一塊就捲到最後，看得到它
  final _stripCtrl = ScrollController();

  /// 找臉中：工具鈕轉圈、不重複送
  bool _findingFaces = false;

  /// 被選浮水印部件的框（畫在裁切外，拖出照片也看得到位置）
  final _wmFrameInfo = ValueNotifier<WmFrameInfo?>(null);
  double? _aspect; // 照片長寬比

  /// 拖曳／捏合／滑桿的每一格只重建預覽（照片、馬賽克、浮水印圖層），
  /// 不整頁 setState——這一頁的 build 連面板一起有三千行，每一格重建
  /// 追不上手指（影片編輯器同一套：onLiveChange）。放手時再 setState
  /// 一次（[_liveEnd]），面板的滑桿讀數、九宮格亮點才對回來
  final _liveTick = ValueNotifier<int>(0);

  void _liveRepaint() {
    if (mounted) _liveTick.value++;
  }

  void _liveEnd() {
    if (mounted) setState(() {});
  }

  /// 畫布比例（null＝跟照片一樣）。改了之後照片置中貼黑底，
  /// 所有座標以畫布為準——跟匯出同一套（renderPhotoComposite）
  double? _canvasAspect;

  /// 目前生效的畫布比例
  double get _canvasAspectEff => _canvasAspect ?? _aspect ?? 1;

  /// 畫布底圖（照片貼黑底）：馬賽克取樣用。null＝畫布跟照片一樣，
  /// 直接取樣照片本人
  ui.Image? _canvasImg;

  /// 馬賽克取樣的底圖（畫布優先）
  ui.Image? get _mosaicBase =>
      _canvasAspect == null ? _photoImg : (_canvasImg ?? _photoImg);

  /// 重算畫布底圖（換比例、照片載好時）
  Future<void> _rebuildCanvasImg() async {
    final photo = _photoImg;
    final ca = _canvasAspect;
    if (photo == null || ca == null) {
      _canvasImg?.dispose();
      if (mounted) setState(() => _canvasImg = null);
      return;
    }
    final w = photo.width, h = photo.height;
    final int cw, ch;
    if (ca >= w / h) {
      ch = h;
      cw = (h * ca).round();
    } else {
      cw = w;
      ch = (w / ca).round();
    }
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.drawRect(
      ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    c.drawImageRect(
      photo,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH((cw - w) / 2, (ch - h) / 2, w.toDouble(), h.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final img = await rec.endRecording().toImage(cw, ch);
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() {
      _canvasImg?.dispose();
      _canvasImg = img;
    });
  }

  // 跟影片/批次的比例視窗同一套選項與順序（原始最前、
  // 其餘照首位數字由小到大——使用者指定全 App 統一）
  static const _ratioOptions = <({String label, double? aspect})>[
    (label: '原始', aspect: null),
    (label: '1:1', aspect: 1.0),
    (label: '3:4', aspect: 0.75),
    (label: '4:3', aspect: 4 / 3),
    (label: '4:5', aspect: 0.8),
    (label: '9:16', aspect: 9 / 16),
    (label: '16:9', aspect: 16 / 9),
  ];

  String get _ratioLabel => _ratioOptions
      .firstWhere(
        (o) => o.aspect == _canvasAspect,
        orElse: () => (label: '自訂', aspect: _canvasAspect),
      )
      .label;

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
              for (final (i, o) in _ratioOptions.indexed)
                optionRow(
                  context: context,
                  title: o.label,
                  selected: _canvasAspect == o.aspect,
                  first: i == 0,
                  onTap: () {
                    Navigator.pop(context);
                    if (_canvasAspect == o.aspect) return;
                    _pushUndo();
                    setState(() => _canvasAspect = o.aspect);
                    unawaited(_rebuildCanvasImg());
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _exporting = false;

  /// 調色（跟影片編輯共用同一組模型與面板）
  final _grade = ColorGrade();

  /// 底部分頁：0 浮水印、1 調色（輸出是動作不是分頁）
  int _tab = 0;

  /// 按住「原圖」比對中：先不要套調色
  bool _colorCompare = false;

  /// 浮水印選到哪個部件（文字或圖片）。縮放只動被選的那個
  WmPart _wmPart = WmPart.none;

  /// 被選部件目前還「活著」嗎（存在、非平鋪）。
  /// 選中 Logo 後把 Logo 移除／開滿版，殘留的選取會讓
  /// 拖曳整個變死的——不活就一律當作沒選
  WmPart get _wmPartAlive {
    final t = _settings.text;
    final lg = _settings.logo;
    return switch (_wmPart) {
      WmPart.text when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
        WmPart.text,
      WmPart.logo when lg.enabled && !lg.tiled => WmPart.logo,
      _ => WmPart.none,
    };
  }

  /// 「有沒有改過」的基準快照：進來時拍一次，輸出成功後重設
  late String _initialJson;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    if (d != null) {
      // 還原要在拍基準之前：不然一進來就被判定成「改過了」，
      // 什麼都沒動就離開也會被問要不要留草稿
      try {
        _applyState(d);
      } catch (_) {
        // 壞掉的草稿不該讓畫面開不起來，當成沒有草稿就好
      }
    }
    _initialJson = _stateJson;
    _loadMosaicShader();
    _load();
  }

  /// 把目前的編輯狀態存成草稿（離開時選「保留」才呼叫）
  Future<bool> _saveDraft() async {
    SharedPreferences? prefs;
    try {
      final state = _stateJsonFull;
      final path = (await DraftAssets.secureAll(DraftAssets.photo, [
        widget.photo.path,
      ])).single;
      if (path == null || path.isEmpty) {
        throw StateError('照片複本無法保存');
      }
      prefs = await SharedPreferences.getInstance();
      // 存成檔案（見 BlobStore）：內容帶著 Logo 的 base64，放在設定檔裡
      // 的話 iOS 每次開 App 都把它整包讀進記憶體
      final saved = await BlobStore.write(
        kPhotoDraftKey,
        jsonEncode({
          'photo': path,
          // 一定要完整版：池子代號存到磁碟等於把 Logo 圖片丟掉
          'state': state,
          'savedAt': DateTime.now().toIso8601String(),
        }),
      );
      if (!saved) {
        await prefs.reload();
        throw StateError('草稿無法保存');
      }
      return true;
    } on DraftAssetException catch (e) {
      if (mounted) showHint(context, e.message, error: true);
      return false;
    } catch (_) {
      try {
        await prefs?.reload();
      } catch (_) {}
      if (mounted) showHint(context, '草稿保存失敗，請確認儲存空間後再試一次', error: true);
      return false;
    }
  }

  static Future<void> clearPhotoDraft({bool deleteAssets = false}) async {
    if (!await BlobStore.delete(kPhotoDraftKey)) {
      await (await SharedPreferences.getInstance()).reload();
      return;
    }
    if (deleteAssets) await DraftAssets.retain(DraftAssets.photo, {});
  }

  Future<void> _cleanupOnLeave() async {
    try {
      final raw = await BlobStore.read(kPhotoDraftKey);
      final path = raw == null ? null : (jsonDecode(raw) as Map)['photo'];
      await DraftAssets.afterLeave(
        DraftAssets.photo,
        keep: {if (path is String && path.isNotEmpty) path},
        received: {widget.photo.path},
      );
    } catch (_) {
      // 無法讀取保存狀態時保留素材，避免清掉仍有用的照片。
    }
  }

  // ===== 馬賽克（照片模式：任意數量的方形區域）=====
  // 存在 WatermarkSettings 上：跟著範本一起存／套用，
  // undo 快照與「有沒有改過」判定也自動涵蓋
  List<PhotoMosaic> get _mosaics => _settings.mosaics;
  int _selMosaic = -1;

  /// 更多浮水印：每一組是完整的一套（文字＋Logo），
  /// 疊在主浮水印上面，可各自拖曳、獨立刪除。
  /// 文字分頁底下的「浮水印＋」入口已拿掉（使用者不要），現在只有
  /// 舊草稿會帶進來；照樣畫、照樣輸出，點預覽上的它能編輯／刪除
  final List<WatermarkSettings> _extraWms = [];

  /// 選取中的額外浮水印：第幾組、哪個部件（-1 = 沒有）。
  /// 跟主浮水印／馬賽克互斥（單一選取）
  int _selExtra = -1;
  WmPart _selExtraPart = WmPart.none;

  /// 被選的額外浮水印部件是否還活著（同 _wmPartAlive 的理由）
  WmPart _extraPartAlive(int i) {
    if (_selExtra != i || i < 0 || i >= _extraWms.length) return WmPart.none;
    final t = _extraWms[i].text;
    final lg = _extraWms[i].logo;
    return switch (_selExtraPart) {
      WmPart.text when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
        WmPart.text,
      WmPart.logo when lg.enabled && !lg.tiled => WmPart.logo,
      _ => WmPart.none,
    };
  }

  /// 預覽用 shader 程式（真像素塊）；載不到就退回霧化。
  /// 存「程式」不存實例：多塊馬賽克同幀各建各的實例，
  /// 共用實例會讓後設定的參數蓋掉前面的
  ui.FragmentProgram? _mosaicProg;

  Future<void> _loadMosaicShader() async {
    try {
      final prog = await ui.FragmentProgram.fromAsset('shaders/mosaic.frag');
      if (mounted) setState(() => _mosaicProg = prog);
    } catch (_) {}
  }

  /// Logo 的 base64 動輒好幾 MB。每次拖曳起手都把它整份 jsonEncode
  /// 進 undo 快照，會讓「按下去那一瞬間」明顯卡一下（拖曳掉幀主因），
  /// 60 份快照更是上百 MB——改成存進池子，快照裡只留編號。
  /// 池子存的是同一個字串參照，沒有額外複製
  final List<String> _b64Pool = [];

  String _b64Token(String b64) {
    for (var i = 0; i < _b64Pool.length; i++) {
      if (identical(_b64Pool[i], b64)) return '@@b64:$i';
    }
    _b64Pool.add(b64);
    return '@@b64:${_b64Pool.length - 1}';
  }

  // 一組浮水印可以有很多張圖片，每一張都要換成池子編號——
  // 漏掉的話那張圖的 base64 會原封不動存進每一步快照裡
  void _packLogo(Object? m) {
    if (m is! Map) return;
    for (final lg in ((m['logos'] as List?) ?? const [])) {
      if (lg is Map && lg['b64'] is String) {
        lg['b64'] = _b64Token(lg['b64'] as String);
      }
    }
  }

  void _unpackLogo(Object? m) {
    if (m is! Map) return;
    for (final lg in ((m['logos'] as List?) ?? const [])) {
      if (lg is! Map || lg['b64'] is! String) continue;
      final v = lg['b64'] as String;
      if (v.startsWith('@@b64:')) {
        final i = int.tryParse(v.substring(6)) ?? -1;
        lg['b64'] = (i >= 0 && i < _b64Pool.length) ? _b64Pool[i] : null;
      }
    }
  }

  /// 馬賽克模式自己的狀態：模式本身（草稿還原要開回同一種畫面）＋
  /// 下面那排選的樣式／形狀（上一步要連它一起退，不然按鈕亮的是
  /// 新樣式、照片上卻是舊的）
  Map<String, dynamic> get _mosaicModeJson => {
    if (_mosaicMode) 'mosaicMode': true,
    if (_mosaicMode) 'mzStyle': _mzStyle.toJson(),
    if (_mosaicMode) 'mzOval': _mzOval,
    if (_mosaicMode) 'mzSize': _mzSize,
  };

  String get _stateJson {
    final j = <String, dynamic>{
      ..._settings.toJson(),
      'color': _grade.toJson(),
      'extraWms': _extraWms.map((e) => e.toJson()).toList(),
      if (_canvasAspect != null) 'canvasAspect': _canvasAspect,
      ..._mosaicModeJson,
    };
    _packLogo(j);
    for (final e in (j['extraWms'] as List)) {
      _packLogo(e);
    }
    return jsonEncode(j);
  }

  /// 完整版狀態（b64 原文，不走池子）。草稿一定要用這份——
  /// 池子只活在記憶體，`@@b64:N` 代號存進 SharedPreferences 後
  /// 下次開啟池子是空的，_unpackLogo 只能填 null：加了圖片浮水印
  /// 的草稿一重開，所有 Logo 無聲消失。池子版（[_stateJson]）
  /// 只給 undo 快照與 _dirty 比對用（同一個工作階段內池子有效）
  String get _stateJsonFull {
    final j = <String, dynamic>{
      ..._settings.toJson(),
      'color': _grade.toJson(),
      'extraWms': _extraWms.map((e) => e.toJson()).toList(),
      if (_canvasAspect != null) 'canvasAspect': _canvasAspect,
      ..._mosaicModeJson,
    };
    return jsonEncode(j);
  }

  bool get _dirty => _stateJson != _initialJson;

  /// 離開保護：調過浮水印但沒輸出就問一下
  Future<void> _confirmLeave() async {
    // 全螢幕檢視中按返回：先退回編輯畫面，不要一按就離開專案
    //（跟影片編輯同一個規則）
    if (_fsView) {
      setState(() => _fsView = false);
      return;
    }
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    // 跟影片編輯同一款三顆直排。以前只有「放棄」一條路，
    // 調了半天的馬賽克跟好幾組浮水印會整個蒸發
    final act = await showLeaveChoice(
      context,
      title: '還沒匯出',
      // 全 App 統一的說法（使用者指定）
      message: '可以在個人頁面的「草稿」繼續未完成的編輯',
      keepLabel: '保留草稿',
      discardLabel: '捨棄',
    );
    if (!mounted) return;
    if (act == 'keep') {
      final saved = await _saveDraft();
      if (saved && mounted) Navigator.of(context).pop();
    } else if (act == 'discard') {
      Navigator.of(context).pop();
    }
  }

  // ===== 上一步（改壞了可以救）=====
  final List<String> _undoStack = [];
  int _sync = 0; // 通知面板同步內部狀態

  /// 重做堆疊：只要有新的編輯就作廢（分支掉的未來留著只會搞混）
  final List<String> _redoStack = [];

  /// 這次手勢還沒拍過快照。
  /// 一按下就拍的話，_pushUndo 會把重做堆疊清空——使用者剛按了
  /// 上一步、手指只是輕碰一下預覽（有 panStart 但沒移動），
  /// 剛撤銷的東西就再也回不來了
  bool _phUndoPending = false;

  void _phPushUndoIfNeeded() {
    if (!_phUndoPending) return;
    _phUndoPending = false;
    _pushUndo();
  }

  /// 拍一張「上一步」快照（改動之前叫）。
  ///
  /// 以前這裡有一條「0.7 秒內不再拍」的全域節流，本意是把連續滑桿併成
  /// 一步；但滑桿早就在面板那層合併了（按下那一刻拍一次、拖動中不拍），
  /// 這條節流剩下的作用只有吃掉離散動作：加一塊馬賽克、0.7 秒內按刪除，
  /// 第二個動作沒拍到快照，上一步一次退兩步；被吃掉的那一次也沒清重做
  /// 堆疊，之後按重做會把剛做的新編輯默默丟掉。
  ///
  /// 現在改成比內容：跟堆疊頂端一模一樣就不重複推——同一個手勢起手被
  /// 拖曳跟捏合各拍一次、或改動根本沒改到值，都是這種情況；重做堆疊也
  /// 留著（狀態沒離開快照鏈，分支掉的未來還是有效的）。其他一律拍
  void _pushUndo() {
    final json = _stateJson;
    if (_undoStack.isNotEmpty && _undoStack.last == json) return;
    _undoStack.add(json);
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    _redoStack.clear();
    setState(() {}); // 讓上一步鈕亮起來
  }

  /// 把某個快照套回目前狀態
  void _applyState(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    // 快照裡的 Logo 是池子編號，先換回真正的 base64
    _unpackLogo(j);
    for (final e in ((j['extraWms'] as List?) ?? const [])) {
      _unpackLogo(e);
    }
    final wm = WatermarkSettings.fromJson(j);
    final ca = (j['canvasAspect'] as num?)?.toDouble();
    if (ca != _canvasAspect) {
      _canvasAspect = ca;
      unawaited(_rebuildCanvasImg());
    }
    // 草稿是從馬賽克模式存的：開回馬賽克模式（模式只會打開、不會關掉——
    // 上一步的快照全在同一個模式裡拍的）
    if (j['mosaicMode'] == true) _mosaicMode = true;
    final mz = j['mzStyle'];
    if (mz is Map) {
      final st = MosaicStyle.fromJson(Map<String, dynamic>.from(mz));
      _mzStyle
        ..type = st.type
        ..strength = st.strength
        ..color = st.color
        ..feather = st.feather;
    }
    if (j['mzOval'] is bool) _mzOval = j['mzOval'] as bool;
    if (j['mzSize'] is num) {
      _mzSize = (j['mzSize'] as num).toDouble().clamp(0.5, 2.0);
    }
    setState(() {
      _settings.copyMarksFrom(wm);
      _grade.copyFrom(
        ColorGrade.fromJson(Map<String, dynamic>.from(j['color'] as Map)),
      );
      _settings.mosaics
        ..clear()
        ..addAll(wm.mosaics);
      _extraWms
        ..clear()
        ..addAll(
          ((j['extraWms'] as List?) ?? const []).map(
            (e) =>
                WatermarkSettings.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );
      // 復原可能把被選取的部件變不見（例如撤銷加 Logo），
      // 選取殘留會讓拖曳整個變死的
      _wmPart = WmPart.none;
      _selMosaic = -1;
      _selExtra = -1;
      _flashIds = const {};
      _sync++;
    });
  }

  void _redoLast() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_stateJson);
    _applyState(_redoStack.removeLast());
  }

  void _undoLast() {
    if (_undoStack.isEmpty) return;
    // 撤銷之前先把現況存進重做堆疊，才回得來
    _redoStack.add(_stateJson);
    _applyState(_undoStack.removeLast());
  }

  /// 解碼後的照片（馬賽克預覽直接取樣它：真像素塊／真羽化，
  /// 跟匯出同一套畫法，web 也一樣）
  ui.Image? _photoImg;

  @override
  void dispose() {
    unawaited(_cleanupOnLeave());
    _photoImg?.dispose();
    _canvasImg?.dispose();
    _liveTick.dispose();
    _wmFrameInfo.dispose();
    _stripCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final img = await _decodeForPreview();
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _photoImg = img;
        _aspect = img.width / img.height;
      });
      if (_canvasAspect != null) unawaited(_rebuildCanvasImg());
      // 馬賽克模式一進來就找臉、全部碼上（草稿還原的已經找過了）
      if (_mosaicMode && widget.draft == null) {
        unawaited(_findFaces(auto: true));
      }
    } catch (_) {
      // 壞檔或不支援的格式：不能讓畫面永遠轉圈
      if (!mounted) return;
      // 從草稿進來卻讀不到照片＝相簿那份暫存檔被系統清掉了。
      // 草稿留著只會讓首頁一直有一列點了就失敗的東西
      if (widget.draft != null) {
        unawaited(clearPhotoDraft());
        showHint(context, '上次那張照片已經不在了，草稿已清除', error: true);
      } else {
        showHint(context, '這張圖片無法讀取，換一張試試', error: true);
      }
      Navigator.of(context).pop();
    }
  }

  /// 預覽用的解碼：長邊最多到「螢幕的長邊（實體像素）」。
  ///
  /// 24MP 的 HEIC 全尺寸解開是 96MB、48MP 逾 190MB，而預覽最多只畫得出
  /// 螢幕那麼多像素。以前全尺寸解一份存著、Image.memory 又在框架的圖片
  /// 快取裡再解一份、換比例後畫布底圖第三份——一張 48MP 的照片光是開進
  /// 編輯器就逾半 GB，實機被系統收掉。現在只解這一份，預覽（RawImage）
  /// 跟馬賽克取樣都用它；匯出才回檔案以原始解析度解（跟批次同一條路，
  /// 見 _export），成品像素不縮水。
  ///
  /// 手機上用 ImmutableBuffer.fromFilePath 讓引擎直接讀檔，檔案不經
  /// Dart 堆；沒有路徑（web、測試的記憶體檔）才 readAsBytes。
  /// ImageDescriptor 在 web 會炸：退回整張解
  Future<ui.Image> _decodeForPreview() async {
    final ps =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    final cap = math.max(ps.width, ps.height).round().clamp(1440, 4096);
    final path = widget.photo.path;
    final hasPath = !kIsWeb && path.isNotEmpty;
    ui.ImmutableBuffer? buf;
    ui.ImageDescriptor? desc;
    ui.Codec? codec;
    try {
      buf = hasPath
          ? await ui.ImmutableBuffer.fromFilePath(path)
          : await ui.ImmutableBuffer.fromUint8List(
              await widget.photo.readAsBytes(),
            );
      desc = await ui.ImageDescriptor.encoded(buf);
      final w = desc.width, h = desc.height;
      final long = math.max(w, h);
      if (long > cap) {
        // 讓解碼器在解的時候就縮（JPEG 是 DCT 縮放、HEIC 是 ImageIO
        // 縮圖），不是解整張再縮
        final sc = cap / long;
        codec = await desc.instantiateCodec(
          targetWidth: (w * sc).round().clamp(1, cap),
          targetHeight: (h * sc).round().clamp(1, cap),
        );
      } else {
        codec = await desc.instantiateCodec();
      }
      return (await codec.getNextFrame()).image;
    } on Object {
      codec?.dispose();
      codec = null;
      final bytes = await widget.photo.readAsBytes();
      codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      desc?.dispose();
      buf?.dispose();
    }
  }

  /// 手繪畫板的底圖：目前的畫面（換了比例就含黑邊，筆跡落點才對得上
  /// 畫布座標），長邊縮到 1920 再編成 PNG。畫板只拿它當參考鋪底，
  /// 不必給全尺寸——畫板還會再解一次，給 48MP 就是又一份 190MB
  Future<Uint8List?> _grabFrame() async {
    final base = _mosaicBase;
    if (base == null) return null;
    final long = math.max(base.width, base.height);
    var img = base;
    var owned = false;
    if (long > 1920) {
      final sc = 1920 / long;
      final tw = (base.width * sc).round(), th = (base.height * sc).round();
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawImageRect(
        base,
        Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
        Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      img = await rec.endRecording().toImage(tw, th);
      owned = true;
    }
    try {
      final d = await img.toByteData(format: ui.ImageByteFormat.png);
      return d?.buffer.asUint8List();
    } finally {
      if (owned) img.dispose();
    }
  }

  /// 預覽與面板之間的控制列：上一步／重做（四個編輯畫面共用同一條）
  Widget _buildControlBar() => undoRedoBar(
    onUndo: _undoStack.isEmpty ? null : _undoLast,
    onRedo: _redoStack.isEmpty ? null : _redoLast,
  );

  /// 編輯某一組浮水印：抽屜裡放「跟主浮水印一模一樣」的完整面板，
  /// 文字、字體、顏色、大小…全都能改，改動即時反映在預覽上
  void _editExtraWm(int i) {
    if (i < 0 || i >= _extraWms.length) return;
    // 抓住這一組本身，不要在抽屜裡用索引取——刪除／復原之後
    // 索引會失效，抽屜還在退場時重建就會越界
    final target = _extraWms[i];
    // 開編輯＝選取這一組（預覽上畫白框），跟其他選取互斥
    setState(() {
      _selExtra = i;
      if (_extraPartAlive(i) == WmPart.none) {
        final t = _extraWms[i].text;
        _selExtraPart = (t.enabled && !t.tiled && t.text.trim().isNotEmpty)
            ? WmPart.text
            : WmPart.logo;
      }
      _wmPart = WmPart.none;
      _selMosaic = -1;
    });
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(
          children: [
            // 標頭：這組是誰＋刪除（列上不放垃圾桶，收在這裡）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _labelOf(target),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: kText,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: kTextDim),
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      _pushUndo();
                      setState(() {
                        _extraWms.remove(target);
                        _selExtra = -1;
                      });
                    },
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('刪除這組', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: WatermarkPanel(
                settings: target,
                // 手繪直接畫在照片上（畫在哪、印在哪）
                grabFrame: _grabFrame,
                // 九宮格「貼邊」要知道畫布比例才夾得準
                canvasAspect: _canvasAspectEff,
                onChanged: () => setState(() {}),
                onLiveChange: _liveRepaint,
                // 每個離散改動各拍一次（滑桿一拖一步，面板自己合併）。
                // 以前整張面板開著只拍一次，改字、改色、改大小之後按
                // 上一步會全部一起消失
                onBeforeChange: _pushUndo,
                hideSaveButton: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _labelOf(WatermarkSettings w) =>
      w.text.enabled && w.text.text.trim().isNotEmpty
      ? w.text.text
      : '浮水印 ${_extraWms.indexOf(w) + 2}（Logo）';

  /// 面板裡的「馬賽克」卡（插在圖片卡下面）：＋加一塊，
  /// 每塊一列可選取／調樣式／刪除
  Widget _mosaicSection() {
    const typeNames = ['像素化', '模糊', '純色遮蓋'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 還沒有馬賽克時整行都能點（跟圖片卡同一套）
        InkWell(
          onTap: _mosaics.isEmpty ? _addMosaic : null,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              const Text(
                '馬賽克',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: kText,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '加一塊馬賽克',
                visualDensity: VisualDensity.compact,
                onPressed: _addMosaic,
                icon: const Icon(Icons.add, size: 20, color: kIcon),
              ),
            ],
          ),
        ),
        for (var i = 0; i < _mosaics.length; i++)
          InkWell(
            onTap: () => setState(() {
              _selMosaic = i;
              _wmPart = WmPart.none;
              _selExtra = -1;
            }),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  _mosaics[i].isStroke
                      ? Icons.brush_outlined
                      : _mosaics[i].style.type == 2
                      ? Icons.square_rounded
                      : Icons.blur_on,
                  size: 15,
                  color: _mosaics[i].style.type == 2
                      ? Color(_mosaics[i].style.color)
                      : (_selMosaic == i ? kSelect : kIcon),
                ),
                const SizedBox(width: 8),
                Text(
                  '第 ${i + 1} 塊 · ${_mosaics[i].isStroke ? '筆刷 · ' : ''}'
                  '${typeNames[_mosaics[i].style.type]}',
                  // 這些是「已經套在照片上」的東西，用正常字色；
                  // 灰字看起來像沒生效（使用者回報）
                  style: TextStyle(
                    fontSize: 12,
                    color: _selMosaic == i ? kSelect : kText,
                    fontWeight: _selMosaic == i
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '調整樣式',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() {
                      _selMosaic = i;
                      _wmPart = WmPart.none;
                      _selExtra = -1;
                    });
                    _editMosaic(i);
                  },
                  icon: const Icon(Icons.tune, size: 17, color: kIcon),
                ),
                IconButton(
                  tooltip: '刪除',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _pushUndo();
                    setState(() {
                      _mosaics.removeAt(i);
                      _selMosaic = -1;
                    });
                  },
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 17,
                    color: kTextDim,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 預覽上的馬賽克層：拖曳移動、點選取、再點開樣式表
  /// 浮水印圖層回報自己畫在哪（在 build/layout 裡呼叫，只能存不能 setState）
  void _phSetBox(int kind, int index, List<Rect?> texts, List<Rect?> logos) {
    void put(WmPart part, int sub, Rect? r) {
      final id = (kind: kind, index: index, part: part, logo: sub);
      if (r == null) {
        _phBox.remove(id);
      } else {
        _phBox[id] = r;
      }
    }

    // 個數會變（加、刪），先把這一組舊的框全清掉再重放，
    // 不然刪掉的那個會留一個永遠點得到的鬼框
    _phBox.removeWhere(
      (k, _) =>
          k.kind == kind &&
          k.index == index &&
          (k.part == WmPart.logo || k.part == WmPart.text),
    );
    for (var i = 0; i < texts.length; i++) {
      put(WmPart.text, i, texts[i]);
    }
    for (var i = 0; i < logos.length; i++) {
      put(WmPart.logo, i, logos[i]);
    }
  }

  /// 置頂導覽列的項目。sec＝WatermarkPanel 的區段索引（按下去是叫
  /// 面板跳第幾區，對不上就跳錯）。
  /// 第一格「範本」不是區段，按了直接開挑選視窗；最後的「調色」是
  /// 另一個模式（點了整個換掉下半部），因為調色面板自己有捲動清單，
  /// 塞不進面板當一張卡
  static const _phNav = [
    (label: '範本', icon: Icons.bookmarks_outlined, sec: 0),
    (label: '位置', icon: Icons.grid_view, sec: 1),
    // 跟其他畫面的面板同一個叫法（使用者指定：這格叫「文字」）
    (label: '文字', icon: Icons.title, sec: 2),
    (label: '圖片', icon: Icons.image_outlined, sec: 3),
    (label: '馬賽克', icon: Icons.blur_on, sec: 4),
    (label: '調色', icon: Icons.tune, sec: -1),
  ];

  /// 調色在導覽列的位置（最後一格）
  static const _phColorIdx = 5;

  Widget _sectionBar() => AnimatedBuilder(
    // 面板捲動時會回報捲到第幾區。只重畫這一條，
    // 不要整頁 setState——預覽跟著重建會頓
    animation: _wmPanelCtrl,
    builder: (context, _) => _sectionBarBody(),
  );

  Widget _sectionBarBody() {
    // 調色模式時高亮最後一格，否則跟著面板捲到哪就亮哪
    final sec = _wmPanelCtrl.activeSection;
    final active = _tab == 1
        ? _phColorIdx
        : _phNav.indexWhere((n) => n.sec == sec);
    return Container(
      color: kPanel,
      // 跟面板那份導覽列同一組內距（往上收緊，間隔才不會太鬆）
      padding: const EdgeInsets.fromLTRB(6, 3, 6, 5),
      child: Row(
        children: [
          for (var i = 0; i < _phNav.length; i++)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  if (i == _phColorIdx) {
                    setState(() => _tab = 1);
                    return;
                  }
                  // 從調色切回來時面板要先掛上，jumpToSection
                  // 內部會等一幀再捲
                  setState(() {
                    _tab = 0;
                    _colorCompare = false;
                  });
                  _wmPanelCtrl.jumpToSection(_phNav[i].sec);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  // 選中不畫框：圖示＋文字直接轉琥珀，
                  // 跟浮水印面板與影片編輯器同一套選取語言
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _phNav[i].icon,
                        size: 17,
                        color: i == active ? kSelect : kTextDim,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _phNav[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: i == active ? kSelect : kTextDim,
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
  }

  /// 從浮動列存成範本。面板只在浮水印分頁掛著，
  /// 在調色模式要先切回去才叫得到它的儲存流程
  Future<void> _savePresetFromBar() async {
    if (_tab != 0) {
      setState(() => _tab = 0);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    await _panelKey.currentState?.savePreset();
  }

  /// 浮在面板上的按鈕列。不佔版面高度——內容從它下面穿過去，
  /// 底下鋪一層漸層讓字不會糊在一起，面板的空間感才拉得開。
  /// 兩顆都寫字：存成範本縮成圖示就沒人知道那是什麼
  Widget _floatingExport() {
    // 鍵盤開著就收起來：浮鍵會壓在文字輸入框上（實測回報：
    // 照片浮水印這裡鍵盤會擋道）。
    //
    // 收起來的替身一定要是 Positioned 的。這一層是面板那個 Stack 裡唯一
    // 「沒定位」的子件，而 Stack 是照沒定位的子件量自己的尺寸——以前
    // 這裡回一個 SizedBox.shrink()，整個 Stack 就縮成 0 寬，底下
    // Positioned.fill 的面板跟著 0 寬：鍵盤一彈出來，文字輸入框連同整個
    // 面板消失、只剩一片底色（實測回報）。定位過的子件不參與量尺寸，
    // Stack 才會撐滿（Stack 本身也改成 StackFit.expand，兩道保險）
    if (MediaQuery.of(context).viewInsets.bottom > 60) {
      return const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SizedBox.shrink(),
      );
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              child: Container(
                // 馬賽克模式的面板不用捲（高度是算好的，見 _mzPanelHeight），
                // 漸層只留一小截：40 的話最後一排滑桿整條被罩成灰的
                height: _mosaicMode ? _kMzBarFade : 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [kBg.withValues(alpha: 0), kBg],
                  ),
                ),
              ),
            ),
            Container(
              color: kBg,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    // 馬賽克模式沒有範本：那個位置換成「新增馬賽克」——
                    // 寫明是「再加一塊」（以前找臉／方框／筆刷三顆擺在
                    // 面板最下面，看不出是加新的，使用者回報不直覺）。
                    // 塗抹中先收掉：筆刷還開著又疊一張選單會打架
                    Expanded(
                      child: _mosaicMode
                          ? secondaryAction(
                              label: '新增馬賽克',
                              icon: Icons.add,
                              onPressed: _exporting || _brushMode
                                  ? null
                                  : _askAddMosaic,
                            )
                          : secondaryAction(
                              label: '存成範本',
                              onPressed: _exporting ? null : _savePresetFromBar,
                            ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: primaryAction(
                        label: '匯出',
                        onPressed: _exporting ? null : _confirmExport,
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
  }

  Widget _buildMosaics(double w, double h) {
    final children = <Widget>[];
    final glows = <Widget>[];
    for (var i = 0; i < _mosaics.length; i++) {
      final m = _mosaics[i];
      Rect rect;
      if (m.isStroke) {
        // 筆畫：範圍＝包圍盒。用照片座標算好再等比換到畫布，
        // 跟匯出的外框是同一個算式
        final imgW = _mosaicBase?.width ?? 1000;
        final imgH = _mosaicBase?.height ?? math.max(1, (1000 * h / w).round());
        final pts = [
          for (var k = 0; k + 1 < m.stroke!.length; k += 2)
            Offset(m.stroke![k] * imgW, m.stroke![k + 1] * imgH),
        ];
        final brushPx = m.brush * math.min(imgW, imgH).toDouble();
        final box = strokeBoundsPx(
          pts,
          brushPx,
          strokeFeatherPx(m.style, brushPx),
        );
        final sc = w / imgW;
        rect = Rect.fromLTWH(
          box.left * sc,
          box.top * sc,
          box.width * sc,
          box.height * sc,
        );
      } else {
        // 方形出界要裁到照片邊界、橢圓不裁——匯出端是同一個算式
        //（photoMosaicRect）。兩邊的 rect 不同的話，像素化格數是
        //「對 rect 均分」、羽化寬是「rect 短邊比例」，格子大小跟柔邊
        // 就對不上成品
        rect = photoMosaicRect(m, w, h);
        if (rect.width <= 0 || rect.height <= 0) continue;
      }
      final hitId = (kind: 0, index: i, part: WmPart.none, logo: -1);
      // 「亮一下」：疊在所有馬賽克上面（迴圈跑完才放進去）
      if (_mosaicMode && _flashIds.contains(i)) {
        glows.add(
          Positioned.fromRect(
            rect: rect.inflate(_FlashGlow.pad),
            child: IgnorePointer(
              child: _FlashGlow(
                key: ValueKey('flash-$_flashToken-$i'),
                oval: m.oval && !m.isStroke,
              ),
            ),
          ),
        );
      }
      if (m.off) {
        // 點掉的臉：只留一圈虛線，點一下就回來（點擊由上面的判定層
        // 統一處理，見 _phTapAt）
        _phBox[hitId] = rect;
        children.add(
          Positioned.fromRect(
            rect: rect,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggleFace(i),
              child: IgnorePointer(
                child: CustomPaint(
                  painter: MosaicOutlinePainter(
                    oval: m.oval,
                    dashed: true,
                    color: Colors.white,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
        );
        continue;
      }
      // 馬賽克模式的臉：點一下是切換碼／不碼，不是選取，也不給拖
      final faceTap = _mosaicMode && m.face;
      Widget effect;
      if (m.isStroke) {
        // 筆畫效果＝共用畫家（跟匯出同一段程式碼）；
        // 調色時同一個矩陣套在補丁上，顏色才會對。
        // 純色遮蓋（type 2）不套：使用者挑什麼顏色就是什麼顏色——匯出
        //（paintMosaicStroke）跟方形純色補丁都畫原色，這裡以前一律包
        // ColorFiltered，亮度 +30% 的預覽把純紅抬成 (255,76,76)、成品
        // 卻是 (255,0,0)
        Widget patch = _mosaicBase == null
            ? const SizedBox.shrink()
            : CustomPaint(
                painter: _MosaicStrokePainter(
                  img: _mosaicBase!,
                  style: m.style,
                  strokePts: m.stroke!,
                  brush: m.brush,
                ),
              );
        if (_grade.hasColor && !_colorCompare && m.style.type != 2) {
          patch = ColorFiltered(
            colorFilter: ColorFilter.matrix(_grade.matrix),
            child: patch,
          );
        }
        effect = patch;
      } else if (m.style.type == 2) {
        effect = m.oval
            ? ClipOval(child: ColoredBox(color: Color(m.style.color)))
            : Container(color: Color(m.style.color));
      } else if (_mosaicBase != null) {
        // 直接取樣照片畫效果：真像素塊、真羽化（跟匯出同一套畫法，
        // web 也一樣）。調色時把同一個矩陣套在補丁上，顏色才會對
        Widget patch = CustomPaint(
          painter: _MosaicPatchPainter(
            img: _mosaicBase!,
            style: m.style,
            srcRect: Rect.fromLTWH(
              rect.left * _mosaicBase!.width / w,
              rect.top * _mosaicBase!.height / h,
              rect.width * _mosaicBase!.width / w,
              rect.height * _mosaicBase!.height / h,
            ),
            oval: m.oval,
          ),
        );
        if (_grade.hasColor && !_colorCompare) {
          patch = ColorFiltered(
            colorFilter: ColorFilter.matrix(_grade.matrix),
            child: patch,
          );
        }
        effect = patch;
      } else {
        ui.ImageFilter? filter;
        if (m.style.type == 0 && _mosaicProg != null) {
          final cells = (26 - 20 * m.style.strength).round().clamp(4, 40);
          final dpr = MediaQuery.of(context).devicePixelRatio;
          final cell = math.max(2.0, rect.width * dpr / cells);
          try {
            final sh = _mosaicProg!.fragmentShader();
            sh.setFloat(2, cell);
            filter = ui.ImageFilter.shader(sh);
          } catch (_) {
            filter = null;
          }
        }
        final sigma = 4.0 + 16 * m.style.strength;
        filter ??= ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
        final backdrop = BackdropFilter(
          filter: filter,
          child: const SizedBox.expand(),
        );
        effect = m.oval ? ClipOval(child: backdrop) : ClipRect(child: backdrop);
      }
      _phBox[hitId] = rect;
      children.add(
        Positioned.fromRect(
          rect: rect,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 點擊統一由上面那層判定（重疊時要能往下鑽），
            // 這裡留著只是萬一那層沒攔到的退路
            onTap: () {
              if (faceTap) {
                _toggleFace(i);
              } else if (_mosaicMode) {
                _flash({i});
              } else if (_selMosaic == i) {
                _editMosaic(i);
              } else {
                setState(() {
                  _selMosaic = i;
                  _wmPart = WmPart.none;
                  _selExtra = -1;
                });
              }
            },
            // 手勢本體在 _mosaicDragStart／_mosaicDragUpdate：這一塊被
            // 選取時，整面的「選取路由」也走同一套（見預覽 Stack 最上層）
            onPanStart: faceTap ? null : (_) => _mosaicDragStart(i),
            onPanUpdate: faceTap ? null : (d) => _mosaicDragUpdate(m, d, w, h),
            onPanEnd: faceTap ? null : (_) => _mosaicDragEnd(),
            onPanCancel: faceTap ? null : _mosaicDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                effect,
                // 選取框跟浮水印同一套：琥珀細框（白框落在亮照片
                // 或白色馬賽克上會整個看不見，見 theme 的 kSelect）。
                // 筆刷塗抹中不畫——正在畫的那一筆被框住很干擾。
                // 馬賽克模式整個不畫框（使用者：「馬賽克不要有邊框」）：
                // 照片上看到的就是成品，認哪一塊靠「亮一下」
                if (_selMosaic == i && !_brushMode && !_mosaicMode)
                  IgnorePointer(
                    child: m.oval
                        ? CustomPaint(
                            painter: MosaicOutlinePainter(
                              oval: true,
                              dashed: false,
                              color: kSelect,
                              width: 1.4,
                            ),
                          )
                        : Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: kSelect, width: 1.4),
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    children.addAll(glows);
    return Stack(clipBehavior: Clip.hardEdge, children: children);
  }

  void _addMosaic() {
    _pushUndo();
    if (_mosaicMode) {
      // 馬賽克模式：照下面那排選的樣式、形狀、大小；放在空的地方、
      // 亮一下，不選取（照片上沒有框，選了也看不出來）
      final scale = (_kMzNewScale * _mzSize).clamp(0.05, 3.0);
      final at = _freeSpot(scale);
      setState(() {
        _mosaics.add(
          PhotoMosaic(
            x: at.dx,
            y: at.dy,
            scale: scale,
            style: _mzStyle.copy(),
            oval: _mzOval,
          ),
        );
        _selMosaic = -1;
        _wmPart = WmPart.none;
        _selExtra = -1;
      });
      _flash({_mosaics.length - 1});
      return;
    }
    setState(() {
      _mosaics.add(PhotoMosaic());
      _selMosaic = _mosaics.length - 1;
      _wmPart = WmPart.none;
      _selExtra = -1;
    });
  }

  /// 馬賽克模式新加一塊方框的大小（短邊比例）：要蓋的通常是招牌、車牌、
  /// 包包上的標誌這種小東西；一般模式的 0.72 一放下去就蓋掉半張照片
  static const double _kMzNewScale = 0.4;

  /// 新的一塊放哪（0~1）：照片上挑跟現有馬賽克重疊最少的位置，一樣少就挑
  /// 離正中央近的。以前一律放正中央，連按兩次方框第二塊剛好疊在第一塊上，
  /// 看起來像「只能加一塊」（使用者回報）
  Offset _freeSpot(double scale) {
    final img = _photoImg;
    final w = (img?.width ?? 1000).toDouble();
    final h = (img?.height ?? 1000).toDouble();
    final taken = [
      for (final m in _mosaics)
        m.isStroke ? _strokeRectPx(m, w, h) : photoMosaicRect(m, w, h),
    ];
    final side = scale * math.min(w, h);
    var best = const Offset(0.5, 0.5);
    var bestCover = double.infinity, bestDist = double.infinity;
    const steps = [0.2, 0.35, 0.5, 0.65, 0.8];
    for (final cy in steps) {
      for (final cx in steps) {
        // 出界太多的不要：方形會被裁小、橢圓會缺一大角
        if (cx * w < side * 0.35 ||
            (1 - cx) * w < side * 0.35 ||
            cy * h < side * 0.35 ||
            (1 - cy) * h < side * 0.35) {
          continue;
        }
        final r = photoMosaicRect(
          PhotoMosaic(x: cx, y: cy, scale: scale, oval: _mzOval),
          w,
          h,
        );
        if (r.width <= 0 || r.height <= 0) continue;
        var cover = 0.0;
        for (final t in taken) {
          final o = r.intersect(t);
          if (o.width > 0 && o.height > 0) cover += o.width * o.height;
        }
        cover /= r.width * r.height;
        final dist = (cx - 0.5) * (cx - 0.5) + (cy - 0.5) * (cy - 0.5);
        if (cover < bestCover - 1e-6 ||
            ((cover - bestCover).abs() <= 1e-6 && dist < bestDist)) {
          best = Offset(cx, cy);
          bestCover = cover;
          bestDist = dist;
        }
      }
    }
    return best;
  }

  /// 筆畫的範圍（照片像素）：跟 _buildMosaics、匯出同一個算式
  Rect _strokeRectPx(PhotoMosaic m, double w, double h) {
    final pts = [
      for (var k = 0; k + 1 < m.stroke!.length; k += 2)
        Offset(m.stroke![k] * w, m.stroke![k + 1] * h),
    ];
    final brushPx = m.brush * math.min(w, h);
    return strokeBoundsPx(pts, brushPx, strokeFeatherPx(m.style, brushPx));
  }

  /// 讓這幾塊「亮一下」；剛加的捲到縮圖那排最後看得到
  void _flash(Set<int> ids) {
    if (ids.isEmpty) return;
    setState(() {
      _flashIds = ids;
      _flashToken++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stripCtrl.hasClients) return;
      final i = ids.reduce(math.max);
      if (i < _mosaics.length - 1) return;
      _stripCtrl.animateTo(
        _stripCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  // ===== 自動找臉（馬賽克模式）=====
  /// 找照片裡的臉，每張臉加一塊橢圓馬賽克（已經碼著的同一張臉不重複加）。
  /// [auto]＝一進來自動跑的那一次：不算一步上一步，也不算「改過了」
  ///（什麼都沒動就離開，不該被問要不要留草稿）
  Future<void> _findFaces({bool auto = false}) async {
    final img = _photoImg;
    if (_findingFaces || img == null) return;
    setState(() => _findingFaces = true);
    final found = await FaceDetect.inPhoto(widget.photo.path);
    if (!mounted) return;
    setState(() => _findingFaces = false);
    if (found == null) {
      showHint(context, '這張照片沒辦法自動找臉，可以用方框或筆刷', error: !auto);
      return;
    }
    // 馬賽克模式不給換畫布比例：畫布就是照片，偵測框直接當畫布座標
    final w = img.width.toDouble(), h = img.height.toDouble();
    final add = <PhotoMosaic>[];
    for (final f in found) {
      final m = faceMosaic(f, w, h, style: _mzStyle, oval: _mzOval);
      // 大小滑桿拉過：新找到的臉也照同一個大小，跟其他塊一致
      m.scale = (m.scale * _mzSize).clamp(0.02, 3.0);
      final r = photoMosaicRect(m, w, h);
      final dup = [
        ..._mosaics,
        ...add,
      ].any((e) => e.face && _overlapRatio(photoMosaicRect(e, w, h), r) > 0.3);
      if (!dup) add.add(m);
    }
    if (add.isEmpty) {
      showHint(context, found.isEmpty ? '沒有找到臉，可以用方框或筆刷' : '找到的臉都已經碼上了');
      return;
    }
    if (!auto) _pushUndo();
    final from = _mosaics.length;
    setState(() {
      _mosaics.addAll(add);
      _selMosaic = -1;
    });
    // 自己按的那次：新碼上的臉亮一下（一進來自動找的不用，整張都是新的）
    if (!auto) _flash({for (var i = from; i < _mosaics.length; i++) i});
    // 找的途中使用者已經動手改了就不重設（那些改動要算數）
    if (auto && _undoStack.isEmpty) _initialJson = _stateJson;
  }

  /// 兩個框的重疊程度（交集÷聯集）
  static double _overlapRatio(Rect a, Rect b) {
    final i = a.intersect(b);
    if (i.width <= 0 || i.height <= 0) return 0;
    final inter = i.width * i.height;
    return inter / (a.width * a.height + b.width * b.height - inter);
  }

  /// 點一下臉：碼↔不碼（點掉的留著虛線框，再點一下就回來）
  void _toggleFace(int i) {
    if (i < 0 || i >= _mosaics.length) return;
    _pushUndo();
    setState(() {
      _mosaics[i].off = !_mosaics[i].off;
      _selMosaic = -1;
    });
  }

  /// 下面那排改了樣式：套到每一塊，之後新加的也照這個
  void _mzApply(void Function(MosaicStyle s) f) {
    f(_mzStyle);
    for (final m in _mosaics) {
      f(m.style);
    }
  }

  /// 馬賽克模式的面板（取代浮水印面板；使用者在畫布選的甲＋二）：
  /// 最上面一排每一塊的縮圖＋虛線加號、效果＋形狀、大小（全部一起）、
  /// 濃度（純色是顏色）。改樣式／大小＝每一塊一起改；新增在浮動列的
  /// 「新增馬賽克」或縮圖那排最後的加號
  Widget _mosaicModePanel() {
    Widget tile({
      required bool on,
      required String label,
      required Widget art,
      required VoidCallback onTap,
      int flex = 68,
    }) => Expanded(
      flex: flex,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: on ? null : onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 62),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          // 設定面板裡的「選項」一律白框白字＋亮底（同樣式表的 chip）
          decoration: BoxDecoration(
            color: on ? kPanelHi : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: on ? kAmber : kClipBorder,
              width: on ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              art,
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    color: kText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    void setType(int type) {
      _pushUndo();
      setState(() => _mzApply((s) => s.type = type));
    }

    void setOval(bool oval) {
      _pushUndo();
      setState(() {
        _mzOval = oval;
        for (final m in _mosaics) {
          if (!m.isStroke) m.oval = oval;
        }
      });
    }

    Widget shapeIcon(IconData icon, bool on) =>
        Icon(icon, size: 22, color: on ? kText : kTextDim);

    return SingleChildScrollView(
      // 底下讓出浮動鈕列（字級放大塞不下時捲得到最後一排）
      padding: EdgeInsets.fromLTRB(16, 10, 16, _mzBarHeight(context) + 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mosaicStrip(),
          const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  on: _mzStyle.type == 0,
                  label: '像素化',
                  art: const _MzSwatch(0),
                  onTap: () => setType(0),
                ),
                const SizedBox(width: 8),
                tile(
                  on: _mzStyle.type == 1,
                  label: '模糊',
                  art: const _MzSwatch(1),
                  onTap: () => setType(1),
                ),
                const SizedBox(width: 8),
                tile(
                  on: _mzStyle.type == 2,
                  label: '純色',
                  art: _MzSwatch(2, color: _mzStyle.color),
                  onTap: () => setType(2),
                ),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  color: kClipBorder,
                ),
                tile(
                  on: _mzOval,
                  label: '圓形',
                  flex: 54,
                  art: shapeIcon(Icons.circle_outlined, _mzOval),
                  onTap: () => setOval(true),
                ),
                const SizedBox(width: 8),
                tile(
                  on: !_mzOval,
                  label: '方形',
                  flex: 54,
                  art: shapeIcon(Icons.crop_square, !_mzOval),
                  onTap: () => setOval(false),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 滑桿拖動中只重畫預覽（_liveRepaint），不整頁 setState；這兩條
          // 自己跟著同一個訊號重畫，拇指才跟得上手指（以前放手才跳過去）
          ValueListenableBuilder<int>(
            valueListenable: _liveTick,
            builder: (context, _, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sliderRow(
                  label: '大小',
                  value: _mzSize,
                  min: 0.5,
                  max: 2.0,
                  readout: '${(_mzSize * 100).round()}',
                  unit: '%',
                  onChangeStart: (_) => _mzSizeStart(),
                  onChanged: _mzSizeChange,
                  onChangeEnd: (_) => _liveEnd(),
                ),
                if (_mzStyle.type != 2)
                  sliderRow(
                    label: '濃度',
                    value: _mzStyle.strength,
                    min: 0,
                    max: 1,
                    readout: '${(_mzStyle.strength * 100).round()}',
                    unit: '%',
                    onChangeStart: (_) => _pushUndo(),
                    onChanged: (v) {
                      _mzApply((s) => s.strength = v);
                      _liveRepaint();
                    },
                    onChangeEnd: (_) => _liveEnd(),
                  )
                else
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const SizedBox(
                          width: kSliderLabelW,
                          child: Text(
                            '顏色',
                            style: TextStyle(fontSize: 12, color: kTextDim),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () async {
                            final picked = await pickColor(
                              context,
                              Color(_mzStyle.color),
                            );
                            if (picked == null || !mounted) return;
                            _pushUndo();
                            setState(() => _mzApply((s) => s.color = picked));
                          },
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: Color(_mzStyle.color),
                              shape: BoxShape.circle,
                              border: Border.all(color: kBorder, width: 1.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 馬賽克模式浮動鈕列的漸層高度（一般模式是 40）
  static const double _kMzBarFade = 12;

  /// 馬賽克模式浮動鈕列佔掉的高度：漸層＋鈕（含觸控留白 48）＋下緣＋安全區
  double _mzBarHeight(BuildContext context) =>
      _kMzBarFade + 48 + 10 + MediaQuery.paddingOf(context).bottom;

  /// 馬賽克模式的下半部固定這麼高：四排（縮圖、效果、大小、濃度）＋浮動鈕列
  /// 剛好放得下、不用捲，剩下的高度全給照片（手機越高照片越大）。
  /// 以前是上 6 下 4 的比例：面板塞不下，最後一排滑桿被鈕列的漸層蓋成灰的
  double _mzPanelHeight(BuildContext context) {
    // 字級放大時多留一點（磚上的字、滑桿的字跟著變高）；再大就捲
    final t = (MediaQuery.textScalerOf(context).scale(12) / 12).clamp(1.0, 2.0);
    const content = 10 + 52 + 14 + 66 + 10 + 34 + 40 + 6;
    return content + (t - 1) * 40 + _mzBarHeight(context);
  }

  /// 下半部（面板＋浮動鈕列）：一般模式照比例分（上 4 下 6），
  /// 馬賽克模式固定高度、其餘全給照片
  Widget _panelArea(Widget child) => _mosaicMode
      ? SizedBox(height: _mzPanelHeight(context), child: child)
      : Expanded(flex: 6, child: child);

  /// 大小滑桿按下去：拍一次上一步，記下這一刻每一塊的大小
  void _mzSizeStart() {
    _pushUndo();
    _mzSizeFrom = _mzSize;
    _mzSizeBase = [for (final m in _mosaics) m.isStroke ? m.brush : m.scale];
  }

  /// 大小滑桿每一格：每一塊照按下去那一刻的大小一起乘上同一個倍率
  ///（筆畫乘的是粗細）。只重畫預覽，放手才整頁補一次
  void _mzSizeChange(double v) {
    _mzSize = v;
    final f = v / _mzSizeFrom;
    for (var i = 0; i < _mosaics.length && i < _mzSizeBase.length; i++) {
      final m = _mosaics[i];
      if (m.isStroke) {
        m.brush = (_mzSizeBase[i] * f).clamp(0.02, 0.6);
      } else {
        m.scale = (_mzSizeBase[i] * f).clamp(0.02, 3.0);
      }
    }
    _liveRepaint();
  }

  /// 最上面那排：每一塊馬賽克一格縮圖（照片上不畫框，有幾塊、加了沒，
  /// 在這裡一眼看得到），最後一格虛線加號＝新增。點縮圖＝那一塊亮一下
  ///（臉是碼／不碼切換，跟點照片上的臉一樣）；長按＝壓暗＋刪除
  Widget _mosaicStrip() => SizedBox(
    height: 52,
    child: ListView(
      controller: _stripCtrl,
      scrollDirection: Axis.horizontal,
      children: [
        for (var i = 0; i < _mosaics.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _mosaicThumb(i),
          ),
        Semantics(
          button: true,
          label: '新增馬賽克',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _brushMode || _findingFaces ? null : _askAddMosaic,
            child: CustomPaint(
              painter: const _DashedTilePainter(),
              child: SizedBox(
                width: 52,
                height: 52,
                // 找臉中這一格轉圈（按了「自動碼人臉」選單就收了，
                // 要有個地方看得出還在找）
                child: _findingFaces
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add, size: 24, color: kText),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _mosaicThumb(int i) {
    final m = _mosaics[i];
    return Builder(
      builder: (tileCtx) => Semantics(
        button: true,
        label: m.face ? (m.off ? '沒碼的臉' : '臉') : (m.isStroke ? '筆刷' : '方框'),
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () => _thumbTap(i),
          onLongPress: () => _askDeleteMosaic(i, tileContext: tileCtx),
          child: Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPanelHi,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kClipBorder),
            ),
            child: _mosaicArt(m, 38),
          ),
        ),
      ),
    );
  }

  /// 點縮圖：臉＝碼／不碼（同點照片上的臉），其他＝照片上那一塊亮一下
  void _thumbTap(int i) {
    if (i < 0 || i >= _mosaics.length) return;
    if (_mosaics[i].face) _toggleFace(i);
    _flash({i});
  }

  /// 一塊馬賽克的小圖（縮圖、長按浮起來那塊共用）：照片上那一塊範圍套上
  /// 同一個效果，等比塞進 [box]×[box]（筆畫照筆畫的範圍）。
  /// 點掉的臉畫原圖＋虛線圈（跟照片上一樣）
  Widget _mosaicArt(PhotoMosaic m, double box) {
    final img = _mosaicBase;
    if (img == null) return Icon(Icons.blur_on, size: box * 0.6, color: kIcon);
    final w = img.width.toDouble(), h = img.height.toDouble();
    final src = m.isStroke ? _strokeRectPx(m, w, h) : photoMosaicRect(m, w, h);
    if (src.width <= 0 || src.height <= 0) {
      return SizedBox(width: box, height: box);
    }
    final ar = src.width / src.height;
    final size = ar >= 1 ? Size(box, box / ar) : Size(box * ar, box);
    final CustomPainter painter;
    if (m.off) {
      painter = _CropPainter(img: img, srcRect: src, oval: m.oval);
    } else if (m.isStroke) {
      painter = _MosaicStrokePainter(
        img: img,
        style: m.style,
        strokePts: m.stroke!,
        brush: m.brush,
      );
    } else {
      painter = _MosaicPatchPainter(
        img: img,
        style: m.style,
        srcRect: src,
        oval: m.oval,
      );
    }
    Widget art = SizedBox.fromSize(
      size: size,
      child: CustomPaint(
        painter: painter,
        foregroundPainter: m.off
            ? MosaicOutlinePainter(
                oval: m.oval,
                dashed: true,
                color: Colors.white,
                width: 1.2,
              )
            : null,
      ),
    );
    // 超出照片的那一截照片上看不到（畫布裁掉了），小圖也切掉，
    // 不然會多畫一塊黑的
    final vis = src.intersect(Offset.zero & Size(w, h));
    if (vis != src && vis.width > 0 && vis.height > 0) {
      art = ClipRect(
        clipper: _FracClipper(
          Rect.fromLTRB(
            (vis.left - src.left) / src.width,
            (vis.top - src.top) / src.height,
            (vis.right - src.left) / src.width,
            (vis.bottom - src.top) / src.height,
          ),
        ),
        child: art,
      );
    }
    return art;
  }

  /// 長按一塊（縮圖，或照片上的那一塊——[rect] 是它的螢幕位置）：背景壓暗、
  /// 那一塊浮起來，旁邊小選單問要不要刪（使用者定的刪除手勢，同草稿夾、範本）
  Future<void> _askDeleteMosaic(
    int i, {
    BuildContext? tileContext,
    Rect? rect,
  }) async {
    if (i < 0 || i >= _mosaics.length || _brushMode) return;
    final m = _mosaics[i];
    const actions = [
      LibraryMenuAction(
        'delete',
        '刪除',
        icon: Icons.delete_outline,
        destructive: true,
      ),
    ];
    final String? act;
    if (rect != null) {
      act = await showTileMenuAt<String>(
        context,
        rect: rect,
        preview: Center(child: _mosaicArt(m, rect.longestSide)),
        actions: actions,
        radius: m.oval && !m.isStroke ? rect.shortestSide / 2 : 4,
      );
    } else if (tileContext != null) {
      act = await showLibraryTileMenu<String>(
        tileContext,
        preview: ColoredBox(
          color: kPanelHi,
          child: Center(child: _mosaicArt(m, 38)),
        ),
        actions: actions,
        radius: 12,
      );
    } else {
      return;
    }
    if (act != 'delete' || !mounted) return;
    // 選單開著的時候清單不會變，保險起見還是照物件找回來
    final at = _mosaics.indexOf(m);
    if (at < 0) return;
    _pushUndo();
    setState(() {
      _mosaics.removeAt(at);
      _selMosaic = -1;
      _flashIds = const {};
    });
  }

  /// 「新增馬賽克」：跟影片剪輯那張馬賽克選單同一個樣子
  ///（使用者在畫布選的）。自動碼人臉／方框／筆刷
  Future<void> _askAddMosaic() async {
    if (_brushMode || _findingFaces) return;
    Widget item(BuildContext context, IconData icon, String label, String v) =>
        InkWell(
          onTap: () => Navigator.pop(context, v),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            child: Row(
              children: [
                Icon(icon, size: 21, color: kAmber),
                const SizedBox(width: 15),
                Text(label, style: const TextStyle(fontSize: 14, color: kText)),
              ],
            ),
          ),
        );
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '新增馬賽克',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
            item(context, Icons.face_retouching_natural, '自動碼人臉', 'face'),
            item(context, Icons.crop_square, '方框', 'box'),
            item(context, Icons.brush_outlined, '筆刷', 'brush'),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (pick) {
      case 'face':
        await _findFaces();
      case 'box':
        _addMosaic();
      case 'brush':
        _startBrush();
    }
  }

  /// 進筆刷塗抹：照下面那排選的樣式畫，直接開全螢幕
  void _startBrush() {
    setState(() {
      _brushStyle
        ..type = _mzStyle.type
        ..strength = _mzStyle.strength
        ..feather = _mzStyle.feather
        ..color = _mzStyle.color;
      _brushMode = true;
      _selMosaic = -1;
      _fsView = true;
      _fsBrushOpen = true;
    });
  }

  // ===== 馬賽克拖曳（方塊自己的手勢與整面的選取路由共用）=====
  /// 起手：選起這一塊、只記「要拍快照」——真的拖到才拍
  ///（理由見 _phPushUndoIfNeeded）
  void _mosaicDragStart(int i) {
    if (_pvPts.length >= 2) return;
    _phClearGuides();
    _phUndoPending = true;
    // 馬賽克模式不選取：照片上沒有框，選了也看不出來，留著的選取還會
    // 讓下一次在別處拖曳時把它拖走（選取路由）。拖曳本身就作用在這一塊
    if (_mosaicMode) return;
    setState(() {
      _selMosaic = i;
      _wmPart = WmPart.none;
      _selExtra = -1;
    });
  }

  /// 每一格：方塊＝原始座標累積、顯示值吸中線（同浮水印手感）；
  /// 筆畫＝所有點一起平移（不吸中線，形狀是自由的）
  void _mosaicDragUpdate(
    PhotoMosaic m,
    DragUpdateDetails d,
    double w,
    double h,
  ) {
    if (_pvPts.length >= 2) return;
    _phPushUndoIfNeeded();
    if (m.isStroke) {
      final s = m.stroke!;
      for (var k = 0; k + 1 < s.length; k += 2) {
        s[k] += d.delta.dx / w;
        s[k + 1] += d.delta.dy / h;
      }
      _liveRepaint();
      return;
    }
    _phRawX ??= m.x;
    _phRawY ??= m.y;
    _phRawX = (_phRawX! + d.delta.dx / w).clamp(0.0, 1.0);
    _phRawY = (_phRawY! + d.delta.dy / h).clamp(0.0, 1.0);
    m.x = _snapC(_phRawX!);
    m.y = _snapC(_phRawY!);
    _liveRepaint();
    _phSetGuides(m.x, m.y);
  }

  /// 拖曳結束（馬賽克／選取路由共用）：收輔助線、整頁補一次 setState
  void _mosaicDragEnd() {
    _phClearGuides();
    _liveEnd();
  }

  /// 選取路由的每一格：整面的拖曳套到被選的那個部件——主浮水印或某一組
  /// 額外浮水印都走這裡。原始座標累積、顯示值吸中線（同 WatermarkLayer
  /// 的手感）
  void _routeDragUpdate(
    WatermarkSettings s,
    WmPart part,
    DragUpdateDetails d,
    double w,
    double h,
  ) {
    if (_pvPts.length >= 2) return;
    _phPushUndoIfNeeded();
    final t = s.text;
    final lg = s.logo;
    final isText =
        part == WmPart.text &&
        t.enabled &&
        !t.tiled &&
        t.text.trim().isNotEmpty;
    final isLogo = part == WmPart.logo && lg.enabled && !lg.tiled;
    if (!isText && !isLogo) return;
    _phRawX ??= isText ? t.x : lg.x;
    _phRawY ??= isText ? t.y : lg.y;
    _phRawX = (_phRawX! + d.delta.dx / w).clamp(0.0, 1.0);
    _phRawY = (_phRawY! + d.delta.dy / h).clamp(0.0, 1.0);
    final x = _snapC(_phRawX!), y = _snapC(_phRawY!);
    if (isText) {
      t.x = x;
      t.y = y;
    } else {
      lg.x = x;
      lg.y = y;
    }
    _liveRepaint();
    _phSetGuides(x, y);
  }

  /// 選取路由：有部件被選取（琥珀框）時，整個預覽的拖曳都只動被選的
  /// 那個——跟影片編輯同一套規則。translucent：點擊照樣穿透給判定層。
  ///
  /// 主浮水印跟每一組額外浮水印都用這一層。額外組以前沒有路由：被選的
  /// 那組若被後加的那組壓住（後加的 opaque、選了別組時不註冊拖曳），
  /// 命中測試停在上面那組、指標到不了被選的，拖不動——跟 c471ff1
  /// 修過的「馬賽克被文字壓住」同一型
  Widget _routeLayer(Key key, WatermarkSettings s, WmPart part) =>
      Positioned.fill(
        key: key,
        child: LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) {
              _phClearGuides();
              if (_pvPts.length < 2) _phUndoPending = true;
            },
            onPanUpdate: (d) =>
                _routeDragUpdate(s, part, d, box.maxWidth, box.maxHeight),
            onPanEnd: (_) => _mosaicDragEnd(),
            onPanCancel: _mosaicDragEnd,
            child: const SizedBox.expand(),
          ),
        ),
      );

  // ===== 筆刷馬賽克：塗到哪、碼到哪 =====
  /// 筆刷模式中：預覽整面接管拖曳，一筆＝一塊筆畫馬賽克
  bool _brushMode = false;

  /// 筆刷工具列上選的樣式與粗細（給接下來畫的每一筆；
  /// 改的當下也套用到剛畫好的那一筆——塗完才想換樣式是常態）
  final MosaicStyle _brushStyle = MosaicStyle();
  double _brushSize = 0.16;

  /// 柔邊每個模式各記各的：模糊調過的柔邊不能跑到像素化／純色去
  final Map<int, double> _brushFeatherByType = {};

  /// 剛畫好、還在筆刷模式裡選取中的那一筆（沒有就 null）
  PhotoMosaic? get _brushSel =>
      (_selMosaic >= 0 &&
          _selMosaic < _mosaics.length &&
          _mosaics[_selMosaic].isStroke)
      ? _mosaics[_selMosaic]
      : null;

  /// 筆刷塗抹中的調整面板：塗抹時整個下面的面板換成它
  ///（樣式、粗細、濃度、柔邊、顏色全在這裡，跟其他卡同一種長相）
  Widget _brushPanel() {
    Widget chip(String label, int type) {
      final on = _brushStyle.type == type;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() {
              // 柔邊各模式自己的：先把現在的存回去，再拿新模式的出來
              _brushFeatherByType[_brushStyle.type] = _brushStyle.feather;
              _brushStyle.type = type;
              _brushStyle.feather = _brushFeatherByType[type] ?? 0.0;
              _brushSel?.style.type = type;
              _brushSel?.style.feather = _brushStyle.feather;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? kPanelHi : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kClipBorder, width: 1),
              ),
              foregroundDecoration: on
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kAmber, width: 1.5),
                    )
                  : null,
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

    Widget row(String label, Widget child, [Widget? trail]) => Row(
      children: [
        SizedBox(
          width: kSliderLabelW,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: kTextDim),
          ),
        ),
        Expanded(child: child),
        if (trail != null) SizedBox(width: 40, child: trail),
      ],
    );

    Text pct(double v) => Text(
      '${(v * 100).round()}%',
      textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 11.5, color: kTextDim),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 90),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.brush_outlined, size: 16, color: kAmber),
              const SizedBox(width: 8),
              const Text(
                '筆刷塗抹',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() => _brushMode = false),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: kAmber,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    '完成',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // 提示降一階：小一號、更暗，排在標題底下不跟它搶
          const Padding(
            padding: EdgeInsets.only(top: 3, left: 24),
            child: Text(
              '點右上角可以放大照片來塗',
              style: TextStyle(fontSize: 10.5, color: Color(0xFF6E6E7A)),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [chip('像素化', 0), chip('模糊', 1), chip('純色遮蓋', 2)]),
          const SizedBox(height: 12),
          row(
            '粗細',
            Slider(
              value: _brushSize.clamp(0.03, 0.5),
              min: 0.03,
              max: 0.5,
              onChanged: (v) => setState(() {
                _brushSize = v;
                _brushSel?.brush = v;
              }),
            ),
            pct(_brushSize),
          ),
          if (_brushStyle.type != 2) ...[
            row(
              '濃度',
              Slider(
                value: _brushStyle.strength,
                onChanged: (v) => setState(() {
                  _brushStyle.strength = v;
                  _brushSel?.style.strength = v;
                }),
              ),
              pct(_brushStyle.strength),
            ),
            // 柔邊只給模糊：像素化的重點就是硬邊的格子，
            // 暈開反而奇怪（使用者指定拿掉）
            if (_brushStyle.type == 1)
              row(
                '柔邊',
                Slider(
                  value: _brushStyle.feather,
                  onChanged: (v) => setState(() {
                    _brushStyle.feather = v;
                    _brushSel?.style.feather = v;
                  }),
                ),
                pct(_brushStyle.feather),
              ),
          ] else ...[
            // 純色遮蓋：自己的柔邊（跟模糊各記各的）＋顏色
            row(
              '柔邊',
              Slider(
                value: _brushStyle.feather,
                onChanged: (v) => setState(() {
                  _brushStyle.feather = v;
                  _brushSel?.style.feather = v;
                }),
              ),
              pct(_brushStyle.feather),
            ),
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
                        Color(_brushStyle.color),
                      );
                      if (picked != null) {
                        setState(() {
                          _brushStyle.color = picked;
                          _brushSel?.style.color = picked;
                        });
                      }
                    },
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(_brushStyle.color),
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
    );
  }

  void _brushStart(Offset p, double w, double h) {
    if (_pvPts.length >= 2) return;
    _pushUndo();
    setState(() {
      _mosaics.add(
        PhotoMosaic(
          // 樣式與粗細照工具列上選的
          style: _brushStyle.copy(),
          brush: _brushSize,
          stroke: [(p.dx / w).clamp(0.0, 1.0), (p.dy / h).clamp(0.0, 1.0)],
        ),
      );
      _selMosaic = _mosaics.length - 1;
      _wmPart = WmPart.none;
      _selExtra = -1;
    });
  }

  void _brushMove(Offset p, double w, double h) {
    if (_pvPts.length >= 2) return;
    if (_selMosaic < 0 || _selMosaic >= _mosaics.length) return;
    final m = _mosaics[_selMosaic];
    final s = m.stroke;
    if (s == null || s.length < 2) return;
    final nx = (p.dx / w).clamp(0.0, 1.0);
    final ny = (p.dy / h).clamp(0.0, 1.0);
    // 點太密不收（間隔門檻＝筆刷的 8%）：省記憶體也省每幀重繪；
    // 1200 點是安全帽，正常塗抹到不了
    final dist = Offset(
      (nx - s[s.length - 2]) * w,
      (ny - s[s.length - 1]) * h,
    ).distance;
    if (dist < m.brush * math.min(w, h) * 0.08 || s.length >= 1200) return;
    s
      ..add(nx)
      ..add(ny);
    _liveRepaint();
  }

  /// 馬賽克樣式表（照片版）：樣式＋大小＋濃度/顏色＋移除
  void _editMosaic(int i) {
    if (i < 0 || i >= _mosaics.length) return;
    final m = _mosaics[i];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          // 套用改動（畫面＋這張表都重畫）
          void set(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          // 離散改動（換樣式、挑顏色）：每一下各拍一次快照。
          // 以前整張表開著只拍一次，連換兩次樣式再按上一步會一次全退。
          // 滑桿不走這裡：按下那一刻拍一次（onChangeStart），拖動中不拍
          void change(VoidCallback f) {
            _pushUndo();
            set(f);
          }

          Widget chip(String label, int type) {
            final on = m.style.type == type;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => change(() => m.style.type = type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    alignment: Alignment.center,
                    // 設定面板裡的「選項」一律白框白字＋亮底
                    //（琥珀只留給疊在使用者照片上的東西，見 theme.dart）
                    decoration: BoxDecoration(
                      color: on ? kPanelHi : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kClipBorder, width: 1),
                    ),
                    // 粗框畫在前景，字不位移（同影片編輯）
                    foregroundDecoration: on
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: kAmber, width: 1.5),
                          )
                        : null,
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

          Widget row(String label, Widget child, [Widget? trail]) => Row(
            children: [
              SizedBox(
                width: kSliderLabelW,
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
              Expanded(child: child),
              if (trail != null) SizedBox(width: 40, child: trail),
            ],
          );

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
                    children: [
                      chip('像素化', 0),
                      chip('模糊', 1),
                      chip('純色', 2),
                      // 第四格不是樣式是動作：直接進筆刷模式，
                      // 樣式沿用這一塊調好的（換個手法碼同一種效果）
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              Navigator.pop(context);
                              setState(() {
                                _brushStyle.type = m.style.type;
                                _brushStyle.strength = m.style.strength;
                                _brushStyle.feather = m.style.feather;
                                _brushStyle.color = m.style.color;
                                _brushMode = true;
                                _selMosaic = -1;
                                _wmPart = WmPart.none;
                                _selExtra = -1;
                                _fsView = true;
                                _fsBrushOpen = true;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: kClipBorder,
                                  width: 1,
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.brush_outlined,
                                    size: 14,
                                    color: kText,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    '筆刷',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: kText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (m.isStroke)
                    row(
                      '粗細',
                      Slider(
                        value: m.brush.clamp(0.03, 0.5),
                        min: 0.03,
                        max: 0.5,
                        onChangeStart: (_) => _pushUndo(),
                        onChanged: (v) => set(() => m.brush = v),
                      ),
                      Text(
                        '${(m.brush * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11.5, color: kTextDim),
                      ),
                    )
                  else
                    row(
                      '大小',
                      // 上限跟影片端一致（原本這裡是 1.5、那邊 3.0，
                      // 同一個功能能拉的範圍卻不一樣）
                      Slider(
                        value: m.scale.clamp(0.05, 3.0),
                        min: 0.05,
                        max: 3.0,
                        onChangeStart: (_) => _pushUndo(),
                        onChanged: (v) => set(() => m.scale = v),
                      ),
                      Text(
                        '${(m.scale * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11.5, color: kTextDim),
                      ),
                    ),
                  if (m.style.type != 2) ...[
                    row(
                      '濃度',
                      Slider(
                        value: m.style.strength,
                        onChangeStart: (_) => _pushUndo(),
                        onChanged: (v) => set(() => m.style.strength = v),
                      ),
                      Text(
                        '${(m.style.strength * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11.5, color: kTextDim),
                      ),
                    ),
                    // 純色遮蓋是實心色塊，沒有邊可以柔；像素化跟模糊都吃得到
                    if (m.style.type != 2)
                      row(
                        '柔邊',
                        Slider(
                          value: m.style.feather,
                          onChangeStart: (_) => _pushUndo(),
                          onChanged: (v) => set(() => m.style.feather = v),
                        ),
                        Text(
                          '${(m.style.feather * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: kTextDim,
                          ),
                        ),
                      ),
                  ] else
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
                                Color(m.style.color),
                              );
                              if (picked != null) {
                                change(() => m.style.color = picked);
                              }
                            },
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: Color(m.style.color),
                                shape: BoxShape.circle,
                                border: Border.all(color: kBorder, width: 1.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  Center(
                    child: TextButton.icon(
                      onPressed: () {
                        _pushUndo();
                        setState(() {
                          _mosaics.removeAt(i);
                          _selMosaic = -1;
                        });
                        Navigator.pop(context);
                      },
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: kTextDim,
                      ),
                      label: const Text(
                        '移除馬賽克',
                        style: TextStyle(fontSize: 12, color: kTextDim),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 輸出前選格式——兩種格式差很多，使用者要知道差在哪。
  /// 點了格式就直接輸出（選擇即確認，不再多一層）
  Future<void> _confirmExport() async {
    if (_exporting) return;
    // 以前這裡還把選的格式寫進 SharedPreferences（photo_export_fmt），
    // 但沒有任何地方讀它——選格式的視窗不吃預設值。存了沒用就拿掉
    final fmt = await askPhotoFormat(context);
    if (fmt == null || !mounted) return;
    await _export(jpeg: fmt == 'jpg');
  }

  Future<void> _export({bool jpeg = false}) async {
    if (_exporting || _photoImg == null) return;
    // 用到的下載字型要先在手機裡（下載不了就擋下來，不然成品是後備字）。
    // 「更多浮水印」那幾組也一起畫進成品
    final fonts = {
      ..._settings.fontFamilies,
      for (final w in _extraWms) ...w.fontFamilies,
    };
    if (!await ensureExportFonts(context, fonts)) return;
    if (!mounted || _exporting) return;
    setState(() => _exporting = true);
    // PopScope：不擋的話返回鍵會把進度框關掉，
    // 輸出完成後那個 pop 就會把「編輯頁本身」關掉，改的東西全沒了
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('匯出中…'),
          content: SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    var message = '';
    String? note;
    var ok = true;
    try {
      final path = widget.photo.path;
      final hasPath = !kIsWeb && path.isNotEmpty;
      final name = 'watermarker_${DateTime.now().millisecondsSinceEpoch}';
      // 來源是 HDR 照片（iOS 17+）：走原生 HDR 路，出 10-bit HEIC——跟批次
      // 同一條 HdrPhotoExport。以前單張永遠走 SDR：同一張照片跟別張一起
      // 選（批次）是 HDR、單獨選進來就被壓平，使用者沒有任何提示。
      // 馬賽克跟調色原生路做不到（照片是在 dart:ui 解成 SDR 之後才取樣、
      // 才調的，疊回 HDR 只會是一塊塊發灰的補丁），這兩種情況照走 SDR，
      // 完成時講清楚；原生路失敗一樣退回 SDR（跟批次同一套退路）
      final hp = hasPath ? await HdrPhotoExport.probe(path) : null;
      final hdrSrc = hp != null && hp.hdr;
      // 點掉的臉不畫：只剩點掉的臉時照樣走得了 HDR 原生路
      final hdrBlocked = _mosaics.any((m) => !m.off) || _grade.hasColor;
      var saved = false;
      if (hdrSrc && !hdrBlocked) {
        final err = await HdrPhotoExport.exportToGallery(
          srcPath: path,
          probe: hp,
          settings: _settings,
          extraMarks: _extraWms,
          canvasAspect: _canvasAspect,
          quality: 92,
          name: name,
        );
        if (err == null) {
          // 跟 SDR 路（photo_saver）講同一句話，同一個相簿
          message = '已存到「浮水印」相簿';
          saved = true;
        }
      }
      if (!saved) {
        // 以原始解析度合成：回檔案重解一次全尺寸（手機上引擎直接讀檔，
        // 不經 Dart 堆；跟批次同一條路）。手上那張 _photoImg 是預覽用的
        // 縮圖（見 _decodeForPreview），成品不能拿它
        final image = await WatermarkRenderer.renderPhotoImage(
          hasPath ? Uint8List(0) : await widget.photo.readAsBytes(),
          _settings,
          grade: _grade,
          mosaics: _mosaics,
          extraMarks: _extraWms,
          canvasAspect: _canvasAspect,
          sourcePath: hasPath ? path : null,
        );
        // 編碼＋存檔跟批次同一條路（原生 ImageIO 直出 → BMP 快路 →
        // Skia PNG，見 photo_export.dart）：不再「先出 PNG 再重壓 JPEG」
        final String ext;
        try {
          (message, ext) = await savePhotoImage(
            image,
            jpeg: jpeg,
            quality: 92,
            name: name,
            // 來源的 EXIF／TIFF 搬進成品（HDR 路本來就這樣做）
            sourcePath: hasPath ? path : null,
          );
        } finally {
          image.dispose();
        }
        // 這些是次要說明，不要接在主訊息後面變成一長串括號
        final notes = [
          if (jpeg && ext == 'png') '這個裝置不支援 JPEG，已改存 PNG',
          if (hdrSrc && hdrBlocked) '這張是 HDR 照片，有馬賽克或調色時會以 SDR 輸出',
        ];
        if (notes.isNotEmpty) note = notes.join('；');
      }
    } catch (e) {
      message = '匯出失敗：$e';
      ok = false;
    }
    if (ok) {
      // 已經輸出過就不用留草稿了
      unawaited(clearPhotoDraft());
      // 輸出成功＝把「有沒有改過」的基準點重設到現在。
      // 不能一輸出就永遠關掉保護：之後又改了十分鐘、
      // 誤觸返回會一聲不吭直接蒸發
      _initialJson = _stateJson;
    }

    if (!mounted) return;
    // 只有進度框還開著才 pop，不然會把編輯頁本身關掉。
    // rootNavigator：showDialog 開在 root，pop 也要對同一個 navigator
    if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    setState(() => _exporting = false);
    if (!ok) {
      showHint(context, message, error: true);
      return;
    }
    // 成功：問要回主畫面還是留下來繼續改
    final act = await askAfterExport(context, message, note: note);
    // _initialJson 上面已經對齊現況，離開不會再問「要放棄嗎」
    if (act == 'home' && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// 點畫面上的浮水印時，叫下面的面板捲到對應的設定區塊
  final _wmPanelCtrl = WatermarkPanelController();

  /// 輸出後要問「存成範本」時，得叫得動面板裡的儲存流程
  final _panelKey = GlobalKey<WatermarkPanelState>();

  /// 預覽上每個可點的東西畫在哪。
  /// 用 Map 不用 List：疊放順序在 _phOrder 裡是固定的（馬賽克在最下、
  /// 再來主浮水印、額外浮水印在最上），不必依賴收集的先後，
  /// 這樣就不怕「清空了但某層那一幀沒重新回報」
  final Map<_PhLayer, Rect> _phBox = {};

  /// 上一次點預覽的位置：同一點再點一次就往下鑽一層
  Offset? _phCycleAt;

  /// 「還有下一層」的提示最多講幾次
  int _phCycleHintLeft = 2;

  /// 由上往下的疊放順序（只列出這一刻真的畫得出來的）
  List<_PhLayer> _phOrder() {
    final out = <_PhLayer>[];
    void add(_PhLayer id) {
      if (_phBox.containsKey(id)) out.add(id);
    }

    // 一組浮水印內部：文字畫在圖片之後＝文字在上；
    // 圖片之間則是後加的那張在上
    void addGroup(int kind, int index, WatermarkSettings s) {
      for (var i = s.texts.length - 1; i >= 0; i--) {
        add((kind: kind, index: index, part: WmPart.text, logo: i));
      }
      for (var i = s.logos.length - 1; i >= 0; i--) {
        add((kind: kind, index: index, part: WmPart.logo, logo: i));
      }
    }

    // 額外浮水印疊在最上面，後加的又在更上面
    for (var i = _extraWms.length - 1; i >= 0; i--) {
      addGroup(2, i, _extraWms[i]);
    }
    addGroup(1, -1, _settings);
    for (var i = _mosaics.length - 1; i >= 0; i--) {
      add((kind: 0, index: i, part: WmPart.none, logo: -1));
    }
    return out;
  }

  /// 目前選中的是哪一層
  _PhLayer? _phCurrent() {
    if (_selMosaic >= 0) {
      return (kind: 0, index: _selMosaic, part: WmPart.none, logo: -1);
    }
    if (_selExtra >= 0) {
      final s = _extraWms[_selExtra];
      return (
        kind: 2,
        index: _selExtra,
        part: _selExtraPart,
        logo: _selExtraPart == WmPart.logo
            ? s.activeLogo
            : (_selExtraPart == WmPart.text ? s.activeText : -1),
      );
    }
    if (_wmPart != WmPart.none) {
      return (
        kind: 1,
        index: -1,
        part: _wmPart,
        logo: _wmPart == WmPart.logo
            ? _settings.activeLogo
            : (_wmPart == WmPart.text ? _settings.activeText : -1),
      );
    }
    return null;
  }

  /// 這一層轉了幾度（馬賽克不轉）
  double _phRotation(_PhLayer id) {
    if (id.kind == 0) return 0;
    final s = id.kind == 1
        ? _settings
        : (id.index >= 0 && id.index < _extraWms.length
              ? _extraWms[id.index]
              : null);
    if (s == null || id.logo < 0) return 0;
    return switch (id.part) {
      WmPart.text when id.logo < s.texts.length => s.texts[id.logo].rotation,
      WmPart.logo when id.logo < s.logos.length => s.logos[id.logo].rotation,
      _ => 0,
    };
  }

  /// 點 [p] 有沒有落在這一層上。圖層回報的是「未旋轉的外框」（旋轉在
  /// Positioned 裡面做），轉過的部件要把點以框中心反轉回去再比——
  /// 以前直接拿外框比：轉 45 度的長文字，點在字上選不到、點在旁邊的
  /// 空白反而選到
  bool _phHit(_PhLayer id, Offset p) {
    final r = _phBox[id];
    if (r == null) return false;
    final deg = _phRotation(id);
    if (deg.abs() <= 0.01) return r.contains(p);
    final c = r.center;
    final a = -deg * math.pi / 180;
    final dx = p.dx - c.dx, dy = p.dy - c.dy;
    return r.contains(
      Offset(
        c.dx + dx * math.cos(a) - dy * math.sin(a),
        c.dy + dx * math.sin(a) + dy * math.cos(a),
      ),
    );
  }

  /// 點預覽區：選這個點上最上面的東西。
  /// 同一點連續點擊往下鑽一層——完全被蓋住的圖層本來永遠選不到
  void _phTapAt(Offset p) {
    FocusManager.instance.primaryFocus?.unfocus();
    // 兩指捏完放開的那一下不是「點」：捏臉調大小，不該順便把它切成不碼
    if (_pinchHappened) return;
    final hits = [
      for (final id in _phOrder())
        if (_phHit(id, p)) id,
    ];
    // 馬賽克模式點到一塊：臉＝切換碼／不碼；其他＝亮一下。都不走選取
    //（照片上不畫框，選了也看不出來；拖曳、兩指捏直接作用在手指底下那塊）
    if (_mosaicMode && hits.isNotEmpty) {
      final top = hits.first;
      if (top.kind == 0 && top.index < _mosaics.length) {
        _phCycleAt = null;
        if (_mosaics[top.index].face) {
          _toggleFace(top.index);
        } else {
          _flash({top.index});
        }
        return;
      }
    }
    if (hits.isEmpty) {
      _phCycleAt = null;
      if (_wmPart != WmPart.none || _selMosaic != -1 || _selExtra != -1) {
        setState(() {
          _wmPart = WmPart.none;
          _selMosaic = -1;
          _selExtra = -1;
        });
      }
      return;
    }
    // 手指不可能點在同一個像素上，給 24px 的容忍
    final same = _phCycleAt != null && (_phCycleAt! - p).distance <= 24;
    final cur = _phCurrent();
    var next = hits.first;
    if (same && cur != null) {
      final at = hits.indexOf(cur);
      if (at >= 0) next = hits[(at + 1) % hits.length];
    }
    _phCycleAt = p;
    // 這裡只有一層而且已經選著它＝再點一次要進編輯（維持原本的手感）
    if (same && next == cur) {
      if (next.kind == 0) _editMosaic(next.index);
      if (next.kind == 2) _editExtraWm(next.index);
      return;
    }
    setState(() {
      _selMosaic = next.kind == 0 ? next.index : -1;
      _selExtra = next.kind == 2 ? next.index : -1;
      if (next.kind == 2) _selExtraPart = next.part;
      _wmPart = next.kind == 1 ? next.part : WmPart.none;
      // 點到哪一個，那個就變成操作中的（面板、捏合都跟著它）
      if (next.logo >= 0) {
        final s = next.kind == 1
            ? _settings
            : (next.kind == 2 ? _extraWms[next.index] : null);
        if (s != null) {
          if (next.part == WmPart.logo) s.activeLogo = next.logo;
          if (next.part == WmPart.text) s.activeText = next.logo;
        }
      }
    });
    if (next.kind == 1) _wmPanelCtrl.scrollTo(next.part);
    // 額外浮水印的設定在彈出視窗裡，選到就開；但循環途中不開，
    // 不然視窗一蓋上來就沒辦法再點下一層
    if (next.kind == 2 && !same) _editExtraWm(next.index);
    if (!same && hits.length > 1 && _phCycleHintLeft > 0) {
      _phCycleHintLeft--;
      showHint(context, overlapHint(hits.length));
    }
  }

  /// 長按照片上的一塊（馬賽克模式）：跟長按縮圖一樣，壓暗＋刪除小選單
  void _phLongPressAt(Offset p) {
    if (_brushMode || _pinchHappened) return;
    for (final id in _phOrder()) {
      if (id.kind != 0 || id.index >= _mosaics.length || !_phHit(id, p)) {
        continue;
      }
      final r = _phBox[id];
      final box = _canvasKey.currentContext?.findRenderObject();
      if (r == null || box is! RenderBox || !box.attached) return;
      unawaited(
        _askDeleteMosaic(
          id.index,
          rect: Rect.fromPoints(
            box.localToGlobal(r.topLeft),
            box.localToGlobal(r.bottomRight),
          ),
        ),
      );
      return;
    }
  }

  /// 這幾個螢幕座標（依序試）落在哪一塊馬賽克上（最上面那塊）；都沒有回 -1
  int _mosaicUnder(List<Offset> globals) {
    final box = _canvasKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return -1;
    final order = _phOrder();
    for (final g in globals) {
      final p = box.globalToLocal(g);
      for (final id in order) {
        if (id.kind == 0 && id.index < _mosaics.length && _phHit(id, p)) {
          return id.index;
        }
      }
    }
    return -1;
  }

  // ===== 置中吸附（路由拖曳／馬賽克拖曳共用，跟 WatermarkLayer 同手感）=====
  /// 未吸附的原始座標（吸附只作用在顯示值上，不然吸上就拖不出來）
  double? _phRawX, _phRawY;
  bool _phGuideV = false, _phGuideH = false;
  bool _phSnapped = false;

  /// 這一手已經看過第一格了：第一格只記「起手時黏不黏」、不震——
  /// 本來就坐在中線上的東西，起手那一下不算「吸上去」
  bool _phSnapKnown = false;

  double _snapC(double v) => (v - 0.5).abs() < 0.015 ? 0.5 : v;

  void _phSetGuides(double x, double y) {
    final v = x == 0.5, hh = y == 0.5;
    if (v != _phGuideV || hh != _phGuideH) {
      setState(() {
        _phGuideV = v;
        _phGuideH = hh;
      });
    }
    final on = v || hh;
    if (!_phSnapKnown) {
      _phSnapKnown = true;
      _phSnapped = on;
    } else if (on != _phSnapped) {
      _phSnapped = on;
      if (on) HapticFeedback.selectionClick();
    }
  }

  void _phClearGuides() {
    _phRawX = null;
    _phRawY = null;
    _phSnapped = false;
    _phSnapKnown = false;
    if (_phGuideV || _phGuideH) {
      setState(() {
        _phGuideV = false;
        _phGuideH = false;
      });
    }
  }

  // ===== 預覽區雙指縮放（照片上的浮水印／選中的馬賽克）=====
  // ===== 全螢幕檢視（放大看照片；跟影片編輯的全螢幕同一套語言）=====
  /// 開著＝照片鋪滿整頁、黑底，可捏合放大細看；編輯手勢全關。
  /// 右上角膠囊或下滑離開
  bool _fsView = false;

  /// 全螢幕塗抹時，筆刷工具列有沒有叫出來（浮在畫面下緣）
  bool _fsBrushOpen = true;

  /// 全螢幕版的筆刷工具列：跟下面那張面板同一組值
  ///（_brushStyle/_brushSize，改了一樣即時套到剛畫的那一筆），
  /// 只是排得緊湊、浮在畫面上——放大看著細節就能直接微調
  Widget _fsBrushTools() {
    Widget chip(String label, int type) {
      final on = _brushStyle.type == type;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: () => setState(() {
              // 柔邊各模式各記各的（同 _brushPanel）
              _brushFeatherByType[_brushStyle.type] = _brushStyle.feather;
              _brushStyle.type = type;
              _brushStyle.feather = _brushFeatherByType[type] ?? 0.0;
              _brushSel?.style.type = type;
              _brushSel?.style.feather = _brushStyle.feather;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: on ? kAmber : Colors.white.withValues(alpha: 0.25),
                  width: on ? 1.4 : 1,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Colors.white,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget slider(
      String label,
      double value,
      double lo,
      double hi,
      ValueChanged<double> onChanged,
    ) => SizedBox(
      height: 30,
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(lo, hi),
              min: lo,
              max: hi,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 往下滑＝收起工具列（把手就是抓的地方）
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 200) {
          setState(() => _fsBrushOpen = false);
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 5, 12, 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 收合把手：點或下滑都收起
            GestureDetector(
              onTap: () => setState(() => _fsBrushOpen = false),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 40,
                height: 14,
                alignment: Alignment.center,
                child: Container(
                  width: 32,
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                chip('像素化', 0),
                chip('模糊', 1),
                chip('純色', 2),
                const SizedBox(width: 6),
                // 上一步／下一步：塗錯一筆馬上收回（跟影片版同款
                // 分段膠囊：合成一顆、中間細分隔線，38px 高好按）
                Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(999),
                        ),
                        onTap: _undoStack.isEmpty ? null : _undoLast,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          child: Icon(
                            Icons.undo,
                            size: 20,
                            color: _undoStack.isEmpty
                                ? Colors.white24
                                : kSelect,
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 18,
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                      InkWell(
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(999),
                        ),
                        onTap: _redoStack.isEmpty ? null : _redoLast,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          child: Icon(
                            Icons.redo,
                            size: 20,
                            color: _redoStack.isEmpty
                                ? Colors.white24
                                : kSelect,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setState(() {
                    _brushMode = false;
                    _fsView = false;
                  }),
                  // 跟膠囊等高（38px），並排才不會矮一截
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kSelect,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            slider('粗細', _brushSize, 0.03, 0.5, (v) {
              setState(() {
                _brushSize = v;
                _brushSel?.brush = v;
              });
            }),
            if (_brushStyle.type != 2)
              slider('濃度', _brushStyle.strength, 0.0, 1.0, (v) {
                setState(() {
                  _brushStyle.strength = v;
                  _brushSel?.style.strength = v;
                });
              }),
            // 柔邊：像素化沒有（硬邊格子才是重點），模糊與純色各記各的
            if (_brushStyle.type != 0)
              slider('柔邊', _brushStyle.feather, 0.0, 1.0, (v) {
                setState(() {
                  _brushStyle.feather = v;
                  _brushSel?.style.feather = v;
                });
              }),
            if (_brushStyle.type == 2)
              SizedBox(
                height: 30,
                child: Row(
                  children: [
                    const Text(
                      '顏色',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                    const Spacer(),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        final picked = await pickColor(
                          context,
                          Color(_brushStyle.color),
                        );
                        if (picked != null) {
                          setState(() {
                            _brushStyle.color = picked;
                            _brushSel?.style.color = picked;
                          });
                        }
                      },
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Color(_brushStyle.color),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 全螢幕檢視：跟編輯畫面看到的完全一樣（調色、馬賽克、浮水印
  /// 全都畫），只是唯讀＋可捏合縮放
  Widget _fsPhotoView() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    // 下滑＝離開（跟影片編輯的全螢幕同手勢）。
    // 筆刷塗抹中不收：直直往下畫一筆會被當成要離開
    onVerticalDragEnd: _brushMode
        ? null
        : (d) {
            if ((d.primaryVelocity ?? 0) > 250) {
              setState(() => _fsView = false);
            }
          },
    child: Container(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            // 全螢幕一律不縮放也不平移（使用者指定）：就是把成品
            // 鋪滿螢幕看，手勢全部留給筆刷
            child: Center(
              child: AspectRatio(
                aspectRatio: _canvasAspectEff,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 塗抹中每一筆只重建這一層（_liveRepaint）
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: ValueListenableBuilder<int>(
                          valueListenable: _liveTick,
                          builder: (context, _, _) => Stack(
                            fit: StackFit.expand,
                            children: [
                              const Positioned.fill(
                                child: ColoredBox(color: Colors.black),
                              ),
                              _photoWidget(_grade.hasColor),
                              if (_mosaics.isNotEmpty)
                                Positioned.fill(
                                  child: LayoutBuilder(
                                    builder: (context, box) => _buildMosaics(
                                      box.maxWidth,
                                      box.maxHeight,
                                    ),
                                  ),
                                ),
                              WatermarkLayer(
                                settings: _settings,
                                onChanged: () {},
                              ),
                              for (final e in _extraWms)
                                WatermarkLayer(settings: e, onChanged: () {}),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 筆刷模式：放大後照樣塗抹（座標在 IV 的子座標系
                    // 裡，命中測試自動反算縮放平移，不用自己換算）
                    if (_brushMode)
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final w = box.maxWidth;
                            final h = box.maxHeight;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (d) =>
                                  _brushStart(d.localPosition, w, h),
                              onPanUpdate: (d) =>
                                  _brushMove(d.localPosition, w, h),
                              child: const SizedBox.expand(),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // 底部：收起時是一句提示，叫出來就是完整的筆刷工具列
          //（放大看著細節直接微調，不用退出全螢幕）
          if (_brushMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _fsBrushOpen
                    ? _fsBrushTools()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Center(
                          child: IgnorePointer(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Text(
                                '在照片上塗抹要打碼的地方',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          // 右上角：筆刷工具列開關（塗抹中才有）＋離開全螢幕
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_brushMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () =>
                              setState(() => _fsBrushOpen = !_fsBrushOpen),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: _fsBrushOpen
                                  ? kAmber
                                  : Colors.black.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.tune,
                              size: 22,
                              color: _fsBrushOpen
                                  ? const Color(0xFF1A1A1A)
                                  : kText,
                            ),
                          ),
                        ),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => setState(() => _fsView = false),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.fullscreen_exit,
                          size: 22,
                          color: kText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  final Map<int, Offset> _pvPts = {};

  /// 每根指標最後出現的時間：殘指自癒用（見 _pinchDown）
  final Map<int, DateTime> _pvSeen = {};
  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;
  double _pvBaseMosaic = 0.35;
  double _pvBaseExtraText = 0.12;
  double _pvBaseExtraLogo = 0.18;

  // 兩指旋轉（跟影片編輯器同一套手感：轉多少是多少、15 度吸附）
  double _pvBaseAngle = 0;
  double _pvBaseRotText = 0;
  double _pvBaseRotLogo = 0;
  double _pvBaseRotExtraText = 0;
  double _pvBaseRotExtraLogo = 0;

  /// 兩指旋轉的 15 度吸附（門檻／遲滯／只在換刻度時震，見 RotationSnap）。
  /// 以領頭（文字，沒文字就圖片）算一次，同一個修正量套給會轉的部件
  final _rotSnap = RotationSnap();

  /// 這次捏合旋轉的領頭底角（跟 _pinchMove 挑目標的規則一致）
  double _pinchRotBase() {
    if (_selExtra >= 0 && _selExtra < _extraWms.length) {
      final e = _extraWms[_selExtra];
      final part = _extraPartAlive(_selExtra);
      final hasText = e.text.enabled && e.text.text.trim().isNotEmpty;
      final hasLogo = e.logo.enabled;
      final doText = hasText && (part != WmPart.logo || !hasLogo);
      return doText ? _pvBaseRotExtraText : _pvBaseRotExtraLogo;
    }
    final t = _settings.text;
    final hasText = t.enabled && t.text.trim().isNotEmpty;
    final hasLogo = _settings.logo.enabled;
    final part = _wmPartAlive;
    final doText = hasText && (part != WmPart.logo || !hasLogo);
    return doText ? _pvBaseRotText : _pvBaseRotLogo;
  }

  static double _wrapDeg(double v) {
    var x = v;
    while (x > 180) {
      x -= 360;
    }
    while (x < -180) {
      x += 360;
    }
    return x;
  }

  void _pinchDown(PointerDownEvent e) {
    // 只有觸控算捏合（跟影片端時間軸同一套防護）：滑鼠／觸控筆
    // 不可能兩指，而 web 上滑鼠在視窗外放開時 pointer-up 常整顆
    // 遺失——幽靈殘指跟下一次按下湊成「兩指」，panLocked 一開，
    // 浮水印與馬賽克從此拖不動
    if (e.kind != ui.PointerDeviceKind.touch) return;
    final now = DateTime.now();
    _pvPts.removeWhere((id, _) {
      final seen = _pvSeen[id];
      // 3 秒沒動靜＝殘指清掉。真的要捏合，第二指 1 秒內就會下來
      final stale = seen == null || now.difference(seen).inSeconds > 3;
      if (stale) _pvSeen.remove(id);
      return stale;
    });
    // 新的一手（之前沒有手指在上面）：上一手捏過的記號清掉
    if (_pvPts.isEmpty) _pinchHappened = false;
    _pvSeen[e.pointer] = now;
    _pvPts[e.pointer] = e.position;
    if (_pvPts.length != 2) return;
    final p = _pvPts.values.toList();
    final d = (p[0] - p[1]).distance;
    if (d <= 20) return;
    _pvBaseDist = d;
    _pinchHappened = true;
    _pvBaseAngle = math.atan2(p[1].dy - p[0].dy, p[1].dx - p[0].dx);
    _pvBaseText = _settings.text.sizeFrac;
    _pvBaseLogo = _settings.logo.sizeFrac;
    _pvBaseRotText = _settings.text.rotation;
    _pvBaseRotLogo = _settings.logo.rotation;
    if (_mosaicMode) {
      // 捏的是兩指中間（不在任何一塊上就看兩根手指各自底下）那一塊
      _pinchMosaic = _mosaicUnder([(p[0] + p[1]) / 2, p[0], p[1]]);
      if (_pinchMosaic >= 0) {
        final m = _mosaics[_pinchMosaic];
        _pvBaseMosaic = m.isStroke ? m.brush : m.scale;
      }
    } else if (_selMosaic >= 0 && _selMosaic < _mosaics.length) {
      _pvBaseMosaic = _mosaics[_selMosaic].scale;
    }
    if (_selExtra >= 0 && _selExtra < _extraWms.length) {
      _pvBaseExtraText = _extraWms[_selExtra].text.sizeFrac;
      _pvBaseExtraLogo = _extraWms[_selExtra].logo.sizeFrac;
      _pvBaseRotExtraText = _extraWms[_selExtra].text.rotation;
      _pvBaseRotExtraLogo = _extraWms[_selExtra].logo.rotation;
    }
    _rotSnap.arm(_pinchRotBase());
    _phUndoPending = true;
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvSeen[e.pointer] = DateTime.now();
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    // 兩指轉多少就轉多少（跟影片編輯器同一套）。手指幾乎沒轉時
    // 不動它——單純想縮放的人不該被順手轉歪
    final ang = math.atan2(p[1].dy - p[0].dy, p[1].dx - p[0].dx);
    final dDeg = _wrapDeg((ang - _pvBaseAngle) * 180 / math.pi);
    // 門檻／遲滯／震動的規則全在 RotationSnap；吸附以領頭算一次，同一個
    // 修正量套給每個目標。馬賽克不轉，所以延到真的要轉才算
    double? dRot;
    double rot(double base) => _wrapDeg(base + (dRot ??= _rotSnap.delta(dDeg)));
    // 馬賽克模式捏在空白處：沒有東西可縮（也沒有浮水印），不拍空的一步
    if (_mosaicMode && _pinchMosaic < 0) return;
    _phPushUndoIfNeeded(); // 真的縮到東西了才拍
    _pinchApply(f, rot);
    // 每一格只重畫預覽；放手（_pinchUp）才整頁 setState 對回面板讀數
    _liveRepaint();
  }

  /// 把捏合的縮放倍率 [f] 與旋轉 [rot] 套到目前的目標上
  void _pinchApply(double f, double Function(double base) rot) {
    // 馬賽克模式：捏哪塊動哪塊（起手時手指底下那塊，臉也可以）；
    // 筆畫縮放的是粗細（跟大小滑桿同一個意思）
    if (_mosaicMode) {
      final i = _pinchMosaic;
      if (i >= 0 && i < _mosaics.length) {
        final m = _mosaics[i];
        if (m.isStroke) {
          m.brush = (_pvBaseMosaic * f).clamp(0.02, 0.6);
        } else {
          m.scale = (_pvBaseMosaic * f).clamp(0.02, 3.0);
        }
      }
      return;
    }
    // 有選中馬賽克：雙指縮它，不動浮水印（打碼區域不支援旋轉）
    if (_selMosaic >= 0 && _selMosaic < _mosaics.length) {
      // 上限跟樣式表滑桿一致（3.0）：以前夾 1.5，用滑桿放大到
      // 200% 的馬賽克一做捏合就瞬間跳縮回 150%
      _mosaics[_selMosaic].scale = (_pvBaseMosaic * f).clamp(0.05, 3.0);
      return;
    }
    // 有選中額外那幾組浮水印：縮的是那一組，不是主浮水印
    if (_selExtra >= 0 && _selExtra < _extraWms.length) {
      final e = _extraWms[_selExtra];
      final part = _extraPartAlive(_selExtra);
      final hasText = e.text.enabled && e.text.text.trim().isNotEmpty;
      final hasLogo = e.logo.enabled;
      if (hasText && (part != WmPart.logo || !hasLogo)) {
        e.text.sizeFrac = (_pvBaseExtraText * f).clamp(0.015, 2.0);
        e.text.rotation = rot(_pvBaseRotExtraText);
      }
      if (hasLogo && (part != WmPart.text || !hasText)) {
        e.logo.sizeFrac = (_pvBaseExtraLogo * f).clamp(0.03, 2.0);
        e.logo.rotation = rot(_pvBaseRotExtraLogo);
      }
      return;
    }
    final t = _settings.text;
    final hasText = t.enabled && t.text.trim().isNotEmpty;
    final hasLogo = _settings.logo.enabled;
    // 有選取就只動被選的那個（畫面上有白框）；
    // 都沒選而兩個都在，才一起動（用活性版，殘留選取不算）
    final part = _wmPartAlive;
    final doText = hasText && (part != WmPart.logo || !hasLogo);
    final doLogo = hasLogo && (part != WmPart.text || !hasText);
    if (doText) {
      t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
      t.rotation = rot(_pvBaseRotText);
    }
    if (doLogo) {
      _settings.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
      _settings.logo.rotation = rot(_pvBaseRotLogo);
    }
  }

  void _pinchUp(int pointer) {
    _pvPts.remove(pointer);
    _pvSeen.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) {
      _pvBaseDist = null;
      _rotSnap.end();
      // 捏合結束：整頁補一次，面板的大小／旋轉讀數才對回來
      _liveEnd();
    }
  }

  /// 照片本人：直接畫解好的那一份（RawImage），不走 Image.memory——
  /// 那會在框架的圖片快取裡再解一份全尺寸（見 _decodeForPreview）。
  /// 自己一層 RepaintBoundary：拖浮水印、拉馬賽克時照片不必跟著重畫
  Widget _photoWidget(bool graded) {
    final img = RawImage(
      image: _photoImg,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
    return RepaintBoundary(
      child: graded
          ? ColorFiltered(
              colorFilter: ColorFilter.matrix(_grade.matrix),
              child: img,
            )
          : img,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        // 全螢幕檢視：整頁只有照片，連標題列都收掉
        appBar: _fsView ? null : AppBar(),
        body: _photoImg == null || _aspect == null
            ? const Center(child: CircularProgressIndicator())
            : _fsView
            ? _fsPhotoView()
            : Column(
                children: [
                  // 上 4 下 6：面板是主要工作區，太窄的話每次調整都在
                  // 捲動；照片有全螢幕預覽可以看，這裡讓一點沒關係。
                  // 馬賽克模式反過來：主角是照片上的臉——下半部固定剛好
                  // 放得下（見 _mzPanelHeight），其餘全給照片
                  Expanded(
                    flex: 4,
                    // 雙指縮放浮水印（用 Listener 不搶單指拖曳手勢）
                    child: Listener(
                      onPointerDown: _pinchDown,
                      onPointerMove: _pinchMove,
                      onPointerUp: (e) => _pinchUp(e.pointer),
                      onPointerCancel: (e) => _pinchUp(e.pointer),
                      child: GestureDetector(
                        // 點空白＝收鍵盤＋取消部件選取
                        //（不取消的話另一個部件會永遠拖不動）
                        onTap: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          if (_wmPart != WmPart.none ||
                              _selMosaic != -1 ||
                              _selExtra != -1) {
                            setState(() {
                              _wmPart = WmPart.none;
                              _selMosaic = -1;
                              _selExtra = -1;
                            });
                          }
                        },
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Container(
                                // 跟影片／批次／工作室同一個底色。原本是純黑，
                                // 直式照片兩側留邊會比其他畫面暗一階
                                color: kPreviewBg,
                                alignment: Alignment.center,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    AspectRatio(
                                      aspectRatio: _canvasAspectEff,
                                      // 整個預覽自己一層：面板重畫不波及
                                      // 預覽、預覽重畫也不波及面板。
                                      // 拖曳／捏合／滑桿的每一格只重建這裡
                                      //（_liveRepaint），不整頁 setState
                                      child: RepaintBoundary(
                                        key: _canvasKey,
                                        child: ValueListenableBuilder<int>(
                                          valueListenable: _liveTick,
                                          builder: (context, _, _) => Stack(
                                            fit: StackFit.expand,
                                            // 不裁切：浮水印選取框要能畫到照片外
                                            //（內容由 WatermarkLayer 自己的 Stack 裁）
                                            clipBehavior: Clip.none,
                                            children: [
                                              // 畫布底：換比例後照片置中、
                                              // 留邊補黑（跟匯出一致）
                                              const Positioned.fill(
                                                child: ColoredBox(
                                                  color: Colors.black,
                                                ),
                                              ),
                                              // 調色即時反映在預覽上
                                              _photoWidget(
                                                _grade.hasColor &&
                                                    !_colorCompare,
                                              ),
                                              // 馬賽克層：畫在照片上、浮水印下。
                                              // 自己一層：拖浮水印時像素化補丁
                                              //（一塊上千次 drawImageRect）不重畫
                                              if (_mosaics.isNotEmpty)
                                                Positioned.fill(
                                                  child: RepaintBoundary(
                                                    child: LayoutBuilder(
                                                      builder: (context, box) =>
                                                          _buildMosaics(
                                                            box.maxWidth,
                                                            box.maxHeight,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              WatermarkLayer(
                                                settings: _settings,
                                                onChanged: () =>
                                                    setState(() {}),
                                                // 拖曳中每一格只重畫預覽層，
                                                // 放手補整頁（見 _liveTick）
                                                onLiveChange: _liveRepaint,
                                                onDragEnd: _liveEnd,
                                                onDragStart: _pushUndo,
                                                // 選取框畫在裁切外（見 _wmFrameInfo）
                                                frameNotifier: _wmFrameInfo,
                                                onHitBox: (t, l) =>
                                                    _phSetBox(1, -1, t, l),
                                                // 活性版：被選部件消失後視同沒選，
                                                // 拖曳才不會整個變死的
                                                selectedPart: _wmPartAlive,
                                                // 選浮水印部件＝取消馬賽克選取，
                                                // 同時只會有一種東西被選（單一選取）
                                                onSelectPart: (p) {
                                                  setState(() {
                                                    _wmPart = p;
                                                    _selMosaic = -1;
                                                    _selExtra = -1;
                                                  });
                                                  // 點文字就把面板捲到文字設定
                                                  //（點圖片同理），不用自己找
                                                  _wmPanelCtrl.scrollTo(p);
                                                },
                                                panLocked: () =>
                                                    _pvPts.length >= 2,
                                                // 別的東西被選取時完全不吃拖曳，讓給下面的
                                                // 選取路由——不然選了馬賽克在畫面上拖，
                                                // 手指剛好經過浮水印就會把浮水印拖走
                                                panAllowed: (_) =>
                                                    _selMosaic == -1 &&
                                                    _selExtra == -1,
                                              ),
                                              // 更多浮水印：一組一層疊上去，各自拖曳；
                                              // 點一下＝選取（白框）＋直接開編輯面板
                                              for (
                                                var i = 0;
                                                i < _extraWms.length;
                                                i++
                                              )
                                                WatermarkLayer(
                                                  settings: _extraWms[i],
                                                  onChanged: () =>
                                                      setState(() {}),
                                                  onLiveChange: _liveRepaint,
                                                  onDragEnd: _liveEnd,
                                                  onDragStart: _pushUndo,
                                                  onHitBox: (t, l) =>
                                                      _phSetBox(2, i, t, l),
                                                  selectedPart: _extraPartAlive(
                                                    i,
                                                  ),
                                                  onSelectPart: (p) {
                                                    setState(() {
                                                      _selExtra = i;
                                                      _selExtraPart = p;
                                                      _wmPart = WmPart.none;
                                                      _selMosaic = -1;
                                                    });
                                                    _editExtraWm(i);
                                                  },
                                                  panLocked: () =>
                                                      _pvPts.length >= 2,
                                                  // 同上：馬賽克選取中誰都不准拖；
                                                  // 選了別組浮水印時這一組也不吃
                                                  panAllowed: (_) =>
                                                      _selMosaic == -1 &&
                                                      (_selExtra == -1 ||
                                                          _selExtra == i),
                                                ),
                                              // 點擊判定層：疊在所有圖層之上，統一決定
                                              // 點到誰。translucent＝只搶點擊，
                                              // 拖曳照樣傳給下面的圖層與選取路由
                                              Positioned.fill(
                                                child: LayoutBuilder(
                                                  builder: (context, box) =>
                                                      GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .translucent,
                                                        onTapUp: (d) =>
                                                            _phTapAt(
                                                              d.localPosition,
                                                            ),
                                                        // 馬賽克模式：長按一塊＝
                                                        // 壓暗＋刪除小選單
                                                        onLongPressStart:
                                                            _mosaicMode
                                                            ? (
                                                                d,
                                                              ) => _phLongPressAt(
                                                                d.localPosition,
                                                              )
                                                            : null,
                                                        child:
                                                            const SizedBox.expand(),
                                                      ),
                                                ),
                                              ),
                                              // 置中輔助線（路由/馬賽克拖曳吸中線時）。
                                              // 一定要「永遠佔一個位置」，不能用 if 增減：
                                              // 線一出現就會把後面圖層的索引往後推，
                                              // Flutter 因此重建下面那個手勢層＝拖曳被中斷，
                                              // 下一輪又從已吸附的中線值重新開始，
                                              // 結果就是吸上中線後再也拖不出來
                                              Positioned.fill(
                                                child: CenterGuides(
                                                  vertical: _phGuideV,
                                                  horizontal: _phGuideH,
                                                ),
                                              ),
                                              // 浮水印選取框：畫在真實位置（部件拖出
                                              // 照片時內容被裁、框照畫）
                                              Positioned.fill(
                                                child: WmFrameOverlay(
                                                  _wmFrameInfo,
                                                ),
                                              ),
                                              // 選取路由：有部件被選取（琥珀框）時，
                                              // 整個預覽的拖曳都只動被選的那個——
                                              // 主浮水印跟每一組額外浮水印各自一條
                                              //（見 _routeLayer）
                                              if (_wmPartAlive != WmPart.none)
                                                _routeLayer(
                                                  const ValueKey('wm-route'),
                                                  _settings,
                                                  _wmPartAlive,
                                                ),
                                              if (_selExtra >= 0 &&
                                                  _selExtra <
                                                      _extraWms.length &&
                                                  _extraPartAlive(_selExtra) !=
                                                      WmPart.none)
                                                _routeLayer(
                                                  const ValueKey('extra-route'),
                                                  _extraWms[_selExtra],
                                                  _extraPartAlive(_selExtra),
                                                ),
                                              // 選取路由（馬賽克版）：馬賽克被選取時，
                                              // 整個預覽的拖曳都只動它——跟上面浮水印
                                              // 部件那條路由同一套規則。
                                              //
                                              // 沒有這一層馬賽克就拖不動（測試者回報）：
                                              // 方塊自己的手勢在文字／圖片圖層「底下」，
                                              // 那些圖層是 opaque，馬賽克選取中它們
                                              // 雖然不註冊拖曳（panAllowed），命中測試
                                              // 照樣停在它們身上，指標到不了方塊；
                                              // 而新加的一塊跟預設文字都在正中央，
                                              // 手指一落下就是這種情況。
                                              // 筆刷模式不掛：塗抹層在最上面整面接管，
                                              // 而且每畫一筆 _selMosaic 就換一次，這層
                                              // 跟著增減會把塗抹層的索引往後推、手勢
                                              // 被重建（同上面輔助線那個坑）。
                                              // 馬賽克模式不掛：那裡沒有浮水印擋在
                                              // 上面，也不留選取（見 _mosaicDragStart）
                                              if (_selMosaic >= 0 &&
                                                  _selMosaic <
                                                      _mosaics.length &&
                                                  !_brushMode &&
                                                  !_mosaicMode)
                                                Positioned.fill(
                                                  key: const ValueKey(
                                                    'mosaic-route',
                                                  ),
                                                  child: LayoutBuilder(
                                                    builder: (context, box) {
                                                      final w = box.maxWidth;
                                                      final h = box.maxHeight;
                                                      final m =
                                                          _mosaics[_selMosaic];
                                                      return GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .translucent,
                                                        onPanStart: (_) =>
                                                            _mosaicDragStart(
                                                              _selMosaic,
                                                            ),
                                                        onPanUpdate: (d) =>
                                                            _mosaicDragUpdate(
                                                              m,
                                                              d,
                                                              w,
                                                              h,
                                                            ),
                                                        onPanEnd: (_) =>
                                                            _mosaicDragEnd(),
                                                        onPanCancel:
                                                            _mosaicDragEnd,
                                                        child:
                                                            const SizedBox.expand(),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              // 筆刷模式：整面接管拖曳，塗到哪碼到哪
                                              //（疊最上層，其他選取/拖曳全讓路）
                                              if (_brushMode)
                                                Positioned.fill(
                                                  child: LayoutBuilder(
                                                    builder: (context, box) {
                                                      final w = box.maxWidth;
                                                      final h = box.maxHeight;
                                                      return GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        onPanStart: (d) =>
                                                            _brushStart(
                                                              d.localPosition,
                                                              w,
                                                              h,
                                                            ),
                                                        onPanUpdate: (d) =>
                                                            _brushMove(
                                                              d.localPosition,
                                                              w,
                                                              h,
                                                            ),
                                                        child:
                                                            const SizedBox.expand(),
                                                      );
                                                    },
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // 全螢幕檢視的入口：貼在「預覽區」的右上角
                            //（跟影片編輯的膠囊同一個位置與長相——
                            // 放在照片自己的角落會壓到畫面內容）
                            Positioned(
                              top: 8,
                              right: 8,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  InkWell(
                                    borderRadius: BorderRadius.circular(
                                      kTagRadius,
                                    ),
                                    onTap: () => setState(() {
                                      _fsView = true;
                                      _wmPart = WmPart.none;
                                      _selMosaic = -1;
                                      _selExtra = -1;
                                    }),
                                    child: Container(
                                      padding: const EdgeInsets.all(5),
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.10,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          kTagRadius,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.fullscreen,
                                        size: 15,
                                        color: kIcon,
                                      ),
                                    ),
                                  ),
                                  // 畫布比例（跟影片編輯的膠囊同語言）。
                                  // 馬賽克模式不給換：臉的位置是照照片找的
                                  if (!_mosaicMode)
                                    InkWell(
                                      borderRadius: BorderRadius.circular(
                                        kTagRadius,
                                      ),
                                      onTap: _openRatioSheet,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.10,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            kTagRadius,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.aspect_ratio,
                                              size: 12,
                                              color: kTextDim,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              _ratioLabel,
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
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 控制列：跟影片編輯的控制列同一個位置，
                  // 固定不動也不擋畫面
                  _buildControlBar(),
                  // 塗抹中不給切區段：切走了筆刷還開著，畫面照樣
                  //（使用者回報「筆刷還沒確認就點到調色」）。
                  // 馬賽克模式沒有區段（只有一張面板）
                  if (!_mosaicMode)
                    IgnorePointer(ignoring: _brushMode, child: _sectionBar()),
                  _panelArea(
                    Stack(
                      // 撐滿，不照子件量尺寸：這裡的子件全是定位過的
                      //（面板 Positioned.fill、浮鍵 Positioned），要是哪天
                      // 混進一個沒定位的小東西，loose 的 Stack 會縮成它的
                      // 尺寸——鍵盤開著時面板消失那個 bug 就是這樣來的
                      //（見 _floatingExport）
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          // 筆刷塗抹中：下面的面板整個換成筆刷調整
                          //（樣式/粗細/濃度/柔邊都在這裡調）
                          child: _brushMode
                              ? _brushPanel()
                              : _mosaicMode
                              ? _mosaicModePanel()
                              : switch (_tab) {
                                  1 => ColorGradePanel(
                                    grade: _grade,
                                    onChanged: () => setState(() {}),
                                    onBeforeChange: _pushUndo,
                                    // 上面的區段導覽列已經寫著「調色」了
                                    showTitle: false,
                                    // 給浮在上面的按鈕列讓位，最後一條滑桿
                                    // 才不會被蓋住
                                    bottomInset: 78,
                                    // 面板 dispose 的回呼可能落在這頁收掉之後——要擋
                                    onCompare: (on) {
                                      if (mounted) {
                                        setState(() => _colorCompare = on);
                                      }
                                    },
                                  ),
                                  _ => WatermarkPanel(
                                    // 手繪直接畫在照片上（畫在哪、印在哪）
                                    grabFrame: _grabFrame,
                                    controller: _wmPanelCtrl,
                                    // 導覽列由這一頁自己畫（要多一格「調色」）
                                    showNav: false,
                                    // 給浮在上面的輸出鍵讓位，最後一張卡才捲得完
                                    bottomInset: 78,
                                    settings: _settings,
                                    // 這一頁的面板比影片編輯高，九宮格給大一點
                                    posGridCap: 280,
                                    // 九宮格「貼邊」要知道畫布比例才夾得準
                                    //（build 129 的修法只接了影片編輯器）
                                    canvasAspect: _canvasAspectEff,
                                    onChanged: () => setState(() {}),
                                    // 滑桿拖動中每一格只重畫預覽層
                                    //（放手時面板補一次 onChanged）
                                    onLiveChange: _liveRepaint,
                                    onBeforeChange: _pushUndo,
                                    syncVersion: _sync,
                                    key: _panelKey,
                                    // 儲存範本改成輸出後才問：一顆白色大鈕釘在捲動區
                                    // 最底，跟浮在上面的輸出鍵長得一樣重，互相搶
                                    hideSaveButton: true,
                                    // 剛加的圖片直接選起來，可以馬上拖／縮放
                                    onLogoAdded: () =>
                                        setState(() => _wmPart = WmPart.logo),
                                    // 面板裡點縮圖／文字＝畫面上也選它（單一
                                    // 選取，順手清掉馬賽克與額外浮水印的選取）。
                                    // 沒有這一段，面板亮框的圖片在預覽上拖不動
                                    onSelectPart: (p) => setState(() {
                                      _wmPart = p;
                                      _selMosaic = -1;
                                      _selExtra = -1;
                                    }),
                                    // 馬賽克卡：插在圖片卡下面（照片模式限定）
                                    extraSections: [
                                      (
                                        label: '馬賽克',
                                        icon: Icons.blur_on,
                                        child: _mosaicSection(),
                                      ),
                                    ],
                                  ),
                                },
                        ),
                        _floatingExport(),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 預覽用的馬賽克補丁：直接取樣照片畫「真效果」，
/// 跟匯出（WatermarkRenderer._drawMosaic）同一套邏輯。
/// - 像素化：每格取「格中心那顆像素」鋪滿整格（真色塊）
/// - 模糊：整張圖經模糊層畫進來，柔邊用「內縮白方塊＋霧化」
///   當 alpha 遮罩（dstIn），邊緣平滑淡出、沒有分界線
/// 筆刷筆畫的預覽補丁：把照片座標的筆畫交給共用畫家
/// paintMosaicStroke（跟照片匯出同一段程式碼）
class _MosaicStrokePainter extends CustomPainter {
  final ui.Image img;

  // 值拷貝，理由同 _MosaicPatchPainter（原地改值要能觸發重繪）
  final MosaicStyle _style;
  final int type;
  final double strength;
  final double feather;
  final double brush;
  final List<double> stroke;

  _MosaicStrokePainter({
    required this.img,
    required MosaicStyle style,
    required List<double> strokePts,
    required this.brush,
  }) : _style = style.copy(),
       type = style.type,
       strength = style.strength,
       feather = style.feather,
       stroke = List.of(strokePts);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [
      for (var k = 0; k + 1 < stroke.length; k += 2)
        Offset(stroke[k] * img.width, stroke[k + 1] * img.height),
    ];
    if (pts.isEmpty) return;
    final brushPx = brush * math.min(img.width, img.height).toDouble();
    final box = strokeBoundsPx(pts, brushPx, strokeFeatherPx(_style, brushPx));
    paintMosaicStroke(
      canvas,
      img,
      _style,
      pts,
      brushPx,
      box,
      Offset.zero & size,
    );
  }

  @override
  bool shouldRepaint(_MosaicStrokePainter old) =>
      old.img != img ||
      old.type != type ||
      old.strength != strength ||
      old.feather != feather ||
      old.brush != brush ||
      !listEquals(old.stroke, stroke);
}

class _MosaicPatchPainter extends CustomPainter {
  final ui.Image img;

  // 樣式「值」在建構時拆開存——存物件參照的話，滑桿原地改值
  // 會讓新舊 painter 比對永遠相等，畫面不重繪
  final int type;
  final double strength;
  final double feather;

  /// 給共用畫家用的快照（值拷貝，理由同上）
  final MosaicStyle _style;

  /// 這塊區域對應到照片上的範圍（照片像素座標）
  final Rect srcRect;

  /// 裁成內切橢圓（臉）
  final bool oval;

  _MosaicPatchPainter({
    required this.img,
    required MosaicStyle style,
    required this.srcRect,
    this.oval = false,
  }) : type = style.type,
       strength = style.strength,
       feather = style.feather,
       _style = style.copy();

  @override
  void paint(Canvas canvas, Size size) {
    // 格數/取色/模糊半徑/羽化全交給共用畫家
    //（跟照片匯出執行同一段程式碼）
    paintMosaicPatch(
      canvas,
      img,
      _style,
      srcRect,
      Offset.zero & size,
      oval: oval,
    );
  }

  @override
  bool shouldRepaint(_MosaicPatchPainter old) =>
      old.img != img ||
      old.srcRect != srcRect ||
      old.oval != oval ||
      old.type != type ||
      old.strength != strength ||
      old.feather != feather;
}

/// 只留 [frac]（0~1，對自己的寬高）那一塊：小圖切掉照片外面那截
class _FracClipper extends CustomClipper<Rect> {
  final Rect frac;

  const _FracClipper(this.frac);

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    frac.left * size.width,
    frac.top * size.height,
    frac.right * size.width,
    frac.bottom * size.height,
  );

  @override
  bool shouldReclip(_FracClipper oldClipper) => oldClipper.frac != frac;
}

/// 點掉的臉的縮圖：照片原本那一塊（不碼），橢圓就裁成橢圓
class _CropPainter extends CustomPainter {
  final ui.Image img;
  final Rect srcRect;
  final bool oval;

  const _CropPainter({
    required this.img,
    required this.srcRect,
    required this.oval,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    if (oval) {
      canvas.save();
      canvas.clipPath(Path()..addOval(dst));
    }
    canvas.drawImageRect(
      img,
      srcRect,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (oval) canvas.restore();
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.img != img || old.srcRect != srcRect || old.oval != oval;
}

/// 「亮一下」：一圈白光從亮到沒（0.8 秒）。照片上的馬賽克不畫框，
/// 剛加的、點到的靠這個認出是哪一塊。外面要多留 [pad] 給光暈擴散
class _FlashGlow extends StatelessWidget {
  static const double pad = 14;
  final bool oval;

  const _FlashGlow({super.key, required this.oval});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 1, end: 0),
    duration: const Duration(milliseconds: 800),
    curve: Curves.easeIn,
    builder: (context, v, _) => v <= 0.01
        ? const SizedBox.shrink()
        : CustomPaint(
            painter: _GlowPainter(v: v, oval: oval),
          ),
  );
}

class _GlowPainter extends CustomPainter {
  final double v;
  final bool oval;

  const _GlowPainter({required this.v, required this.oval});

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(_FlashGlow.pad);
    final path = oval ? (Path()..addOval(r)) : (Path()..addRect(r));
    canvas
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..color = Colors.white.withValues(alpha: 0.55 * v)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withValues(alpha: 0.7 * v),
      );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.v != v || old.oval != oval;
}

/// 效果磚上的小樣本：像素化＝一小格臉的色塊、模糊＝暈開的一團、
/// 純色＝現在選的那個顏色
class _MzSwatch extends StatelessWidget {
  final int type;
  final int color;

  const _MzSwatch(this.type, {this.color = 0xFF000000});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 28,
    height: 28,
    child: switch (type) {
      0 => ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: const CustomPaint(painter: _PixelSwatchPainter()),
      ),
      1 => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          gradient: const RadialGradient(
            center: Alignment(0, -0.16),
            radius: 0.75,
            colors: [
              Color(0xFFE8C3A7),
              Color(0xFFD2A88F),
              Color(0xFF7D6E86),
              Color(0xFF8E95B8),
            ],
            stops: [0, 0.26, 0.58, 1],
          ),
        ),
      ),
      _ => DecoratedBox(
        decoration: BoxDecoration(
          color: Color(color),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFF3A3A42)),
        ),
      ),
    },
  );
}

class _PixelSwatchPainter extends CustomPainter {
  const _PixelSwatchPainter();

  // 4×4：頭髮、膚色、衣服——一眼看得出是「把臉碼成格子」
  static const _cells = [
    0xFF2A211E, 0xFF3A2C27, 0xFF3A2C27, 0xFF2A211E, //
    0xFF3A2C27, 0xFFD8B096, 0xFFE2BBA0, 0xFF3A2C27, //
    0xFF5B4740, 0xFFE8C3A7, 0xFFDDB59A, 0xFF4A3A35, //
    0xFF9E8CC0, 0xFFC9A592, 0xFFC29F8D, 0xFFA895C8, //
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / 4, ch = size.height / 4;
    for (var i = 0; i < _cells.length; i++) {
      canvas.drawRect(
        Rect.fromLTWH((i % 4) * cw, (i ~/ 4) * ch, cw + 0.5, ch + 0.5),
        Paint()..color = Color(_cells[i]),
      );
    }
  }

  @override
  bool shouldRepaint(_PixelSwatchPainter old) => false;
}

/// 縮圖那排最後的「新增」格：虛線圓角框
class _DashedTilePainter extends CustomPainter {
  const _DashedTilePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      const Radius.circular(12),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF6A6A74);
    for (final metric in (Path()..addRRect(r)).computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 5, metric.length)),
          paint,
        );
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedTilePainter old) => false;
}
