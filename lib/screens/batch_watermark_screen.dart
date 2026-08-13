import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import '../services/photo_saver.dart';
import '../services/screen_awake.dart';
import '../services/video_controller.dart';
import '../services/video_engine.dart' as engine;
import '../services/video_processor.dart';
import '../services/watermark_renderer.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

/// 批次浮水印：一次選多個檔案（照片/影片混合），
/// 統一調一組浮水印，整批匯出到相簿
class BatchWatermarkScreen extends StatefulWidget {
  final List<XFile> files;

  /// 進場時要顯示的提示（例如「已略過 N 個非影片檔案」）。
  /// 在前一頁 show 的話會被這頁蓋住，根本看不到
  final String? initialHint;

  const BatchWatermarkScreen({super.key, required this.files, this.initialHint});

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

  /// 單張模式：這張有自己的浮水印設定（在預覽上調過就會建立），
  /// null＝跟著整批的設定走
  WatermarkSettings? override;
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

  /// 「有沒有改過」的基準快照：進來時拍一次，匯出成功後重設
  late String _initialJson;

  @override
  void initState() {
    super.initState();
    _initialJson = jsonEncode(_settings.toJson());
    _loadPreviews();
    _loadPreviewFull();
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
      _items.any((it) => it.override != null);

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
  final List<_UndoStep> _undoStack = [];
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _sync = 0; // 通知面板同步內部狀態

  void _pushUndo() {
    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < 700) return;
    _lastPush = now;
    // 連同「這一步是改哪一份設定」一起記：單張模式的上一步要還原到
    // 那一張的 override，還原到共用設定的話畫面完全沒反應
    final target = _items[_previewIndex].override != null ? _previewIndex : -1;
    _undoStack.add(
      _UndoStep(target, jsonEncode(_effectiveOf(_previewIndex).toJson())),
    );
    if (_undoStack.length > 60) _undoStack.removeAt(0);
    setState(() {}); // 讓上一步鈕亮起來
  }

