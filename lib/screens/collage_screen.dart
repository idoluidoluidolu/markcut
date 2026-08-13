import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';

import '../theme.dart';
import 'photo_editor_screen.dart';

/// 宮格拼圖：把多張照片拼成一張（2/4/6/9 宮格），
/// 拼完直接進照片編輯器上浮水印。
/// 版型固定 1:1 畫布、格子等分、照片置中裁滿（cover）；
/// 拖曳格子互換位置、點一下鎖定後可調構圖（右上角鈕換照片），
/// 也能開純格線（調線寬、選顏色）。
class CollageScreen extends StatefulWidget {
  final List<XFile> photos;

  const CollageScreen({super.key, required this.photos});

  @override
  State<CollageScreen> createState() => _CollageScreenState();
}

/// 單邊上限：再多的話手機上每格會小於觸控目標（約 48dp），
/// 點選、拖曳互換、雙指縮放都會變得很難按
const _kMaxSide = 6;

/// 總格數上限：輸出畫布放大到 2400 時每格仍有 400px
const _kMaxCells = 30;

/// 解碼後的長邊上限。不縮的話一張 4000x3000 的照片解開就是 48MB，
/// 放滿 30 格會直接被系統殺掉；縮到這裡每張約 7.7MB，
/// 而輸出畫布最多 2400、單格最多幾百 px，畫質綽綽有餘
const _kDecodeLongSide = 1600;

class _CollageScreenState extends State<CollageScreen> {
  /// 已解碼的照片。換掉之後不再被任何格子用到的會被釋放並留 null，
  /// 索引保持穩定（_order 存的是這裡的索引）
  final List<ui.Image?> _images = [];

  /// 一開始選進來的那批數量：換版型時還會用到，不能釋放
  int _poolSize = 0;

  /// 宮格的欄與列（0 = 還在載入）
  int _cols = 0;
  int _rows = 0;

  int get _cellCount => _cols * _rows;

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

  /// 格線：開了之後在格子交界疊上細線（純線條，不填背景）
  bool _lines = false;

