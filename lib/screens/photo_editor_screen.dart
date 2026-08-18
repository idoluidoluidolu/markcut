import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/color_grade.dart';
import '../models/mosaic.dart';
import '../models/watermark_settings.dart';
import '../services/photo_saver.dart';
import '../theme.dart';
import '../services/watermark_renderer.dart';
import '../widgets/color_grade_panel.dart';
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
  final XFile photo;
  final WatermarkSettings? initialWatermark;

  /// 從草稿還原：整份編輯狀態的 JSON（見 _stateJson）
  final String? draft;

  const PhotoEditorScreen({
    super.key,
    required this.photo,
    this.initialWatermark,
    this.draft,
  });

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  late final WatermarkSettings _settings =
      widget.initialWatermark?.copy() ?? WatermarkSettings();

  /// 被選浮水印部件的框（畫在裁切外，拖出照片也看得到位置）
  final _wmFrameInfo = ValueNotifier<WmFrameInfo?>(null);
  Uint8List? _photoBytes;
  double? _aspect; // 照片長寬比
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
      WmPart.text
          when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
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
  Future<void> _saveDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kPhotoDraftKey,
      jsonEncode({
        'photo': widget.photo.path,
        'state': _stateJson,
        'savedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  static Future<void> clearPhotoDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPhotoDraftKey);
  }

  // ===== 馬賽克（照片模式：任意數量的方形區域）=====
  // 存在 WatermarkSettings 上：跟著範本一起存／套用，
  // undo 快照與「有沒有改過」判定也自動涵蓋
  List<PhotoMosaic> get _mosaics => _settings.mosaics;
  int _selMosaic = -1;

  /// 更多浮水印：每一組是完整的一套（文字＋Logo），
  /// 疊在主浮水印上面，可各自拖曳、獨立刪除
  final List<WatermarkSettings> _extraWms = [];

  /// 選取中的「浮水印＋」：第幾組、哪個部件（-1 = 沒有）。
  /// 跟主浮水印／馬賽克互斥（單一選取）
  int _selExtra = -1;
  WmPart _selExtraPart = WmPart.none;

  /// 被選的額外浮水印部件是否還活著（同 _wmPartAlive 的理由）
  WmPart _extraPartAlive(int i) {
    if (_selExtra != i || i < 0 || i >= _extraWms.length) return WmPart.none;
    final t = _extraWms[i].text;
    final lg = _extraWms[i].logo;
    return switch (_selExtraPart) {
      WmPart.text
          when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
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

  String get _stateJson {
    final j = <String, dynamic>{
      ..._settings.toJson(),
      'color': _grade.toJson(),
      'extraWms': _extraWms.map((e) => e.toJson()).toList(),
    };
    _packLogo(j);
    for (final e in (j['extraWms'] as List)) {
      _packLogo(e);
    }
    return jsonEncode(j);
  }

  bool get _dirty => _stateJson != _initialJson;

  /// 離開保護：調過浮水印但沒輸出就問一下
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    // 跟影片編輯同一款三顆直排。以前只有「放棄」一條路，
    // 調了半天的馬賽克跟好幾組浮水印會整個蒸發
    final act = await showLeaveChoice(
      context,
      title: '還沒輸出',
      message: '留著草稿的話，下次可以從首頁接著改',
      keepLabel: '保留草稿',
      discardLabel: '捨棄',
    );
    if (!mounted) return;
    if (act == 'keep') {
      await _saveDraft();
      if (mounted) Navigator.of(context).pop();
    } else if (act == 'discard') {
      Navigator.of(context).pop();
    }
  }

  // ===== 上一步（改壞了可以救；連續滑桿拖動 0.7 秒內併成一步）=====
  final List<String> _undoStack = [];
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
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

  void _pushUndo() {
    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < 700) return;
    _lastPush = now;
    _undoStack.add(_stateJson);
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
            (e) => WatermarkSettings.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          ),
        );
      // 復原可能把被選取的部件變不見（例如撤銷加 Logo），
      // 選取殘留會讓拖曳整個變死的
      _wmPart = WmPart.none;
      _selMosaic = -1;
      _selExtra = -1;
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
    _photoImg?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.photo.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _photoBytes = bytes;
        _photoImg = frame.image;
        _aspect = frame.image.width / frame.image.height;
      });
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

  /// 預覽與面板之間的控制列：上一步／重做（四個編輯畫面共用同一條）
  Widget _buildControlBar() => undoRedoBar(
        onUndo: _undoStack.isEmpty ? null : _undoLast,
        onRedo: _redoStack.isEmpty ? null : _redoLast,
      );

  /// 加一組浮水印：以目前主浮水印為底複製一組，稍微錯開位置
  void _addExtraWm() {
    final t = _settings.text;
    final hasAny = (t.enabled && t.text.trim().isNotEmpty) ||
        _settings.logos.any((l) => l.enabled);
    if (!hasAny) {
      showHint(context, '先把上面的浮水印設定好，再新增更多組');
      return;
    }
    _pushUndo();
    final copy = _settings.copy()..mosaics.clear();
    copy.text.x = (copy.text.x + 0.08).clamp(0.0, 1.0);
    copy.text.y = (copy.text.y + 0.08).clamp(0.0, 1.0);
    // 每一張圖片都要錯開，不然多圖的那幾張會整個疊在原來的位置上
    for (final l in copy.logos) {
      l.x = (l.x + 0.08).clamp(0.0, 1.0);
      l.y = (l.y + 0.08).clamp(0.0, 1.0);
    }
    setState(() => _extraWms.add(copy));
    _editExtraWm(_extraWms.length - 1);
  }

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
        _selExtraPart =
            (t.enabled && !t.tiled && t.text.trim().isNotEmpty)
            ? WmPart.text
            : WmPart.logo;
      }
      _wmPart = WmPart.none;
      _selMosaic = -1;
    });
    var pushed = false;
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
                    label: const Text(
                      '刪除這組',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: WatermarkPanel(
                settings: target,
                onChanged: () => setState(() {}),
                onBeforeChange: () {
                  if (!pushed) {
                    pushed = true;
                    _pushUndo();
                  }
                },
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

  String _extraWmLabel(int i) => _labelOf(_extraWms[i]);

  /// 面板裡的「浮水印＋」卡（A 版）：整列可點進編輯（右邊箭頭），
  /// 刪除收在編輯面板裡；最下面永遠有一個「浮水印＋」可以再加
  Widget _extraWmSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _extraWms.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _editExtraWm(i),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: kBorder)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.branding_watermark,
                    size: 14,
                    color: kTextDim,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _extraWmLabel(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: kText),
                    ),
                  ),
                  const Text(
                    '點我編輯',
                    style: TextStyle(fontSize: 11, color: kTextDim),
                  ),
                  const Icon(Icons.chevron_right, size: 17, color: kTextDim),
                ],
              ),
            ),
          ),
        // 永遠釘在最下面的「浮水印＋」：跟圖片/馬賽克卡同一套排法
        InkWell(
          onTap: _addExtraWm,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              const Text(
                '浮水印',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: kText,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '再加一組浮水印',
                visualDensity: VisualDensity.compact,
                onPressed: _addExtraWm,
                icon: const Icon(Icons.add, size: 20, color: kIcon),
              ),
            ],
          ),
        ),
      ],
    );
  }

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
                  _mosaics[i].style.type == 2
                      ? Icons.square_rounded
                      : Icons.blur_on,
                  size: 15,
                  color: _mosaics[i].style.type == 2
                      ? Color(_mosaics[i].style.color)
                      : (_selMosaic == i ? kSelect : kTextDim),
                ),
                const SizedBox(width: 8),
                Text(
                  '第 ${i + 1} 塊 · ${typeNames[_mosaics[i].style.type]}',
                  style: TextStyle(
                    fontSize: 12,
                    color: _selMosaic == i ? kSelect : kTextDim,
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
  void _phSetBox(int kind, int index, Rect? text, List<Rect?> logos) {
    void put(WmPart part, int logo, Rect? r) {
      final id = (kind: kind, index: index, part: part, logo: logo);
      if (r == null) {
        _phBox.remove(id);
      } else {
        _phBox[id] = r;
      }
    }

    put(WmPart.text, -1, text);
    // 張數會變（加圖、刪圖），先把這一組舊的圖片框全清掉再重放，
    // 不然刪掉的那張會留一個永遠點得到的鬼框
    _phBox.removeWhere(
      (k, _) => k.kind == kind && k.index == index && k.part == WmPart.logo,
    );
    for (var i = 0; i < logos.length; i++) {
      put(WmPart.logo, i, logos[i]);
    }
  }

  /// 置頂導覽列的項目。順序要跟 WatermarkPanel 裡那份一模一樣——
  /// 這一條是自己畫的，但按下去是叫面板跳第幾區，索引對不上就跳錯。
  /// 第一格「範本」不是區段，按了直接開挑選視窗；最後的「調色」是
  /// 另一個模式（點了整個換掉下半部），因為調色面板自己有捲動清單，
  /// 塞不進面板當一張卡
  static const _phNav = [
    (label: '範本', icon: Icons.bookmarks_outlined),
    (label: '位置', icon: Icons.grid_view),
    (label: '文字', icon: Icons.title),
    (label: '圖片', icon: Icons.image_outlined),
    (label: '馬賽克', icon: Icons.blur_on),
    (label: '更多', icon: Icons.branding_watermark),
    (label: '調色', icon: Icons.tune),
  ];

  /// 調色在導覽列的位置（最後一格）
  static const _phColorIdx = 6;

  Widget _sectionBar() => AnimatedBuilder(
        // 面板捲動時會回報捲到第幾區。只重畫這一條，
        // 不要整頁 setState——預覽跟著重建會頓
        animation: _wmPanelCtrl,
        builder: (context, _) => _sectionBarBody(),
      );

  Widget _sectionBarBody() {
    // 調色模式時高亮最後一格，否則跟著面板捲到哪就亮哪。
    // 捲到「更多浮水印」那一區時沒有對應的格子（見 _phNav），
    // 這時不要亂亮——不然會亮到「調色」上面去
    final sec = _wmPanelCtrl.activeSection;
    final active =
        _tab == 1 ? _phColorIdx : (sec < _phColorIdx ? sec : -1);
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
                  _wmPanelCtrl.jumpToSection(i);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  // D 案：選中不填色，改畫線框。框在前景，內容不位移
                  foregroundDecoration: i == active
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: kAmber, width: 1.5),
                        )
                      : null,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_phNav[i].icon,
                          size: 17, color: i == active ? kText : kTextDim),
                      const SizedBox(height: 3),
                      Text(_phNav[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5,
                              color: i == active ? kText : kTextDim)),
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
  Widget _floatingExport() => Positioned(
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
                  height: 40,
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
                      Expanded(
                        child: secondaryAction(
                          label: '存成範本',
                          onPressed: _exporting ? null : _savePresetFromBar,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: primaryAction(
                          label: '輸出',
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

  Widget _buildMosaics(double w, double h) {
    final children = <Widget>[];
    for (var i = 0; i < _mosaics.length; i++) {
      final m = _mosaics[i];
      final side = m.scale * math.min(w, h);
      final rect = Rect.fromCenter(
        center: Offset(m.x * w, m.y * h),
        width: side,
        height: side,
      );
      Widget effect;
      if (m.style.type == 2) {
        effect = Container(color: Color(m.style.color));
      } else if (_photoImg != null) {
        // 直接取樣照片畫效果：真像素塊、真羽化（跟匯出同一套畫法，
        // web 也一樣）。調色時把同一個矩陣套在補丁上，顏色才會對
        Widget patch = CustomPaint(
          painter: _MosaicPatchPainter(
            img: _photoImg!,
            style: m.style,
            srcRect: Rect.fromLTWH(
              rect.left * _photoImg!.width / w,
              rect.top * _photoImg!.height / h,
              rect.width * _photoImg!.width / w,
              rect.height * _photoImg!.height / h,
            ),
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
          final cell = math.max(2.0, side * dpr / cells);
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
        effect = ClipRect(
          child: BackdropFilter(
            filter: filter,
            child: const SizedBox.expand(),
          ),
        );
      }
      _phBox[(kind: 0, index: i, part: WmPart.none, logo: -1)] = rect;
      children.add(
        Positioned.fromRect(
          rect: rect,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 點擊統一由上面那層判定（重疊時要能往下鑽），
            // 這裡留著只是萬一那層沒攔到的退路
            onTap: () {
              if (_selMosaic == i) {
                _editMosaic(i);
              } else {
                setState(() {
                  _selMosaic = i;
                  _wmPart = WmPart.none;
                  _selExtra = -1;
                });
              }
            },
            onPanStart: (_) {
              if (_pvPts.length >= 2) return;
              _phClearGuides();
              _phUndoPending = true; // 真的拖到才拍（見 _phPushUndoIfNeeded）
              setState(() {
                _selMosaic = i;
                _wmPart = WmPart.none;
                _selExtra = -1;
              });
            },
            onPanUpdate: (d) {
              if (_pvPts.length >= 2) return;
              _phPushUndoIfNeeded();
              setState(() {
                // 原始座標累積、顯示值吸中線（同浮水印手感）
                _phRawX ??= m.x;
                _phRawY ??= m.y;
                _phRawX = (_phRawX! + d.delta.dx / w).clamp(0.0, 1.0);
                _phRawY = (_phRawY! + d.delta.dy / h).clamp(0.0, 1.0);
                m.x = _snapC(_phRawX!);
                m.y = _snapC(_phRawY!);
              });
              _phSetGuides(m.x, m.y);
            },
            onPanEnd: (_) => _phClearGuides(),
            onPanCancel: _phClearGuides,
            child: Stack(
              fit: StackFit.expand,
              children: [
                effect,
                // 選取框跟浮水印同一套：細白框
                if (_selMosaic == i)
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.9),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Stack(clipBehavior: Clip.hardEdge, children: children);
  }

  void _addMosaic() {
    _pushUndo();
    setState(() {
      _mosaics.add(PhotoMosaic());
      _selMosaic = _mosaics.length - 1;
      _wmPart = WmPart.none;
      _selExtra = -1;
    });
  }

  /// 馬賽克樣式表（照片版）：樣式＋大小＋濃度/顏色＋移除
  void _editMosaic(int i) {
    if (i < 0 || i >= _mosaics.length) return;
    final m = _mosaics[i];
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
                    children: [chip('像素化', 0), chip('模糊', 1), chip('純色遮蓋', 2)],
                  ),
                  const SizedBox(height: 14),
                  row(
                    '大小',
                    // 上限跟影片端一致（原本這裡是 1.5、那邊 3.0，
                    // 同一個功能能拉的範圍卻不一樣）
                    Slider(
                      value: m.scale.clamp(0.05, 3.0),
                      min: 0.05,
                      max: 3.0,
                      onChanged: (v) => change(() => m.scale = v),
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
                        onChanged: (v) => change(() => m.style.strength = v),
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
                          onChanged: (v) => change(() => m.style.feather = v),
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
    context, Color(m.style.color));
final ok = picked != null;
final color = Color(picked ?? 0);
                              if (ok == true) {
                                change(
                                  () => m.style.color = color.toARGB32(),
                                );
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
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final fmt = await askPhotoFormat(context);
    if (fmt == null || !mounted) return;
    await prefs.setString('photo_export_fmt', fmt);
    await _export(jpeg: fmt == 'jpg');
  }


  Future<void> _export({bool jpeg = false}) async {
    if (_exporting || _photoBytes == null) return;
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
          title: Text('輸出中…'),
          content: SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    String message;
    String? note;
    var ok = true;
    try {
      // 以原始解析度合成（合成永遠是無損 PNG，要 JPEG 才轉檔）
      var bytes = await WatermarkRenderer.renderPhotoComposite(
        _photoBytes!,
        _settings,
        grade: _grade,
        mosaics: _mosaics,
        extraMarks: _extraWms,
      );
      var ext = 'png';
      if (jpeg) {
        try {
          bytes = await FlutterImageCompress.compressWithList(
            bytes,
            quality: 92,
            format: CompressFormat.jpeg,
          );
          ext = 'jpg';
        } catch (_) {
          // 這個平台轉不了 JPEG 就照樣給 PNG，總比失敗好
        }
      }
      message = await savePhotoPng(
        bytes,
        'watermarker_${DateTime.now().millisecondsSinceEpoch}',
        ext: ext,
      );
      // 這句是次要說明，不要接在主訊息後面變成一長串括號
      if (jpeg && ext == 'png') note = '這個裝置不支援 JPEG，已改存 PNG';
    } catch (e) {
      message = '輸出失敗：$e';
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
      add((kind: kind, index: index, part: WmPart.text, logo: -1));
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
      return (
        kind: 2,
        index: _selExtra,
        part: _selExtraPart,
        logo: _selExtraPart == WmPart.logo
            ? _extraWms[_selExtra].activeLogo
            : -1,
      );
    }
    if (_wmPart != WmPart.none) {
      return (
        kind: 1,
        index: -1,
        part: _wmPart,
        logo: _wmPart == WmPart.logo ? _settings.activeLogo : -1,
      );
    }
    return null;
  }

  /// 點預覽區：選這個點上最上面的東西。
  /// 同一點連續點擊往下鑽一層——完全被蓋住的圖層本來永遠選不到
  void _phTapAt(Offset p) {
    FocusManager.instance.primaryFocus?.unfocus();
    final hits = [
      for (final id in _phOrder())
        if (_phBox[id]!.contains(p)) id,
    ];
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
      // 點到哪一張圖片，那張就變成操作中的（面板、捏合都跟著它）
      if (next.logo >= 0) {
        if (next.kind == 1) _settings.activeLogo = next.logo;
        if (next.kind == 2) _extraWms[next.index].activeLogo = next.logo;
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

  // ===== 置中吸附（路由拖曳／馬賽克拖曳共用，跟 WatermarkLayer 同手感）=====
  /// 未吸附的原始座標（吸附只作用在顯示值上，不然吸上就拖不出來）
  double? _phRawX, _phRawY;
  bool _phGuideV = false, _phGuideH = false;
  bool _phSnapped = false;

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
    if (on != _phSnapped) {
      _phSnapped = on;
      if (on) HapticFeedback.selectionClick();
    }
  }

  void _phClearGuides() {
    _phRawX = null;
    _phRawY = null;
    _phSnapped = false;
    if (_phGuideV || _phGuideH) {
      setState(() {
        _phGuideV = false;
        _phGuideH = false;
      });
    }
  }

  // ===== 預覽區雙指縮放（照片上的浮水印／選中的馬賽克）=====
  final Map<int, Offset> _pvPts = {};
  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;
  double _pvBaseMosaic = 0.35;
  double _pvBaseExtraText = 0.12;
  double _pvBaseExtraLogo = 0.18;

  void _pinchDown(PointerDownEvent e) {
    _pvPts[e.pointer] = e.position;
    if (_pvPts.length != 2) return;
    final p = _pvPts.values.toList();
    final d = (p[0] - p[1]).distance;
    if (d <= 20) return;
    _pvBaseDist = d;
    _pvBaseText = _settings.text.sizeFrac;
    _pvBaseLogo = _settings.logo.sizeFrac;
    if (_selMosaic >= 0 && _selMosaic < _mosaics.length) {
      _pvBaseMosaic = _mosaics[_selMosaic].scale;
    }
    if (_selExtra >= 0 && _selExtra < _extraWms.length) {
      _pvBaseExtraText = _extraWms[_selExtra].text.sizeFrac;
      _pvBaseExtraLogo = _extraWms[_selExtra].logo.sizeFrac;
    }
    _phUndoPending = true;
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    _phPushUndoIfNeeded(); // 真的縮到東西了才拍
    setState(() {
      // 有選中馬賽克：雙指縮它，不動浮水印
      if (_selMosaic >= 0 && _selMosaic < _mosaics.length) {
        _mosaics[_selMosaic].scale = (_pvBaseMosaic * f).clamp(0.05, 1.5);
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
        }
        if (hasLogo && (part != WmPart.text || !hasText)) {
          e.logo.sizeFrac = (_pvBaseExtraLogo * f).clamp(0.03, 2.0);
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
      if (doText) t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
      if (doLogo) {
        _settings.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
      }
    });
  }

  void _pinchUp(int pointer) {
    _pvPts.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) _pvBaseDist = null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(),
        body: _photoBytes == null || _aspect == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    flex: 5,
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
                        child: Container(
                          // 跟影片／批次／工作室同一個底色。原本是純黑，
                          // 直式照片兩側留邊會比其他畫面暗一階
                          color: kPreviewBg,
                          alignment: Alignment.center,
                          child: AspectRatio(
                            aspectRatio: _aspect!,
                            child: Stack(
                              fit: StackFit.expand,
                              // 不裁切：浮水印選取框要能畫到照片外
                              //（內容由 WatermarkLayer 自己的 Stack 裁）
                              clipBehavior: Clip.none,
                              children: [
                                // 調色即時反映在預覽上
                                if (_grade.hasColor && !_colorCompare)
                                  ColorFiltered(
                                    colorFilter: ColorFilter.matrix(
                                      _grade.matrix,
                                    ),
                                    child: Image.memory(
                                      _photoBytes!,
                                      fit: BoxFit.contain,
                                    ),
                                  )
                                else
                                  Image.memory(
                                    _photoBytes!,
                                    fit: BoxFit.contain,
                                  ),
                                // 馬賽克層：畫在照片上、浮水印下
                                if (_mosaics.isNotEmpty)
                                  Positioned.fill(
                                    child: LayoutBuilder(
                                      builder: (context, box) =>
                                          _buildMosaics(
                                            box.maxWidth,
                                            box.maxHeight,
                                          ),
                                    ),
                                  ),
                                WatermarkLayer(
                                  settings: _settings,
                                  onChanged: () => setState(() {}),
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
                                  panLocked: () => _pvPts.length >= 2,
                                  // 別的東西被選取時完全不吃拖曳，讓給下面的
                                  // 選取路由——不然選了馬賽克在畫面上拖，
                                  // 手指剛好經過浮水印就會把浮水印拖走
                                  panAllowed: (_) =>
                                      _selMosaic == -1 && _selExtra == -1,
                                ),
                                // 更多浮水印：一組一層疊上去，各自拖曳；
                                // 點一下＝選取（白框）＋直接開編輯面板
                                for (var i = 0; i < _extraWms.length; i++)
                                  WatermarkLayer(
                                    settings: _extraWms[i],
                                    onChanged: () => setState(() {}),
                                    onDragStart: _pushUndo,
                                    onHitBox: (t, l) => _phSetBox(2, i, t, l),
                                    selectedPart: _extraPartAlive(i),
                                    onSelectPart: (p) {
                                      setState(() {
                                        _selExtra = i;
                                        _selExtraPart = p;
                                        _wmPart = WmPart.none;
                                        _selMosaic = -1;
                                      });
                                      _editExtraWm(i);
                                    },
                                    panLocked: () => _pvPts.length >= 2,
                                    // 同上：馬賽克選取中誰都不准拖；
                                    // 選了別組浮水印時這一組也不吃
                                    panAllowed: (_) =>
                                        _selMosaic == -1 &&
                                        (_selExtra == -1 || _selExtra == i),
                                  ),
                                // 點擊判定層：疊在所有圖層之上，統一決定
                                // 點到誰。translucent＝只搶點擊，
                                // 拖曳照樣傳給下面的圖層與選取路由
                                Positioned.fill(
                                  child: LayoutBuilder(
                                    builder: (context, box) => GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTapUp: (d) =>
                                          _phTapAt(d.localPosition),
                                      child: const SizedBox.expand(),
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
                                  child: WmFrameOverlay(_wmFrameInfo),
                                ),
                                // 選取路由：有部件被選取（白框）時，
                                // 整個預覽的拖曳都只動被選的那個——
                                // 跟影片編輯同一套規則
                                if (_wmPartAlive != WmPart.none)
                                  Positioned.fill(
                                    key: const ValueKey('wm-route'),
                                    child: LayoutBuilder(
                                      builder: (context, box) {
                                        final w = box.maxWidth;
                                        final h = box.maxHeight;
                                        return GestureDetector(
                                          behavior:
                                              HitTestBehavior.translucent,
                                          onPanStart: (_) {
                                            _phClearGuides();
                                            if (_pvPts.length < 2) {
                                              _phUndoPending = true;
                                            }
                                          },
                                          onPanUpdate: (d) {
                                            if (_pvPts.length >= 2) return;
                                            _phPushUndoIfNeeded();
                                            final t = _settings.text;
                                            final lg = _settings.logo;
                                            final part = _wmPartAlive;
                                            setState(() {
                                              // 原始座標累積、顯示值吸中線
                                              //（同 WatermarkLayer 手感）
                                              if (part == WmPart.text &&
                                                  t.enabled &&
                                                  !t.tiled &&
                                                  t.text.trim().isNotEmpty) {
                                                _phRawX ??= t.x;
                                                _phRawY ??= t.y;
                                                _phRawX =
                                                    (_phRawX! +
                                                            d.delta.dx / w)
                                                        .clamp(0.0, 1.0);
                                                _phRawY =
                                                    (_phRawY! +
                                                            d.delta.dy / h)
                                                        .clamp(0.0, 1.0);
                                                t.x = _snapC(_phRawX!);
                                                t.y = _snapC(_phRawY!);
                                                _phSetGuides(t.x, t.y);
                                              } else if (part ==
                                                      WmPart.logo &&
                                                  lg.enabled &&
                                                  !lg.tiled) {
                                                _phRawX ??= lg.x;
                                                _phRawY ??= lg.y;
                                                _phRawX =
                                                    (_phRawX! +
                                                            d.delta.dx / w)
                                                        .clamp(0.0, 1.0);
                                                _phRawY =
                                                    (_phRawY! +
                                                            d.delta.dy / h)
                                                        .clamp(0.0, 1.0);
                                                lg.x = _snapC(_phRawX!);
                                                lg.y = _snapC(_phRawY!);
                                                _phSetGuides(lg.x, lg.y);
                                              }
                                            });
                                          },
                                          onPanEnd: (_) => _phClearGuides(),
                                          onPanCancel: _phClearGuides,
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
                    ),
                  ),
                  // 控制列：跟影片編輯的控制列同一個位置，
                  // 固定不動也不擋畫面
                  _buildControlBar(),
                  _sectionBar(),
                  Expanded(
                    flex: 5,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: switch (_tab) {
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
                          if (mounted) setState(() => _colorCompare = on);
                        },
                      ),
                      _ => WatermarkPanel(
                        controller: _wmPanelCtrl,
                        // 導覽列由這一頁自己畫（要多一格「調色」）
                        showNav: false,
                        // 給浮在上面的輸出鍵讓位，最後一張卡才捲得完
                        bottomInset: 78,
                        settings: _settings,
                        onChanged: () => setState(() {}),
                        onBeforeChange: _pushUndo,
                        syncVersion: _sync,
                        key: _panelKey,
                        // 儲存範本改成輸出後才問：一顆白色大鈕釘在捲動區
                        // 最底，跟浮在上面的輸出鍵長得一樣重，互相搶
                        hideSaveButton: true,
                        // 剛加的圖片直接選起來，可以馬上拖／縮放
                        onLogoAdded: () =>
                            setState(() => _wmPart = WmPart.logo),
                        // 馬賽克/更多浮水印卡：插在圖片卡下面（照片模式限定）
                        extraSections: [
                          (
                            label: '馬賽克',
                            icon: Icons.blur_on,
                            child: _mosaicSection(),
                          ),
                          (
                            label: '更多浮水印',
                            icon: Icons.branding_watermark,
                            child: _extraWmSection(),
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
class _MosaicPatchPainter extends CustomPainter {
  final ui.Image img;

  // 樣式「值」在建構時拆開存——存物件參照的話，滑桿原地改值
  // 會讓新舊 painter 比對永遠相等，畫面不重繪
  final int type;
  final double strength;
  final double feather;

  /// 這塊區域對應到照片上的範圍（照片像素座標）
  final Rect srcRect;

  _MosaicPatchPainter({
    required this.img,
    required MosaicStyle style,
    required this.srcRect,
  }) : type = style.type,
       strength = style.strength,
       feather = style.feather;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 1 || size.height < 1) return;
    final scale = size.width / srcRect.width;
    // 「整張圖」在此補丁座標系裡的位置：srcRect 對齊 (0,0)~size
    final dstFull = Rect.fromLTWH(
      -srcRect.left * scale,
      -srcRect.top * scale,
      img.width * scale,
      img.height * scale,
    );

    // 柔邊的遮罩寬度（像素化與模糊共用同一條公式）
    final featherPx = feather * 0.2 * math.min(size.width, size.height);
    final bounds = Offset.zero & size;

    /// 把剛畫好的那一層用「中間實、邊緣淡」的遮罩收邊。
    /// 遮罩用圖層模糊而不是 MaskFilter——web 的繪圖引擎對 MaskFilter
    /// 支援不完整，會變成硬邊
    void softEdge() {
      canvas.saveLayer(
        bounds,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: featherPx * 0.5,
            sigmaY: featherPx * 0.5,
          ),
      );
      canvas.drawRect(
        bounds.deflate(featherPx),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      canvas.restore();
      canvas.restore();
    }

    if (type == 0) {
      // 真像素塊：每格取格中心像素
      final soft = featherPx >= 1;
      if (soft) canvas.saveLayer(bounds, Paint());
      final cells = (26 - 20 * strength).round().clamp(4, 40);
      final nx = cells;
      final ny = math.max(1, (cells * size.height / size.width).round());
      final cw = size.width / nx;
      final ch = size.height / ny;
      final paintCell = Paint()..filterQuality = FilterQuality.none;
      for (var iy = 0; iy < ny; iy++) {
        for (var ix = 0; ix < nx; ix++) {
          final sx = srcRect.left + (ix + 0.5) / nx * srcRect.width;
          final sy = srcRect.top + (iy + 0.5) / ny * srcRect.height;
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(
              sx.clamp(0.0, img.width - 1.0),
              sy.clamp(0.0, img.height - 1.0),
              1,
              1,
            ),
            Rect.fromLTWH(ix * cw, iy * ch, cw + 0.5, ch + 0.5),
            paintCell,
          );
        }
      }
      if (soft) softEdge();
      return;
    }

    // 模糊
    final sigma = 4.0 + 16 * strength;
    if (featherPx >= 1) {
      canvas.saveLayer(bounds, Paint());
      canvas.save();
      canvas.clipRect(bounds);
      canvas.saveLayer(
        bounds,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        dstFull,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      canvas.restore();
      softEdge();
      return;
    }
    canvas.save();
    canvas.clipRect(bounds);
    canvas.saveLayer(
      bounds,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dstFull,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MosaicPatchPainter old) =>
      old.img != img ||
      old.srcRect != srcRect ||
      old.type != type ||
      old.strength != strength ||
      old.feather != feather;
}
