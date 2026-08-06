import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import '../services/photo_saver.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../services/watermark_renderer.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';
import 'photo_editor_screen.dart';
import 'video_editor_screen.dart';

/// 批次浮水印：一次選多個檔案（照片/影片混合），
/// 統一調一組浮水印，整批匯出到相簿
class BatchWatermarkScreen extends StatefulWidget {
  final List<XFile> files;

  const BatchWatermarkScreen({super.key, required this.files});

  @override
  State<BatchWatermarkScreen> createState() => _BatchWatermarkScreenState();
}

/// 批次清單裡的一個檔案（縮圖與尺寸載入後補上）
class _BatchItem {
  final XFile file;
  Uint8List? thumb;
  (int, int)? dims;
  Uint8List? photoBytes;
  _BatchItem(this.file);
}

class _BatchWatermarkScreenState extends State<BatchWatermarkScreen> {
  final _settings = WatermarkSettings();
  int _previewIndex = 0;

  late final List<_BatchItem> _items =
      widget.files.map(_BatchItem.new).toList();

  bool _exporting = false;
  bool _stopRequested = false;

  bool _isVideo(XFile f) {
    final mime = f.mimeType;
    if (mime != null && mime.isNotEmpty) return mime.startsWith('video/');
    final ext = f.name.toLowerCase().split('.').last;
    return const {
      'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts', 'mts'
    }.contains(ext);
  }

  /// 進來時的設定快照＋是否已匯出，決定離開要不要問
  late String _initialJson;
  bool _exported = false;

  @override
  void initState() {
    super.initState();
    _initialJson = jsonEncode(_settings.toJson());
    _loadPreviews();
  }

  bool get _dirty =>
      !_exported && jsonEncode(_settings.toJson()) != _initialJson;

