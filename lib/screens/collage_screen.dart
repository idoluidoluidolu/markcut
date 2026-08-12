import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme.dart';
import '../widgets/swipe_back.dart';
import 'photo_editor_screen.dart';

/// 宮格拼圖：把多張照片拼成一張（2/4/6/9 宮格），
/// 拼完直接進照片編輯器上浮水印。
/// 版型固定 1:1 畫布、格子等分、照片置中裁滿（cover）；
/// 拖曳格子互換位置、點一下選取後可調構圖、長按換照片，
/// 也能開格線（調間距、選顏色）。
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

  /// 選取中的格子（-1 = 沒有）：選中後可拖曳移動、雙指縮放調整構圖
  int _selCell = -1;

  /// 每格的取景（縮放倍率＋來源像素平移）
  List<_CellFit> _fits = [];

  // 雙指縮放
  final Map<int, Offset> _pts = {};
  double? _baseDist;
  double _baseZoom = 1;

  // 拖曳互換：從哪格拖起、目前指尖（宮格座標）、懸在哪格上
  int _dragFrom = -1;
  Offset? _dragPos;
  int _dragOver = -1;

  // 這一幀宮格的幾何（拖曳換算目標格用）
  double _gG = 0, _gCw = 1, _gCh = 1;

  /// 格線：開了之後格子間（含外框）會留縫、填格線顏色
  bool _lines = false;

  /// 間距（畫布邊長的比例），格線開啟時才作用
  double _gapN = 0.012;

  /// 格線顏色（ARGB）
  int _lineColor = 0xFFFFFFFF;

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
      _fits = List.generate(_kLayouts[pick].$1, (_) => _CellFit());
    });
  }

  void _setLayout(int i) {
    setState(() {
      _layout = i;
      _selCell = -1;
      _order = List.generate(_kLayouts[i].$1, (n) => n % _images.length);
      _fits = List.generate(_kLayouts[i].$1, (_) => _CellFit());
    });
  }

  /// 點格子＝選取（可調整）；再點同一格取消
  void _tapCell(int cell) {
    setState(() => _selCell = _selCell == cell ? -1 : cell);
  }

  /// 長按格子＝換一張照片（重新從相簿挑）
  Future<void> _longPressCell(int cell) async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (f == null || !mounted) return;
    try {
      final b = await f.readAsBytes();
      final codec = await ui.instantiateImageCodec(b);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _bytes.add(b);
        _images.add(frame.image);
        _order[cell] = _images.length - 1;
        _fits[cell] = _CellFit();
        _selCell = cell;
      });
    } catch (_) {
      if (mounted) showHint(context, '這張照片讀不出來', error: true);
    }
  }

  /// 拖曳互換：由宮格座標算出落在哪一格（-1 = 界外）
  int _cellAt(Offset p) {
    final (count, cols, rows) = _kLayouts[_layout];
    final c = ((p.dx - _gG) / (_gCw + _gG)).floor();
    final r = ((p.dy - _gG) / (_gCh + _gG)).floor();
    if (c < 0 || c >= cols || r < 0 || r >= rows) return -1;
    final i = r * cols + c;
    return i < count ? i : -1;
  }

  /// 放開＝落在別格就互換（照片跟取景一起換）
  void _endDrag() {
    final from = _dragFrom;
    final to = _dragPos == null ? -1 : _cellAt(_dragPos!);
    setState(() {
      if (from != -1 && to != -1 && to != from) {
        final t = _order[from];
        _order[from] = _order[to];
        _order[to] = t;
        final f = _fits[from];
        _fits[from] = _fits[to];
        _fits[to] = f;
      }
      _dragFrom = -1;
      _dragPos = null;
      _dragOver = -1;
    });
  }

  /// 這一格目前的取景窗（來源圖片座標）。cover 基準：
  /// zoom=1 剛好蓋滿格子，只能再放大；平移夾在圖片範圍內。
  /// 預覽跟合成都用這個算，所見即所得
  ui.Rect _srcRect(ui.Image img, _CellFit f, double cellAspect) {
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    double sw, sh;
    if (iw / ih > cellAspect) {
      sh = ih / f.zoom;
      sw = sh * cellAspect;
    } else {
      sw = iw / f.zoom;
      sh = sw / cellAspect;
    }
    var cx = (iw - sw) / 2 + f.panX;
    var cy = (ih - sh) / 2 + f.panY;
    cx = cx.clamp(0.0, iw - sw);
    cy = cy.clamp(0.0, ih - sh);
    return ui.Rect.fromLTWH(cx, cy, sw, sh);
  }

  /// 合成一張 2048×2048 的拼圖，交給照片編輯器
  Future<void> _done() async {
    if (_building) return;
    setState(() => _building = true);
    try {
      const size = 2048.0;
      final (count, cols, rows) = _kLayouts[_layout];
      // 跟預覽同一套排法：格線開啟時格子間（含外框）留縫
      final g = _lines ? _gapN * size : 0.0;
      final cw = (size - g * (cols + 1)) / cols;
      final ch = (size - g * (rows + 1)) / rows;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      if (_lines) {
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, size, size),
          ui.Paint()..color = ui.Color(_lineColor),
        );
      }
      for (var i = 0; i < count; i++) {
        final img = _images[_order[i]];
        final dst = ui.Rect.fromLTWH(
          g + (i % cols) * (cw + g),
          g + (i ~/ cols) * (ch + g),
          cw,
          ch,
        );
        canvas.drawImageRect(
          img,
          _srcRect(img, _fits[i], cw / ch),
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

  Widget _lineSwatch(int c) {
    final on = _lineColor == c;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _lineColor = c),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Color(c),
            shape: BoxShape.circle,
            border: Border.all(
              color: on ? kSelect : kBorder,
              width: on ? 2 : 1,
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
        appBar: AppBar(backgroundColor: kBg, title: const Text('照片拼圖')),
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
                    // 格線開關＋顏色；開了才有間距可調
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                      child: Row(
                        children: [
                          const Text(
                            '格線',
                            style: TextStyle(fontSize: 12.5, color: kText),
                          ),
                          const SizedBox(width: 4),
                          Switch(
                            value: _lines,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) => setState(() => _lines = v),
                          ),
                          if (_lines) ...[
                            const SizedBox(width: 8),
                            for (final c in const [
                              0xFFFFFFFF,
                              0xFF000000,
                              0xFF9E9EA6,
                              0xFFFFC24B,
                              0xFFE57373,
                              0xFF64B5F6,
                            ])
                              _lineSwatch(c),
                          ],
                        ],
                      ),
                    ),
                    if (_lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            const Text(
                              '間距',
                              style: TextStyle(fontSize: 12.5, color: kTextDim),
                            ),
                            Expanded(
                              child: Slider(
                                value: _gapN,
                                min: 0.002,
                                max: 0.05,
                                onChanged: (v) => setState(() => _gapN = v),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '拖曳格子互換位置；點一下選取可調構圖；長按換照片',
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
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.maxWidth; // 1:1 畫布
        final g = _lines ? _gapN * size : 0.0;
        final cw = (size - g * (cols + 1)) / cols;
        final ch = (size - g * (rows + 1)) / rows;
        _gG = g;
        _gCw = cw;
        _gCh = ch;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: _lines ? Color(_lineColor) : Colors.transparent,
              ),
            ),
            for (var i = 0; i < count; i++)
              Positioned(
                left: g + (i % cols) * (cw + g),
                top: g + (i ~/ cols) * (ch + g),
                width: cw,
                height: ch,
                child: _cell(i, cw, ch),
              ),
            // 拖曳互換中：浮起的縮圖跟著指尖走
            if (_dragFrom != -1 && _dragPos != null)
              Positioned(
                left: _dragPos!.dx - cw * 0.3,
                top: _dragPos!.dy - ch * 0.3,
                width: cw * 0.6,
                height: ch * 0.6,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.85,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: kSelect, width: 2),
                      ),
                      child: ClipRect(
                        child: CustomPaint(
                          painter: _CellPainter(
                            img: _images[_order[_dragFrom]],
                            src: _srcRect(
                              _images[_order[_dragFrom]],
                              _fits[_dragFrom],
                              cw / ch,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _cell(int i, double cellW, double cellH) {
    final selected = _selCell == i;
    final img = _images[_order[i]];
    final fit = _fits[i];
    // 這格在宮格座標裡的左上角（拖曳換算指尖位置用）
    final origin = Offset(
      _gG + (i % _kLayouts[_layout].$2) * (_gCw + _gG),
      _gG + (i ~/ _kLayouts[_layout].$2) * (_gCh + _gG),
    );
    // 螢幕位移 → 來源像素位移的換算比
    double dispScale() => cellW / _srcRect(img, fit, cellW / cellH).width;
    return Listener(
      // 雙指縮放（選取中才作用）
      onPointerDown: (e) {
        _pts[e.pointer] = e.position;
        if (selected && _pts.length == 2) {
          final p = _pts.values.toList();
          _baseDist = (p[0] - p[1]).distance;
          _baseZoom = fit.zoom;
        }
      },
      onPointerMove: (e) {
        if (!_pts.containsKey(e.pointer)) return;
        _pts[e.pointer] = e.position;
        if (selected && _baseDist != null && _pts.length >= 2) {
          final p = _pts.values.toList();
          final f = (p[0] - p[1]).distance / _baseDist!;
          setState(() => fit.zoom = (_baseZoom * f).clamp(1.0, 4.0));
        }
      },
      onPointerUp: (e) {
        _pts.remove(e.pointer);
        if (_pts.length < 2) _baseDist = null;
      },
      onPointerCancel: (e) {
        _pts.remove(e.pointer);
        if (_pts.length < 2) _baseDist = null;
      },
      // 桌面：滾輪縮放選取中的格子
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent || !selected) return;
        setState(() {
          fit.zoom = (fit.zoom * (e.scrollDelta.dy > 0 ? 1 / 1.07 : 1.07))
              .clamp(1.0, 4.0);
        });
      },
      child: GestureDetector(
        onTap: () => _tapCell(i),
        onLongPress: () => _longPressCell(i),
        // 選取中單指拖曳＝移動構圖；沒選取＝拖起來跟別格互換
        onPanStart: selected
            ? null
            : (d) => setState(() {
                _dragFrom = i;
                _dragPos = origin + d.localPosition;
                _dragOver = i;
              }),
        onPanUpdate: (d) {
          if (_pts.length >= 2) return;
          if (selected) {
            final k = dispScale();
            setState(() {
              fit.panX -= d.delta.dx / k;
              fit.panY -= d.delta.dy / k;
            });
          } else if (_dragFrom == i) {
            setState(() {
              _dragPos = origin + d.localPosition;
              _dragOver = _cellAt(_dragPos!);
            });
          }
        },
        onPanEnd: selected ? null : (_) => _endDrag(),
        onPanCancel: selected
            ? null
            : () => setState(() {
                _dragFrom = -1;
                _dragPos = null;
                _dragOver = -1;
              }),
        child: Container(
          foregroundDecoration: selected
              ? BoxDecoration(border: Border.all(color: kSelect, width: 2))
              : (_dragFrom != -1 && _dragOver == i && _dragFrom != i)
              ? BoxDecoration(
                  border: Border.all(color: kSelect, width: 2.5),
                  color: kSelect.withValues(alpha: 0.15),
                )
              : null,
          child: ClipRect(
            child: CustomPaint(
              size: Size(cellW, cellH),
              painter: _CellPainter(
                img: img,
                src: _srcRect(img, fit, cellW / cellH),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 每格的取景：cover 基準的縮放倍率（≥1）＋來源像素平移
class _CellFit {
  double zoom = 1;
  double panX = 0;
  double panY = 0;
}

/// 依取景窗畫出這一格的照片
class _CellPainter extends CustomPainter {
  final ui.Image img;
  final ui.Rect src;

  const _CellPainter({required this.img, required this.src});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      img,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CellPainter old) => old.img != img || old.src != src;
}
