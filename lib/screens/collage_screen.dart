import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme.dart';
import '../widgets/swipe_back.dart';
import 'photo_editor_screen.dart';

/// 宮格拼圖：把多張照片拼成一張（2/4/6/9 宮格），
/// 拼完直接進照片編輯器上浮水印。
/// 版型固定 1:1 畫布、格子等分、照片置中裁滿（cover）；
/// 點兩個格子可以互換位置。
class CollageScreen extends StatefulWidget {
  final List<XFile> photos;

  const CollageScreen({super.key, required this.photos});

  @override
  State<CollageScreen> createState() => _CollageScreenState();
}

/// 版型：(格數, 欄數, 列數)
const _kLayouts = [(2, 2, 1), (4, 2, 2), (6, 2, 3), (9, 3, 3)];

class _CollageScreenState extends State<CollageScreen> {
  final List<Uint8List> _bytes = [];
  final List<ui.Image> _images = [];

  /// 目前版型（_kLayouts 的 index）；-1 = 還在載入
  int _layout = -1;

  /// 每個格子放哪張照片（照片 index，照選取順序）
  List<int> _order = [];

  /// 互換模式：先點的那個格子（-1 = 沒有）
  int _swapFrom = -1;

  bool _building = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final img in _images) {
      img.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    for (final f in widget.photos) {
      try {
        final b = await f.readAsBytes();
        final codec = await ui.instantiateImageCodec(b);
        final frame = await codec.getNextFrame();
        _bytes.add(b);
        _images.add(frame.image);
      } catch (_) {}
      if (_images.length >= 9) break; // 最多九宮格
    }
    if (!mounted) return;
    if (_images.length < 2) {
      showHint(context, '至少要兩張讀得出來的照片', error: true);
      Navigator.pop(context);
      return;
    }
    // 預設挑「放得下最多張」的版型
    var pick = 0;
    for (var i = 0; i < _kLayouts.length; i++) {
      if (_images.length >= _kLayouts[i].$1) pick = i;
    }
    setState(() {
      _layout = pick;
      _order = List.generate(_kLayouts[pick].$1, (i) => i % _images.length);
    });
  }

  void _setLayout(int i) {
    setState(() {
      _layout = i;
      _swapFrom = -1;
      _order = List.generate(_kLayouts[i].$1, (n) => n % _images.length);
    });
  }

  void _tapCell(int cell) {
    setState(() {
      if (_swapFrom == -1) {
        _swapFrom = cell;
      } else if (_swapFrom == cell) {
        _swapFrom = -1;
      } else {
        final t = _order[_swapFrom];
        _order[_swapFrom] = _order[cell];
        _order[cell] = t;
        _swapFrom = -1;
      }
    });
  }

  /// 合成一張 2048×2048 的拼圖，交給照片編輯器
  Future<void> _done() async {
    if (_building) return;
    setState(() => _building = true);
    try {
      const size = 2048.0;
      final (count, cols, rows) = _kLayouts[_layout];
      final cw = size / cols;
      final ch = size / rows;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      for (var i = 0; i < count; i++) {
        final img = _images[_order[i]];
        final dst = ui.Rect.fromLTWH(
          (i % cols) * cw,
          (i ~/ cols) * ch,
          cw,
          ch,
        );
        // cover：等比放大到蓋滿格子，超出的置中裁掉
        final scale =
            (cw / img.width) > (ch / img.height)
            ? cw / img.width
            : ch / img.height;
        final sw = cw / scale;
        final sh = ch / scale;
        final src = ui.Rect.fromLTWH(
          (img.width - sw) / 2,
          (img.height - sh) / 2,
          sw,
          sh,
        );
        canvas.drawImageRect(
          img,
          src,
          dst,
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
      }
      final image = await rec.endRecording().toImage(
        size.toInt(),
        size.toInt(),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || data == null) return;
      final file = XFile.fromData(
        data.buffer.asUint8List(),
        name: 'collage.png',
        mimeType: 'image/png',
      );
      // 直接換頁進編輯器：返回時回首頁，不會卡在拼圖頁
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => PhotoEditorScreen(photo: file)),
      );
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  Widget _layoutChip(int i) {
    final (count, _, _) = _kLayouts[i];
    final enabled = _images.length >= count || count == _kLayouts[0].$1;
    final on = _layout == i;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? () => _setLayout(i) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? kSelect.withValues(alpha: 0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: on ? kSelect : kBorder,
                width: on ? 1.5 : 1,
              ),
            ),
            child: Text(
              '$count 宮格',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                color: !enabled
                    ? kBorder
                    : (on ? kSelect : kText),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg, title: const Text('宮格拼圖')),
        body: _layout == -1
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: _buildGrid(),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(
                        children: [
                          for (var i = 0; i < _kLayouts.length; i++)
                            _layoutChip(i),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '點兩個格子可以互換位置',
                        style: TextStyle(fontSize: 11, color: kTextDim),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _building ? null : _done,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              _building ? '合成中…' : '完成，上浮水印',
                              style: const TextStyle(fontSize: 15),
                            ),
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

  Widget _buildGrid() {
    final (count, cols, rows) = _kLayouts[_layout];
    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Expanded(
            child: Row(
              children: [
                for (var c = 0; c < cols; c++)
                  Expanded(child: _cell(r * cols + c)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(int i) {
    final selected = _swapFrom == i;
    return GestureDetector(
      onTap: () => _tapCell(i),
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          border: selected ? Border.all(color: kSelect, width: 2) : null,
        ),
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _images[_order[i]].width.toDouble(),
              height: _images[_order[i]].height.toDouble(),
              child: Image.memory(_bytes[_order[i]], gaplessPlayback: true),
            ),
          ),
        ),
      ),
    );
  }
}