  /// 線寬（畫布邊長的比例），格線開啟時才作用
  double _gapN = 0.008;

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
      img?.dispose();
    }
    super.dispose();
  }

  /// 解碼並把長邊縮到 [_kDecodeLongSide]。
  /// 先用 ImageDescriptor 讀出原圖尺寸（不解碼像素），才知道該縮哪一邊——
  /// 只指定 targetWidth 的話，直式照片反而會被放大
  Future<ui.Image> _decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buffer);
    final long = math.max(desc.width, desc.height);
    ui.Codec codec;
    if (long > _kDecodeLongSide) {
      final k = _kDecodeLongSide / long;
      codec = await desc.instantiateCodec(
        targetWidth: math.max(1, (desc.width * k).round()),
        targetHeight: math.max(1, (desc.height * k).round()),
      );
    } else {
      codec = await desc.instantiateCodec(); // 本來就小，不放大
    }
    final frame = await codec.getNextFrame();
    codec.dispose();
    desc.dispose();
    return frame.image;
  }

  Future<void> _load() async {
    for (final f in widget.photos) {
      try {
        final img = await _decode(await f.readAsBytes());
        // 讀取途中使用者可能已經離開，這時 dispose 過了，
        // 再往清單裡塞就沒人會釋放它
        if (!mounted) {
          img.dispose();
          return;
        }
        _images.add(img);
      } catch (_) {}
      if (_images.length >= _kMaxCells) break;
    }
    if (!mounted) return;
    _poolSize = _images.length;
    if (_images.length < 2) {
      showHint(context, '至少要兩張讀得出來的照片', error: true);
      Navigator.pop(context);
      return;
    }
    // 預設挑一個「剛好放得下」而且接近正方形的排法
    final n = _images.length;
    var cols = math.sqrt(n).ceil().clamp(1, _kMaxSide);
    var rows = (n / cols).ceil().clamp(1, _kMaxSide);
    if (cols * rows > _kMaxCells) rows = _kMaxCells ~/ cols;
    setState(() {
      _cols = cols;
      _rows = rows;
      _resize();
    });
  }

  /// 依目前欄列重建格子：照片夠就填，不夠的留空（畫面上顯示「＋」）
  void _resize() {
    final alive = [
      for (var k = 0; k < _images.length; k++)
        if (_images[k] != null) k,
    ];
    final keep = _order.take(_cellCount).toList();
    _order = List.generate(_cellCount, (n) {
      if (n < keep.length) return keep[n]; // 原本就有的格子維持不動
      final used = keep.toSet();
      final free = alive.where((x) => !used.contains(x)).toList();
      final extra = n - keep.length;
      return extra < free.length ? free[extra] : -1;
    });
    _fits = List.generate(
      _cellCount,
      (n) => n < _fits.length ? _fits[n] : _CellFit(),
    );
  }

  void _setGrid({int? cols, int? rows}) {
    final c = (cols ?? _cols).clamp(1, _kMaxSide);
    final r = (rows ?? _rows).clamp(1, _kMaxSide);
    if (c * r > _kMaxCells) {
      showHint(context, '最多 $_kMaxCells 格', error: true);
      return;
    }
    if (c == _cols && r == _rows) return;
    setState(() {
      _cols = c;
      _rows = r;
      _selCell = -1;
      // 換排法時把拖曳狀態歸零，避免殘留的格子編號超出範圍
      _dragFrom = -1;
      _dragPos = null;
      _dragOver = -1;
      _resize();
    });
  }

  /// 點空格子的「＋」：挑照片補進來（多選會依序補其他空格）
  Future<void> _fillCell(int cell) async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty || !mounted) return;
    var filled = 0;
    var failed = 0;
    for (final f in files) {
      try {
        final img = await _decode(await f.readAsBytes());
        // 解碼要好幾秒，這中間使用者可能換了排法／離開，
        // 用當初算好的索引會直接越界
        if (!mounted) {
          img.dispose();
          return;
        }
        final slot = _emptySlot(prefer: filled == 0 ? cell : -1);
        if (slot == -1) {
          img.dispose();
          break; // 沒有空格了
        }
        _images.add(img);
        _order[slot] = _images.length - 1;
        _fits[slot] = _CellFit();
        filled++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    if (filled == 0 && failed > 0) {
      showHint(context, '照片讀不出來', error: true);
    }
    setState(() {});
  }

  /// 這一格現在顯示的照片（空格或已釋放都回 null）
  ui.Image? _imgAt(int cell) {
    if (cell < 0 || cell >= _order.length) return null;
    final idx = _order[cell];
    if (idx < 0 || idx >= _images.length) return null;
    return _images[idx];
  }

  /// 現在還空著的格子；prefer 若仍是空的就優先用它
  int _emptySlot({int prefer = -1}) {
    if (prefer >= 0 && prefer < _order.length && _order[prefer] == -1) {
      return prefer;
    }
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] == -1) return i;
    }
    return -1;
  }

  /// 點格子＝選取（可調整）；再點同一格取消
  void _tapCell(int cell) {
    setState(() => _selCell = _selCell == cell ? -1 : cell);
  }

  /// 換一張照片（重新從相簿挑）：鎖定格子後點右上角按鈕
  Future<void> _replaceCell(int cell) async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (f == null || !mounted) return;
    try {
      final img = await _decode(await f.readAsBytes());
      // 選照片＋解碼期間排法可能被換掉，格子編號會失效
      if (!mounted || cell >= _order.length) {
        img.dispose();
        return;
      }
      setState(() {
        final old = _order[cell];
        _images.add(img);
        _order[cell] = _images.length - 1;
        _fits[cell] = _CellFit();
        _selCell = cell;
        // 被換掉的那張若沒有別的格子在用就釋放，
        // 不然連換幾張就是好幾十 MB 掛在那裡等到離開才放
        _releaseIfUnused(old);
      });
    } catch (_) {
      if (mounted) showHint(context, '這張照片讀不出來', error: true);
    }
  }

  /// 釋放沒有任何格子在用的照片（一開始選進來的那批留著，
  /// 換版型時還要靠它們把格子填回去）
  void _releaseIfUnused(int idx) {
    if (idx < _poolSize || idx < 0 || idx >= _images.length) return;
    if (_order.contains(idx)) return;
    _images[idx]?.dispose();
    _images[idx] = null;
  }

  /// 拖曳互換：由宮格座標算出落在哪一格（-1 = 界外）
  int _cellAt(Offset p) {
    final c = (p.dx / (_gCw + _gG)).floor();
    final r = (p.dy / (_gCh + _gG)).floor();
    if (c < 0 || c >= _cols || r < 0 || r >= _rows) return -1;
    final i = r * _cols + c;
    return i < _cellCount ? i : -1;
  }

  /// 放開＝落在別格就互換（照片跟取景一起換；拖到空格＝移過去）
  void _endDrag() {
    final from = _dragFrom;
    final to = _dragPos == null ? -1 : _cellAt(_dragPos!);
    setState(() {
      if (from >= 0 && from < _order.length && to != -1 && to != from) {
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
  (double, double) _srcSize(ui.Image img, _CellFit f, double cellAspect) {
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
    return (math.min(sw, iw), math.min(sh, ih));
  }

  /// 把平移夾回「圖片還蓋得滿格子」的範圍。
  /// 只在 _srcRect 裡夾的話，pan 本身會無上限累積
  void _clampFit(ui.Image img, _CellFit f, double cellAspect) {
    final (sw, sh) = _srcSize(img, f, cellAspect);
    final mx = (img.width - sw) / 2;
    final my = (img.height - sh) / 2;
    f.panX = f.panX.clamp(-mx, math.max(0.0, mx));
    f.panY = f.panY.clamp(-my, math.max(0.0, my));
  }

  ui.Rect _srcRect(ui.Image img, _CellFit f, double cellAspect) {
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    // _srcSize 已經把取景窗夾在圖片內（web 的繪圖引擎對出界很嚴格）
    final (sw, sh) = _srcSize(img, f, cellAspect);
    // clamp 的上限不能是負的（浮點誤差會讓 iw-sw 變 -0.0001 直接炸）
    final mx = (iw - sw) > 0 ? iw - sw : 0.0;
    final my = (ih - sh) > 0 ? ih - sh : 0.0;
    var cx = (iw - sw) / 2 + f.panX;
    var cy = (ih - sh) / 2 + f.panY;
    cx = cx.clamp(0.0, mx);
    cy = cy.clamp(0.0, my);
    return ui.Rect.fromLTWH(cx, cy, sw, sh);
  }

  /// 合成一張 2048×2048 的拼圖，交給照片編輯器
  Future<void> _done() async {
    if (_building) return;
    if (_order.contains(-1)) {
      showHint(context, '還有空格子：點「＋」補照片，或換個宮格數', error: true);
      return;
    }
    setState(() => _building = true);
    // 讓「合成中…」先畫出來再開始重活（PNG 編碼在 web 會卡主執行緒）
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // 這 40ms 裡使用者可能已經離開（照片都 dispose 了）或換了版型
    if (!mounted) return;
    if (_order.contains(-1)) {
      setState(() => _building = false);
      return;
    }
    try {
      // 畫布跟著格數長：格子多的時候固定 1600 會讓每格只剩百來 px。
      // 上限 2400——再大 PNG 編碼在 web 會卡住主執行緒
      final size = (math.max(_cols, _rows) * 420.0).clamp(1600.0, 2400.0);
      final (count, cols, rows) = (_cellCount, _cols, _rows);
      // 跟預覽同一套排法：照片貼齊排滿，格線最後疊上去畫
      final cw = size / cols;
      final ch = size / rows;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      for (var i = 0; i < count; i++) {
        final img = _imgAt(i);
        if (img == null) continue;
        final dst = ui.Rect.fromLTWH(
          (i % cols) * cw,
          (i ~/ cols) * ch,
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
      if (_lines) {
        final t = _gapN * size;
        final lp = ui.Paint()..color = ui.Color(_lineColor);
        for (var c = 1; c < cols; c++) {
          canvas.drawRect(
            ui.Rect.fromLTWH(c * cw - t / 2, 0, t, size),
            lp,
          );
        }
        for (var r = 1; r < rows; r++) {
          canvas.drawRect(
            ui.Rect.fromLTWH(0, r * ch - t / 2, size, t),
            lp,
          );
        }
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
      // 用 push 保留拼圖頁：編輯器按上一步會回到宮格繼續調
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PhotoEditorScreen(photo: file)),
      );
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  /// 設定卡（版本 B）：左標籤右內容，「版型」「格線」兩列一張卡
  Widget _settingsCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                width: 40,
                child: Text(
                  '版型',
                  style: TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
              _stepper('欄', _cols, (v) => _setGrid(cols: v)),
              const SizedBox(width: 10),
              _stepper('列', _rows, (v) => _setGrid(rows: v)),
              const Spacer(),
              Text(
                '$_cellCount 格',
                style: const TextStyle(fontSize: 12, color: kTextDim),
              ),
            ],
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: kBorder,
          ),
          Row(
            children: [
              const SizedBox(
                width: 40,
                child: Text(
                  '格線',
                  style: TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
              SizedBox(
                width: 42,
                height: 26,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Switch(
                    value: _lines,
                    onChanged: (v) => setState(() => _lines = v),
                  ),
                ),
              ),
              if (_lines) ...[
                const SizedBox(width: 8),
                for (final c in const [
                  0xFFFFFFFF,
                  0xFF000000,
                  0xFF9E9EA6,
                  0xFFFFC24B,
                ])
                  _lineSwatch(c),
                // 調色盤：想要什麼顏色都能挑
                Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _pickLineColor,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const SweepGradient(
                          colors: [
                            Color(0xFFE57373),
                            Color(0xFFFFC24B),
                            Color(0xFF81C784),
                            Color(0xFF64B5F6),
                            Color(0xFFBA68C8),
                            Color(0xFFE57373),
                          ],
                        ),
                        border: Border.all(color: kBorder),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: Slider(
                      value: _gapN,
                      min: 0.001,
                      max: 0.05,
                      onChanged: (v) => setState(() => _gapN = v),
                    ),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
        ],
      ),
    );
  }

  /// 欄／列的加減。到達上限時該側按鈕變灰，不是消失——
  /// 按鈕位置跳動比按不下去更難用
  Widget _stepper(String label, int value, ValueChanged<int> onChange) {
    Widget btn(IconData icon, int delta, bool enabled) => InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: enabled ? () => onChange(value + delta) : null,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          icon,
          size: 17,
          color: enabled ? kText : kBorder,
        ),
      ),
    );
    final other = label == '欄' ? _rows : _cols;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kClipBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 3, right: 5),
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: kTextDim),
            ),
          ),
          btn(Icons.remove, -1, value > 1),
          SizedBox(
            width: 18,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: kText,
              ),
            ),
          ),
          btn(
            Icons.add,
            1,
            value < _kMaxSide && (value + 1) * other <= _kMaxCells,
          ),
        ],
      ),
    );
  }

  /// 調色盤挑格線顏色（跟浮水印文字的顏色挑選同一套）
  Future<void> _pickLineColor() async {
    var color = Color(_lineColor);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('格線顏色'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: color,
            enableAlpha: false,
            labelTypes: const [],
            onColorChanged: (c) => color = c,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _lineColor = color.toARGB32());
    }
  }

  Widget _lineSwatch(int c) {
    final on = _lineColor == c;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _lineColor = c),
        child: Container(
          width: 16,
          height: 16,
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
    // 不包 SwipeBack：拖曳格子互換會誤觸右滑返回、被踢回首頁
    return Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg, title: const Text('照片拼圖')),
        body: _cols == 0
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
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: _settingsCard(),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '拖曳可交換照片位置；點一下鎖定 可調照片顯示位置',
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
    );
  }

  Widget _buildGrid() {
    final (count, cols, rows) = (_cellCount, _cols, _rows);
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.maxWidth; // 1:1 畫布
        // 純格線：格子貼齊排滿，線條疊在照片上面畫，
        // 不用背景填色（背景填色會從空格、邊緣露出來）
        final cw = size / cols;
        final ch = size / rows;
        _gG = 0;
        _gCw = cw;
        _gCh = ch;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < count; i++)
              Positioned(
                left: (i % cols) * cw,
                top: (i ~/ cols) * ch,
                width: cw,
                height: ch,
                child: _cell(i, cw, ch),
              ),
            if (_lines)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GridLinePainter(
                      cols: cols,
                      rows: rows,
                      t: _gapN * size,
                      color: Color(_lineColor),
                    ),
                  ),
                ),
              ),
            // 拖曳互換中：浮起的縮圖跟著指尖走
            if (_dragFrom >= 0 && _imgAt(_dragFrom) != null && _dragPos != null)
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
                            img: _imgAt(_dragFrom)!,
                            src: _srcRect(
                              _imgAt(_dragFrom)!,
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
    final img = _imgAt(i);
    // 空格子：一個「＋」，點了挑照片補進來（拖照片過來也行）
    if (img == null) {
      final over = _dragFrom != -1 && _dragOver == i;
      return GestureDetector(
        onTap: () => _fillCell(i),
        child: Container(
          decoration: BoxDecoration(
            color: kPanel,
            border: over
                ? Border.all(color: kSelect, width: 2.5)
                : Border.all(color: kBorder),
          ),
          child: const Center(
            child: Icon(Icons.add, size: 30, color: kTextDim),
          ),
        ),
      );
    }
    final selected = _selCell == i;
    final fit = _fits[i];
    // 這格在宮格座標裡的左上角（拖曳換算指尖位置用）
    final origin = Offset(
      (i % _cols) * (_gCw + _gG),
      (i ~/ _cols) * (_gCh + _gG),
    );
    // 螢幕位移 → 來源像素位移的換算比
    double dispScale() => cellW / _srcRect(img, fit, cellW / cellH).width;
    return Listener(
      // 雙指縮放：判斷用「有沒有格子被選」而不是「這一格被選」——
      // 撐開時第二指多半落在隔壁格，用後者的話常常整個沒反應
      onPointerDown: (e) {
        _pts[e.pointer] = e.position;
        if (_selCell != -1 && _pts.length == 2) {
          final p = _pts.values.toList();
          _baseDist = (p[0] - p[1]).distance;
          _baseZoom = _fits[_selCell].zoom;
        }
      },
      onPointerMove: (e) {
        if (!_pts.containsKey(e.pointer)) return;
        _pts[e.pointer] = e.position;
        if (_selCell != -1 && _baseDist != null && _pts.length >= 2) {
          final p = _pts.values.toList();
          final f = (p[0] - p[1]).distance / _baseDist!;
          final sf = _fits[_selCell];
          setState(() {
            sf.zoom = (_baseZoom * f).clamp(1.0, 4.0);
            final si = _imgAt(_selCell);
            if (si != null) _clampFit(si, sf, cellW / cellH);
          });
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
              // 夾回可移動範圍：不夾的話拖到底之後還會一直累積，
              // 往回拖時要先抵銷那幾百 px，畫面看起來像卡住
              _clampFit(img, fit, cellW / cellH);
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                child: CustomPaint(
                  size: Size(cellW, cellH),
                  painter: _CellPainter(
                    img: img,
                    src: _srcRect(img, fit, cellW / cellH),
                  ),
                ),
              ),
              // 鎖定中：右上角「換照片」鈕
              // （長按跟拖曳在手機上會互相搶，改用按鈕最不會誤觸）
              if (selected)
                Positioned(
                  right: 6,
                  top: 6,
                  child: GestureDetector(
                    onTap: () => _replaceCell(i),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.cached,
                        size: 16,
                        color: Colors.white,
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
}

/// 純格線：畫在照片上面的細線（直的 cols-1 條、橫的 rows-1 條）
class _GridLinePainter extends CustomPainter {
  final int cols;
  final int rows;
  final double t;
  final Color color;

  const _GridLinePainter({
    required this.cols,
    required this.rows,
    required this.t,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final cw = size.width / cols;
    final ch = size.height / rows;
    for (var c = 1; c < cols; c++) {
      canvas.drawRect(Rect.fromLTWH(c * cw - t / 2, 0, t, size.height), p);
    }
    for (var r = 1; r < rows; r++) {
      canvas.drawRect(Rect.fromLTWH(0, r * ch - t / 2, size.width, t), p);
    }
  }

  @override
  bool shouldRepaint(_GridLinePainter old) =>
      old.cols != cols || old.rows != rows || old.t != t || old.color != color;
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
