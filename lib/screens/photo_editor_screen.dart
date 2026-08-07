import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/watermark_settings.dart';
import '../services/photo_saver.dart';
import '../theme.dart';
import '../services/watermark_renderer.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

class PhotoEditorScreen extends StatefulWidget {
  final XFile photo;
  final WatermarkSettings? initialWatermark;

  const PhotoEditorScreen(
      {super.key, required this.photo, this.initialWatermark});

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  late final WatermarkSettings _settings =
      widget.initialWatermark?.copy() ?? WatermarkSettings();
  Uint8List? _photoBytes;
  double? _aspect; // 照片長寬比
  bool _exporting = false;

  /// 進來時的設定快照＋是否已輸出，決定離開要不要問
  late String _initialJson;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _initialJson = jsonEncode(_settings.toJson());
    _load();
  }

  bool get _dirty =>
      !_saved && jsonEncode(_settings.toJson()) != _initialJson;

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

  void _pushUndo() {
    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < 700) return;
    _lastPush = now;
    _undoStack.add(jsonEncode(_settings.toJson()));
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    setState(() {}); // 讓上一步鈕亮起來
  }

  void _undoLast() {
    if (_undoStack.isEmpty) return;
    final wm = WatermarkSettings.fromJson(
        jsonDecode(_undoStack.removeLast()) as Map<String, dynamic>);
    setState(() {
      _settings.text = wm.text;
      _settings.logo = wm.logo;
      _settings.animation = wm.animation;
      _settings.animSpeed = wm.animSpeed;
      _settings.animRange = wm.animRange;
      _sync++;
    });
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

  Future<void> _export() async {
    if (_exporting || _photoBytes == null) return;
    setState(() => _exporting = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        title: Text('輸出中…'),
        content: SizedBox(
            height: 48, child: Center(child: CircularProgressIndicator())),
      ),
    );

    String message;
    var ok = true;
    try {
      // 以原始解析度合成，輸出 PNG 完全不壓畫質
      final png = await WatermarkRenderer.renderPhotoComposite(
          _photoBytes!, _settings);
      message = await savePhotoPng(
          png, 'markcut_${DateTime.now().millisecondsSinceEpoch}');
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
      if (t.enabled && t.text.trim().isNotEmpty) {
        t.sizeFrac = (_pvBaseText * f).clamp(0.015, 0.8);
      }
      if (_settings.logo.enabled) {
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
      appBar: AppBar(
        title: const Text('照片浮水印'),
        actions: [
          IconButton(
            tooltip: '上一步',
            icon: const Icon(Icons.undo),
            onPressed: _undoStack.isEmpty ? null : _undoLast,
          ),
        ],
      ),
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
                          Image.memory(_photoBytes!, fit: BoxFit.contain),
                          WatermarkLayer(
                            settings: _settings,
                            onChanged: () => setState(() {}),
                            onDragStart: _pushUndo,
                          ),
                        ],
                      ),
                    ),
                    ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: WatermarkPanel(
                    key: _panelKey,
                    settings: _settings,
                    onChanged: () => setState(() {}),
                    onBeforeChange: _pushUndo,
                    syncVersion: _sync,
                    // 儲存鈕移到底部跟「輸出」並排
                    hideSaveButton: true,
                  ),
                ),
                // 底部雙鍵：儲存範本（次要）＋輸出（主要）
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                _panelKey.currentState?.savePreset(),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(46),
                              side: const BorderSide(color: kClipBorder),
                              foregroundColor: kText,
                            ),
                            icon: const Icon(Icons.bookmark_add_outlined,
                                size: 17),
                            label: const Text('儲存範本',
                                style: TextStyle(fontSize: 13.5)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _exporting ? null : _export,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(46),
                            ),
                            icon: const Icon(Icons.ios_share, size: 17),
                            label: const Text('輸出',
                                style: TextStyle(fontSize: 13.5)),
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
}
