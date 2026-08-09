import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/color_grade.dart';
import '../models/watermark_settings.dart';
import '../services/photo_saver.dart';
import '../theme.dart';
import '../services/watermark_renderer.dart';
import '../widgets/color_grade_panel.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

class PhotoEditorScreen extends StatefulWidget {
  final XFile photo;
  final WatermarkSettings? initialWatermark;

  const PhotoEditorScreen({
    super.key,
    required this.photo,
    this.initialWatermark,
  });

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  late final WatermarkSettings _settings =
      widget.initialWatermark?.copy() ?? WatermarkSettings();
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

  /// 進來時的設定快照＋是否已輸出，決定離開要不要問
  late String _initialJson;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _initialJson = _stateJson;
    _load();
  }

  String get _stateJson =>
      jsonEncode({..._settings.toJson(), 'color': _grade.toJson()});

  bool get _dirty => !_saved && _stateJson != _initialJson;

  /// 離開保護：調過浮水印但沒輸出就問一下
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final ok = await showConfirm(
      context,
      title: '放棄這張照片？',
      message: '浮水印還沒輸出，離開後設定會消失',
      action: '放棄離開',
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  // ===== 上一步（改壞了可以救；連續滑桿拖動 0.7 秒內併成一步）=====
  final List<String> _undoStack = [];
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _sync = 0; // 通知面板同步內部狀態

  /// 重做堆疊：只要有新的編輯就作廢（分支掉的未來留著只會搞混）
  final List<String> _redoStack = [];

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
    final wm = WatermarkSettings.fromJson(j);
    setState(() {
      _settings.text = wm.text;
      _settings.logo = wm.logo;
      _settings.animation = wm.animation;
      _settings.animSpeed = wm.animSpeed;
      _settings.animRange = wm.animRange;
      _grade.copyFrom(
        ColorGrade.fromJson(Map<String, dynamic>.from(j['color'] as Map)),
      );
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

  Future<void> _load() async {
    final bytes = await widget.photo.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    setState(() {
      _photoBytes = bytes;
      _aspect = frame.image.width / frame.image.height;
    });
    frame.image.dispose();
  }

  /// 預覽與面板之間的控制列：上一步／重做。
  /// 左邊刻意留白——尺寸那類數字對使用者不構成任何決定
  Widget _buildControlBar() {
    Widget btn(IconData icon, String tip, VoidCallback? onTap) {
      final on = onTap != null;
      return IconButton(
        tooltip: tip,
        icon: Icon(icon, size: 19, color: on ? kIcon : kBorder),
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(
          top: BorderSide(color: kBorder),
          bottom: BorderSide(color: kBorder),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          btn(Icons.undo, '上一步', _undoStack.isEmpty ? null : _undoLast),
          btn(Icons.redo, '重做', _redoStack.isEmpty ? null : _redoLast),
        ],
      ),
    );
  }

  /// 輸出前選格式——兩種格式差很多，使用者要知道差在哪。
  /// 點了格式就直接輸出（選擇即確認，不再多一層）
  Future<void> _confirmExport() async {
    if (_exporting) return;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('photo_export_fmt') ?? 'jpg';
    if (!mounted) return;
    final fmt = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: kBg,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: kBorder),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '輸出到相簿',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 14),
                _fmtTile(
                  context,
                  fmt: 'jpg',
                  title: "JPEG${last == 'jpg' ? '（上次用這個）' : ''}",
                  subtitle:
                      '檔案小很多（約 1/8），發社群、傳給別人用這個。'
                      '肉眼看不出跟 PNG 的差別',
                  icon: Icons.bolt,
                ),
                const SizedBox(height: 8),
                _fmtTile(
                  context,
                  fmt: 'png',
                  title: "PNG 無損${last == 'png' ? '（上次用這個）' : ''}",
                  subtitle:
                      '完全不壓縮，檔案很大（可能幾十 MB）。'
                      '之後還要再編修、或想典藏原稿再用',
                  icon: Icons.diamond_outlined,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (fmt == null || !mounted) return;
    await prefs.setString('photo_export_fmt', fmt);
    await _export(jpeg: fmt == 'jpg');
  }

  Widget _fmtTile(
    BuildContext context, {
    required String fmt,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return Material(
      color: Colors.black,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pop(context, fmt),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kClipBorder),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: kAmber),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: kTextDim,
                        height: 1.5,
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

  Future<void> _export({bool jpeg = false}) async {
    if (_exporting || _photoBytes == null) return;
    setState(() => _exporting = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        title: Text('輸出中…'),
        content: SizedBox(
          height: 48,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    String message;
    var ok = true;
    try {
      // 以原始解析度合成（合成永遠是無損 PNG，要 JPEG 才轉檔）
      var bytes = await WatermarkRenderer.renderPhotoComposite(
        _photoBytes!,
        _settings,
        grade: _grade,
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
        'markcut_${DateTime.now().millisecondsSinceEpoch}',
        ext: ext,
      );
      if (jpeg && ext == 'png') {
        message = '$message（此平台不支援 JPEG，已改用 PNG）';
      }
    } catch (e) {
      message = '輸出失敗：$e';
      ok = false;
    }
    if (ok) _saved = true; // 已輸出，離開不用再問

    if (mounted) {
      Navigator.of(context).pop();
      showHint(context, message, error: !ok);
    }
    setState(() => _exporting = false);
  }

  /// 底部「儲存範本」鈕要觸發面板裡的儲存流程
  final _panelKey = GlobalKey<WatermarkPanelState>();

  // ===== 預覽區雙指縮放（照片上的浮水印）=====
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
    _pvBaseText = _settings.text.sizeFrac;
    _pvBaseLogo = _settings.logo.sizeFrac;
    _pushUndo();
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    setState(() {
      final t = _settings.text;
      final hasText = t.enabled && t.text.trim().isNotEmpty;
      final hasLogo = _settings.logo.enabled;
      // 有選取就只動被選的那個（畫面上有白框）；
      // 都沒選而兩個都在，才一起動
      final doText = hasText && (_wmPart != WmPart.logo || !hasLogo);
      final doLogo = hasLogo && (_wmPart != WmPart.text || !hasText);
      if (doText) t.sizeFrac = (_pvBaseText * f).clamp(0.015, 0.8);
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
        appBar: AppBar(title: const Text('照片浮水印')),
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
                        // 點空白＝收鍵盤
                        onTap: () =>
                            FocusManager.instance.primaryFocus?.unfocus(),
                        child: Container(
                          color: Colors.black,
                          alignment: Alignment.center,
                          child: AspectRatio(
                            aspectRatio: _aspect!,
                            child: Stack(
                              fit: StackFit.expand,
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
                                WatermarkLayer(
                                  settings: _settings,
                                  onChanged: () => setState(() {}),
                                  onDragStart: _pushUndo,
                                  selectedPart: _wmPart,
                                  onSelectPart: (p) =>
                                      setState(() => _wmPart = p),
                                  panLocked: () => _pvPts.length >= 2,
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
                  Expanded(
                    flex: 4,
                    child: switch (_tab) {
                      1 => ColorGradePanel(
                        grade: _grade,
                        onChanged: () => setState(() {}),
                        onBeforeChange: _pushUndo,
                        onCompare: (on) => setState(() => _colorCompare = on),
                      ),
                      _ => WatermarkPanel(
                        key: _panelKey,
                        settings: _settings,
                        onChanged: () => setState(() {}),
                        onBeforeChange: _pushUndo,
                        syncVersion: _sync,
                        // 儲存範本跟著面板捲到最後面，不釘在底部
                        hideSaveButton: false,
                      ),
                    },
                  ),
                ],
              ),
        // 底部分頁：跟影片編輯同一套（浮水印／調色／輸出）
        bottomNavigationBar: _photoBytes == null
            ? null
            : Container(
                decoration: const BoxDecoration(
                  color: kBg,
                  border: Border(top: BorderSide(color: kBorder)),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      _tabBtn(0, Icons.branding_watermark, '浮水印'),
                      _tabBtn(1, Icons.tune, '調色'),
                      // 輸出是動作不是分頁。只有一種格式沒得選，
                      // 中間再插一個視窗只是多一次點擊
                      _tabBtn(
                        -1,
                        Icons.ios_share,
                        '輸出',
                        // 一定要給非 null，不然 ?? 會掉回分頁切換
                        onTap: _confirmExport,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// i < 0 代表這一格是動作（例如輸出），不是分頁
  Widget _tabBtn(int i, IconData icon, String label, {VoidCallback? onTap}) {
    final on = _tab == i;
    // 調色調過但現在不在那個分頁時，圖示留一點顏色提示
    final hint = i == 1 && !on && _grade.hasColor;
    return Expanded(
      child: InkWell(
        onTap:
            onTap ??
            () => setState(() {
              _tab = i;
              if (i != 1) _colorCompare = false;
            }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: on ? kAmber : (hint ? kSelect : kIcon),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: 0.3,
                  color: on ? kText : kTextDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