  /// 離開保護：調過浮水印但整批還沒匯出就問一下
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final ok = await showConfirm(
      context,
      title: '放棄這批檔案？',
      message: '還沒匯出，離開後浮水印設定會消失',
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

  Future<void> _loadPreviews() async {
    for (final item in _items) {
      final f = item.file;
      try {
        if (_isVideo(f)) {
          // 720p 高清格：預覽不會糊
          final t =
              await engine.makeThumbnails(f.path, 1, 1, height: 720);
          if (t.isNotEmpty) {
            item.thumb = t.first;
            final codec = await ui.instantiateImageCodec(t.first);
            final frame = await codec.getNextFrame();
            item.dims = (frame.image.width, frame.image.height);
            frame.image.dispose();
          }
        } else {
          final bytes = await f.readAsBytes();
          item.photoBytes = bytes;
          item.thumb = bytes;
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          item.dims = (frame.image.width, frame.image.height);
          frame.image.dispose();
        }
      } catch (_) {}
      if (mounted) setState(() {});
    }
  }

  /// 把目前選中的檔案丟進完整編輯器（帶著現在的浮水印設定）
  Future<void> _editCurrentAlone() async {
    final item = _items[_previewIndex];
    if (_isVideo(item.file)) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoEditorScreen(
            videoPath: item.file.path,
            initialWatermark: _settings.copy(),
          ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoEditorScreen(
            photo: item.file,
            initialWatermark: _settings.copy(),
          ),
        ),
      );
    }
  }

  /// 長按縮圖＝從批次移除（要單獨處理的先踢出去）
  void _removeItem(int i) {
    if (_items.length <= 1) return;
    setState(() {
      _items.removeAt(i);
      if (_previewIndex >= _items.length) {
        _previewIndex = _items.length - 1;
      }
    });
  }

  // ===== 批次匯出 =====

  Future<void> _exportAll() async {
    if (_exporting) return;
    final hasVideo = _items.any((it) => _isVideo(it.file));
    if (hasVideo && !engine.videoExportSupported) {
      showHint(context, 'Web 版不支援影片匯出，只會處理照片');
    }
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
                builder: (context, v, _) =>
                    LinearProgressIndicator(value: v),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: label,
                builder: (context, s, _) => Text(s,
                    style: const TextStyle(
                        fontSize: 12, color: kTextDim)),
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

    var done = 0;
    var failed = 0;
    for (var i = 0; i < _items.length; i++) {
      if (_stopRequested) break;
      final item = _items[i];
      final f = item.file;
      label.value = '第 ${i + 1} / $total 個：${f.name}';
      try {
        if (_isVideo(f)) {
          if (!engine.videoExportSupported) continue;
          final ok = await _exportVideo(f, (p) {
            overall.value = (i + p) / total;
          });
          ok ? done++ : failed++;
        } else {
          final bytes = item.photoBytes ?? await f.readAsBytes();
          final png = await WatermarkRenderer.renderPhotoComposite(
              bytes, _settings);
          await savePhotoPng(png,
              'markcut_${DateTime.now().millisecondsSinceEpoch}_$i');
          done++;
        }
      } catch (_) {
        failed++;
      }
      overall.value = (i + 1) / total;
    }

    if (done > 0) _exported = true; // 有輸出成功，離開不用再問
    if (mounted) {
      Navigator.of(context).pop();
      final msg = _stopRequested
          ? '已取消，完成 $done 個'
          : (failed == 0 ? '完成！已輸出 $done 個檔案' : '完成 $done 個，$failed 個失敗');
      showHint(context, msg, error: failed > 0 && !_stopRequested);
    }
    setState(() => _exporting = false);
  }

  /// 單支影片：原樣 + 浮水印，整段匯出
  Future<bool> _exportVideo(
      XFile f, void Function(double) onProgress) async {
    final c = makeVideoController(f.path);
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

    Uint8List? wmPng;
    if (_settings.hasAnyMark) {
      wmPng = await WatermarkRenderer.renderOverlayPng(_settings, w, h);
    }
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
        outW: w,
        outH: h,
        wmAnimation: _settings.animation,
        wmSpeed: _settings.animSpeed,
        wmRange: _settings.animRange,
      ),
      onProgress: onProgress,
    );
    return result.ok;
  }

  // ===== 畫面 =====

  @override
  Widget build(BuildContext context) {
    final dims = _items[_previewIndex].dims;
    final aspect =
        dims == null ? 16 / 9 : dims.$1 / (dims.$2 == 0 ? 1 : dims.$2);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text('批次浮水印（${_items.length}）'),
        actions: [
          IconButton(
            tooltip: '上一步',
            icon: const Icon(Icons.undo),
            onPressed: _undoStack.isEmpty ? null : _undoLast,
          ),
          // 這個檔案要剪時間軸/單獨調 → 丟進完整編輯器（帶目前浮水印）
          TextButton.icon(
            onPressed: _editCurrentAlone,
            icon: const Icon(Icons.tune, size: 16, color: kIcon),
            label: const Text('單獨編輯',
                style: TextStyle(fontSize: 12.5, color: kText)),
          ),
        ],
      ),
      body: Column(
        children: [
          // 預覽：目前選中的檔案縮圖 + 浮水印圖層
          Expanded(
            flex: 4,
            child: Container(
              color: const Color(0xFF1B1B1F),
              child: Center(
                // 換檔案時整個預覽子樹重建，浮水印圖層不會殘留舊狀態
                child: KeyedSubtree(
                  key: ValueKey(_previewIndex),
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: Container(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_items[_previewIndex].thumb != null)
                            Image.memory(_items[_previewIndex].thumb!,
                                fit: BoxFit.contain),
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
          ),
          // 檔案縮圖列：點了切換預覽、長按從批次移除
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              itemCount: _items.length,
              separatorBuilder: (_, i) => const SizedBox(width: 6),
              itemBuilder: (context, i) => InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _previewIndex = i),
                onLongPress: () {
                  _removeItem(i);
                  showHint(context, '已從批次移除');
                },
                child: Container(
                  width: 56,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: kPanelHi,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: i == _previewIndex ? kSelect : kBorder,
                      width: i == _previewIndex ? 1.5 : 1,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_items[i].thumb != null)
                        Image.memory(_items[i].thumb!,
                            fit: BoxFit.cover, gaplessPlayback: true),
                      if (_isVideo(_items[i].file))
                        const Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.videocam,
                                size: 11, color: Colors.white70),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(height: 1, color: kBorder),
          // 浮水印設定面板（跟編輯器同一套）；
          // 底部疊一段漸層淡出，內容是淡出去、不是被底欄硬切
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                WatermarkPanel(
                  settings: _settings,
                  onChanged: () => setState(() {}),
                  onBeforeChange: _pushUndo,
                  syncVersion: _sync,
                  // 有影片才顯示動畫選項
                  showAnimation:
                      _items.any((it) => _isVideo(it.file)),
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
                          colors: [
                            kBg.withValues(alpha: 0),
                            kBg,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 薄型底欄：左側檔案數小字、右側緊湊匯出鍵
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _exporting ? null : _exportAll,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 9),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                  icon: const Icon(Icons.ios_share, size: 16),
                  label: const Text('全部匯出',
                      style: TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