  void _undoLast() {
    if (_undoStack.isEmpty) return;
    final step = _undoStack.removeLast();
    final wm = WatermarkSettings.fromJson(
        jsonDecode(step.json) as Map<String, dynamic>);
    // 那張後來被移除的話就跳過這一步
    if (step.itemIndex >= _items.length) return;
    final dst = step.itemIndex < 0
        ? _settings
        : (_items[step.itemIndex].override ??= _settings.copy());
    setState(() {
      if (step.itemIndex >= 0) _previewIndex = step.itemIndex;
      dst.text = wm.text;
      dst.logo = wm.logo;
      dst.animation = wm.animation;
      dst.animSpeed = wm.animSpeed;
      dst.animRange = wm.animRange;
      _sync++;
    });
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
      return null;
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
      final png =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return png?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      desc?.dispose();
      buf?.dispose();
    }
  }

  /// 一次把每個檔案的小縮圖備好；原檔讀完就丟。
  /// 迭代快照，不直接迭代 _items——載入中長按移除一張會讓
  /// 迭代器丟 ConcurrentModificationError，剩下的縮圖全載不出來
  Future<void> _loadPreviews() async {
    final snapshot = List.of(_items);
    for (final item in snapshot) {
      if (!mounted) return;
      if (!_items.contains(item)) continue; // 中途被移除就跳過
      final f = item.file;
      try {
        if (_isVideo(f)) {
          // 條列用的小格，抽小的就好（大預覽另外抽 720p）
          final t = await engine.makeThumbnails(f.path, 1, 1, height: 240);
          if (t.isNotEmpty) {
            item.thumb = t.first;
            item.dims = await _dimsOf(t.first);
          }
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
        final t = await engine.makeThumbnails(f.path, 1, 1, height: 720);
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

  /// 在預覽上動手＝這張進入「單張模式」：
  /// 把目前生效的設定複製成這張自己的，之後怎麼調都不影響其他張
  void _ensureOverride() {
    final item = _items[_previewIndex];
    if (item.override != null) return;
    item.override = _settings.copy();
    setState(() => _sync++); // 面板換綁到 override，內部狀態要重新同步
    showHint(context, '已切換為單張調整，只影響這一張');
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
    _pushUndo();
    _ensureOverride(); // 捏合＝這張進入單張模式
    final eff = _effectiveOf(_previewIndex);
    _pvBaseText = eff.text.sizeFrac;
    _pvBaseLogo = eff.logo.sizeFrac;
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    setState(() {
      final eff = _effectiveOf(_previewIndex);
      final t = eff.text;
      if (t.enabled && t.text.trim().isNotEmpty) {
        t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
      }
      if (eff.logo.enabled) {
        eff.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
      }
    });
  }

  void _pinchUp(int pointer) {
    _pvPts.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) _pvBaseDist = null;
  }

  // ===== 批次匯出 =====

  Future<void> _exportAll() async {
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

    // 整批跑很久，螢幕一關系統就可能凍結或回收 App，匯出會斷在中間
    await keepScreenAwake(true);

    var done = 0;
    var failed = 0;
    var skipped = 0;
    for (var i = 0; i < _items.length; i++) {
      if (_stopRequested) break;
      final item = _items[i];
      final f = item.file;
      label.value = '第 ${i + 1} / $total 個：${f.name}';
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
          final png = await WatermarkRenderer.renderPhotoComposite(
              bytes, _effectiveOf(i));
          await savePhotoPng(png,
              'watermarker_${DateTime.now().millisecondsSinceEpoch}_$i');
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
        : (failed == 0 ? '完成！已輸出 $done 個檔案' : '完成 $done 個，$failed 個失敗');
    if (skipped > 0) msg += '（$skipped 部影片略過：此平台不支援）';
    setState(() => _exporting = false);
    // 全部成功才問下一步；有失敗或略過就用提示講清楚，
    // 這種時候把人送回主畫面等於把問題蓋掉
    if (_stopRequested || failed > 0 || skipped > 0) {
      showHint(context, msg,
          error: (failed > 0 || skipped > 0) && !_stopRequested);
      return;
    }
    final home = await askAfterExport(context, msg);
    // _initialJson 上面已經對齊現況，離開不會再問「要放棄嗎」
    if (home && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// 單支影片：原樣 + 浮水印，整段匯出
  Future<bool> _exportVideo(
      XFile f,
      WatermarkSettings wm,
      void Function(double) onProgress) async {
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
    if (wm.hasAnyMark) {
      wmPng = await WatermarkRenderer.renderOverlayPng(wm, w, h);
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
        wmAnimation: wm.animation,
        wmSpeed: wm.animSpeed,
        wmRange: wm.animRange,
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
        ],
      ),
      body: Column(
        children: [
          // 預覽：目前選中的檔案縮圖 + 浮水印圖層
          Expanded(
            flex: 4,
            child: Listener(
              // 雙指縮放浮水印（跟照片編輯同一套，用 Listener 不搶單指拖曳）
              onPointerDown: _pinchDown,
              onPointerMove: _pinchMove,
              onPointerUp: (e) => _pinchUp(e.pointer),
              onPointerCancel: (e) => _pinchUp(e.pointer),
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
                          // 大圖還在讀的時候先用小縮圖頂著，不要閃黑
                          if (_previewBytes != null)
                            Image.memory(_previewBytes!,
                                fit: BoxFit.contain,
                                cacheWidth: 1280,
                                gaplessPlayback: true)
                          else if (_items[_previewIndex].thumb != null)
                            Image.memory(_items[_previewIndex].thumb!,
                                fit: BoxFit.contain),
                          WatermarkLayer(
                            settings: _effectiveOf(_previewIndex),
                            onChanged: () => setState(() {}),
                            // 在預覽上拖＝這張進入單張模式。
                            // 先切模式再拍快照，上一步才會還原到這張自己的設定
                            onDragStart: () {
                              _ensureOverride();
                              _pushUndo();
                            },
                            panLocked: () => _pvPts.length >= 2,
                          ),
                        ],
                      ),
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
                onTap: () => _selectPreview(i),
                onLongPress: () async {
                  HapticFeedback.mediumImpact(); // 長按成立的觸覺回饋
                  final hasOverride = _items[i].override != null;
                  final action = await showModalBottomSheet<String>(
                    context: context,
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
                    showHint(this.context, '批次至少要留一個檔案', error: true);
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
                            fit: BoxFit.cover,
                            cacheWidth: _thumbLongSide,
                            gaplessPlayback: true),
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
                  // 綁「這張實際生效的設定」：單張模式下要改的是那張的
                  // override，綁 _settings 的話面板改了預覽不動、
                  // 其他張反而被改到
                  settings: _effectiveOf(_previewIndex),
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
