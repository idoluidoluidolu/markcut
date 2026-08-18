import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// flutter_colorpicker 也輸出一個叫 CheckerPainter 的類別，藏掉它
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    hide CheckerPainter;

import '../services/photo_saver.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart' show CheckerPainter;

/// 手繪浮水印：全螢幕畫板，畫完輸出「裁到筆跡範圍」的透明 PNG。
///
/// 拿到的 PNG 走現有的圖片浮水印那條路——位置、縮放、旋轉、透明度、
/// 平鋪、匯出全部直接繼承，這一頁只負責「把筆跡變成一張圖」。
///
/// 回傳 null＝取消。
Future<Uint8List?> drawWatermark(BuildContext context) =>
    Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => const _DrawScreen()),
    );

/// 筆刷：每種差在透明度、寬度倍率、筆頭形狀
enum _Brush { pen, marker, highlight, eraser }

extension _BrushInfo on _Brush {
  String get label => switch (this) {
        _Brush.pen => '鋼筆',
        _Brush.marker => '麥克筆',
        _Brush.highlight => '螢光筆',
        _Brush.eraser => '橡皮擦',
      };

  IconData get icon => switch (this) {
        _Brush.pen => Icons.edit_outlined,
        _Brush.marker => Icons.brush_outlined,
        _Brush.highlight => Icons.border_color_outlined,
        _Brush.eraser => Icons.cleaning_services_outlined,
      };

  /// 透明度：麥克筆半透明、螢光筆更透（疊起來有層次）
  double get alpha => switch (this) {
        _Brush.marker => 0.65,
        _Brush.highlight => 0.4,
        _ => 1.0,
      };

  /// 寬度倍率：同一支粗細滑桿，不同筆刷有自己的手感
  double get widthK => switch (this) {
        _Brush.marker => 1.6,
        _Brush.highlight => 2.4,
        _Brush.eraser => 1.4,
        _ => 1.0,
      };
}

/// 一筆：路徑點＋顏色＋粗細＋筆刷。
/// 粗細不是 final——畫完還可以點選那一筆回頭調
class _Stroke {
  final List<Offset> points;
  final Color color;
  double width;
  final _Brush brush;

  _Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.brush,
  });

  bool get eraser => brush == _Brush.eraser;

  /// 實際畫出來的寬度
  double get drawWidth => width * brush.widthK;

  /// 這一筆的外框（輸出裁圖用）
  Rect get bounds {
    final pad = drawWidth / 2 + 2;
    var r = Rect.fromCircle(center: points.first, radius: pad);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromCircle(center: p, radius: pad));
    }
    return r;
  }

  /// 點 [p] 到這一筆的最短距離（選取判定用）
  double distanceTo(Offset p) {
    if (points.length == 1) return (points.first - p).distance;
    var best = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      best = math.min(best, _distToSegment(p, points[i], points[i + 1]));
      if (best == 0) break;
    }
    return best;
  }

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 <= 1e-9) return (p - a).distance;
    final t =
        (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }
}

class _DrawScreen extends StatefulWidget {
  const _DrawScreen();

  @override
  State<_DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<_DrawScreen> {
  final List<_Stroke> _strokes = [];

  /// 重做堆疊：上一步收回來的筆放這裡，畫新的一筆就清掉
  final List<_Stroke> _undone = [];
  _Stroke? _live;

  /// 被選取的那一筆（-1＝沒有）。選了之後粗細滑桿調的就是它；
  /// 點空白處或開始畫新的一筆＝取消
  int _sel = -1;

  Color _color = Colors.white;

  /// 調色盤挑出來的自訂色（顯示成色列的第一顆）
  Color _custom = const Color(0xFF9B7BFF);
  double _width = 8;
  _Brush _brush = _Brush.pen;

  /// 白色放最前面：深色影片上最常用的就是白字白圖
  static const _palette = [
    Colors.white,
    Color(0xFF121216),
    Color(0xFFFF3B30),
    Color(0xFFFFC24B),
    Color(0xFF34C759),
    Color(0xFF0A84FF),
    Color(0xFFBF5AF2),
    Color(0xFFFF6FA6),
  ];

  bool get _hasInk => _strokes.any((s) => !s.eraser);

  _Stroke? get _selStroke =>
      (_sel >= 0 && _sel < _strokes.length) ? _strokes[_sel] : null;

  /// 點一下：先看有沒有點到既有的筆畫（選取它、回頭調粗細）；
  /// 都沒點到——沒選取時畫一個圓點（原本的手感），有選取時只取消
  void _tapAt(Offset p) {
    var hit = -1;
    // 後畫的在上面，從後往前找
    for (var i = _strokes.length - 1; i >= 0; i--) {
      final s = _strokes[i];
      if (s.distanceTo(p) <= math.max(12, s.drawWidth / 2 + 6)) {
        hit = i;
        break;
      }
    }
    if (hit >= 0) {
      setState(() => _sel = hit == _sel ? -1 : hit);
      return;
    }
    if (_sel != -1) {
      setState(() => _sel = -1);
      return;
    }
    // 點空白＝一個圓點
    setState(() {
      _strokes.add(_Stroke(
        points: [p],
        color: _color,
        width: _width,
        brush: _brush,
      ));
      _undone.clear();
    });
  }

  void _start(Offset p) {
    setState(() {
      _sel = -1; // 開始畫新的一筆＝取消選取
      _live = _Stroke(
        points: [p],
        color: _color,
        width: _width,
        brush: _brush,
      );
    });
  }

  void _move(Offset p) {
    final s = _live;
    if (s == null) return;
    // 距離太近的點丟掉：一筆幾千個點會讓重繪跟輸出都變慢
    if ((s.points.last - p).distance < 1.5) return;
    setState(() => s.points.add(p));
  }

  void _end() {
    final s = _live;
    if (s == null) return;
    setState(() {
      _strokes.add(s);
      _live = null;
      _undone.clear(); // 畫了新的，原本的重做路線就斷了
    });
  }

  /// 調色盤：挑任意顏色（挑完直接拿在手上）
  Future<void> _openPicker() async {
    var pick = _custom;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('調色盤'),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pick,
            onColorChanged: (c) => pick = c,
            enableAlpha: false,
            hexInputBar: true,
            labelTypes: const [],
            pickerAreaBorderRadius: BorderRadius.circular(10),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('就用這個'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _custom = pick;
        _color = pick;
        if (_brush == _Brush.eraser) _brush = _Brush.pen;
      });
    }
  }

  /// 把畫好的透明 PNG 直接存進相簿（不進浮水印流程也拿得到圖）
  Future<void> _saveToGallery() async {
    final png = await _renderPng(_boardSize);
    if (!mounted) return;
    if (png == null) {
      showHint(context, '還沒畫任何東西', error: true);
      return;
    }
    final msg = await savePhotoPng(
      png,
      'draw_${DateTime.now().millisecondsSinceEpoch}',
    );
    if (mounted) showHint(context, msg, error: !msg.contains('已'));
  }

  Future<void> _done(Size boardSize) async {
    final png = await _renderPng(boardSize);
    if (!mounted) return;
    if (png == null) {
      showHint(context, '還沒畫任何東西', error: true);
      return;
    }
    Navigator.pop(context, png);
  }

  /// 把筆跡畫成 PNG：只取「筆跡的外框＋一點邊距」，不是整塊畫板——
  /// 畫在角落的小圖示不該帶著一大圈透明邊進來（縮放會失準、
  /// 選取框也會大得莫名其妙）。長邊輸出 1024。
  Future<Uint8List?> _renderPng(Size boardSize) async {
    if (!_hasInk) return null;
    // 外框只看畫筆（橡皮擦只影響透明度，不該撐大範圍）
    var bounds = Rect.zero;
    var first = true;
    for (final s in _strokes) {
      if (s.eraser) continue;
      bounds = first ? s.bounds : bounds.expandToInclude(s.bounds);
      first = false;
    }
    bounds = bounds.intersect(Offset.zero & boardSize);
    if (bounds.width < 4 || bounds.height < 4) return null;

    final scale = 1024 / math.max(bounds.width, bounds.height);
    final outW = (bounds.width * scale).round();
    final outH = (bounds.height * scale).round();

    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);
    // 跟預覽同一個畫法（saveLayer 讓橡皮擦真的擦成透明）
    _paintStrokes(canvas, _strokes, null, Offset.zero & boardSize);
    final img = await rec.endRecording().toImage(outW, outH);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }

  /// 筆刷選項的小圓片
  Widget _chip({
    required String label,
    required IconData icon,
    required bool on,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: kClipBorder),
        ),
        foregroundDecoration: on
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: kSelect, width: 1.5),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: on ? kText : kTextDim),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                color: on ? kText : kTextDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selStroke;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        actions: [
          IconButton(
            tooltip: '上一步',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() {
                      _undone.add(_strokes.removeLast());
                      _sel = -1;
                    }),
            icon: Icon(Icons.undo,
                size: 20, color: _strokes.isEmpty ? kTextDim : kSelect),
          ),
          IconButton(
            tooltip: '重做',
            onPressed: _undone.isEmpty
                ? null
                : () => setState(() => _strokes.add(_undone.removeLast())),
            icon: Icon(Icons.redo,
                size: 20, color: _undone.isEmpty ? kTextDim : kSelect),
          ),
          IconButton(
            tooltip: '存到相簿（透明背景 PNG）',
            onPressed: !_hasInk ? null : _saveToGallery,
            icon: const Icon(Icons.save_alt, size: 20),
          ),
          IconButton(
            tooltip: '全部清掉',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() {
                      _undone
                        ..clear()
                        ..addAll(_strokes.reversed);
                      _strokes.clear();
                      _sel = -1;
                    }),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 畫板：佔掉整個剩餘空間。棋盤格＝透明底，
            // 跟製作浮水印畫面同一套語言
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final size = Size(cons.maxWidth, cons.maxHeight);
                    _boardSize = size;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: GestureDetector(
                        // 畫圖是單指的事；縮放手勢這一頁用不到。
                        // 點一下＝選取既有筆畫（回頭調粗細）或畫圓點
                        onTapUp: (d) => _tapAt(d.localPosition),
                        onPanStart: (d) => _start(d.localPosition),
                        onPanUpdate: (d) => _move(d.localPosition),
                        onPanEnd: (_) => _end(),
                        child: CustomPaint(
                          painter: const CheckerPainter(),
                          foregroundPainter: _BoardPainter(
                            strokes: _strokes,
                            live: _live,
                            selected: _sel,
                          ),
                          size: size,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 筆刷一排：單選
                  SizedBox(
                    height: 32,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final b in _Brush.values) ...[
                          _chip(
                            label: b.label,
                            icon: b.icon,
                            on: _brush == b,
                            onTap: () => setState(() => _brush = b),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 顏色一排：第一顆是調色盤（自訂色），其餘是常用色
                  SizedBox(
                    height: 34,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: _openPicker,
                          child: Container(
                            width: 34,
                            decoration: BoxDecoration(
                              color: _custom,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _brush != _Brush.eraser &&
                                        _color == _custom
                                    ? kSelect
                                    : kClipBorder,
                                width: _brush != _Brush.eraser &&
                                        _color == _custom
                                    ? 2.5
                                    : 1,
                              ),
                            ),
                            child: const Icon(Icons.palette_outlined,
                                size: 16, color: Colors.white70),
                          ),
                        ),
                        const SizedBox(width: 8),
                        for (final c in _palette) ...[
                          InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => setState(() {
                              _color = c;
                              if (_brush == _Brush.eraser) {
                                _brush = _Brush.pen;
                              }
                            }),
                            child: Container(
                              width: 34,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _brush != _Brush.eraser &&
                                          c == _color
                                      ? kSelect
                                      : kClipBorder,
                                  width: _brush != _Brush.eraser &&
                                          c == _color
                                      ? 2.5
                                      : 1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 粗細：沒選東西＝下一筆的粗細；點選了某一筆＝直接調它
                  Row(
                    children: [
                      Text(
                        sel == null ? '粗細' : '這一筆',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: sel == null ? kText : kSelect),
                      ),
                      Expanded(
                        child: Slider(
                          value: (sel?.width ?? _width).clamp(2.0, 36.0),
                          min: 2,
                          max: 36,
                          onChanged: (v) => setState(() {
                            if (sel != null) {
                              sel.width = v;
                            } else {
                              _width = v;
                            }
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: Builder(builder: (context) {
                            final w = sel?.drawWidth ??
                                (_width * _brush.widthK);
                            final showColor = sel == null
                                ? (_brush == _Brush.eraser
                                    ? kPanelHi
                                    : _color
                                        .withValues(alpha: _brush.alpha))
                                : (sel.eraser
                                    ? kPanelHi
                                    : sel.color
                                        .withValues(alpha: sel.brush.alpha));
                            return Container(
                              width: w.clamp(2, 40),
                              height: w.clamp(2, 40),
                              decoration: BoxDecoration(
                                color: showColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: kClipBorder),
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  primaryAction(
                    label: '完成',
                    icon: Icons.check,
                    onPressed: !_hasInk ? null : () => _done(_boardSize),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 畫板目前的實際尺寸（build 時由 LayoutBuilder 記下，輸出裁圖用）
  Size _boardSize = Size.zero;
}

/// 預覽跟輸出共用的畫法：saveLayer 之後畫全部筆跡，
/// 橡皮擦用 BlendMode.clear——不開圖層的話 clear 會把棋盤格也擦掉。
/// [selected] 是被選取那一筆的索引（畫琥珀光暈），輸出時給 -1
void _paintStrokes(
  Canvas canvas,
  List<_Stroke> strokes,
  _Stroke? live,
  Rect area, {
  int selected = -1,
}) {
  canvas.saveLayer(area, Paint());
  final all = [...strokes, ?live];
  for (var i = 0; i < all.length; i++) {
    final s = all[i];
    // 被選取的那一筆：先在底下畫一圈琥珀光暈，看得出選到誰
    if (i == selected) {
      final halo = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.drawWidth + 7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = kSelect.withValues(alpha: 0.85);
      _strokePath(canvas, s, halo, haloDot: true);
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.drawWidth
      // 螢光筆是平頭（畫出來像真的螢光筆），其他圓頭
      ..strokeCap = s.brush == _Brush.highlight
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (s.eraser) {
      paint.blendMode = BlendMode.clear;
    } else {
      paint.color = s.color.withValues(alpha: s.brush.alpha);
    }
    _strokePath(canvas, s, paint);
  }
  canvas.restore();
}

/// 一筆的實際繪製（光暈與本體共用同一條路徑）
void _strokePath(Canvas canvas, _Stroke s, Paint paint,
    {bool haloDot = false}) {
  if (s.points.length == 1) {
    final dot = Paint()
      ..color = haloDot
          ? paint.color
          : (s.eraser
              ? Colors.transparent
              : s.color.withValues(alpha: s.brush.alpha))
      ..blendMode =
          (!haloDot && s.eraser) ? BlendMode.clear : BlendMode.srcOver;
    canvas.drawCircle(s.points.first, paint.strokeWidth / 2, dot);
    return;
  }
  final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
  // 相鄰點取中點畫二次貝茲：折線的稜角會被抹掉，看起來像真的筆
  for (var i = 1; i < s.points.length - 1; i++) {
    final mid = (s.points[i] + s.points[i + 1]) / 2;
    path.quadraticBezierTo(s.points[i].dx, s.points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(s.points.last.dx, s.points.last.dy);
  canvas.drawPath(path, paint);
}

class _BoardPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _Stroke? live;
  final int selected;

  const _BoardPainter({
    required this.strokes,
    required this.live,
    required this.selected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintStrokes(canvas, strokes, live, Offset.zero & size,
        selected: selected);
  }

  // 筆跡的點是就地 add 的，列表比對看不出變化——每次都重畫。
  // 這一頁只有一塊畫板在動，重畫成本可以接受
  @override
  bool shouldRepaint(_BoardPainter old) => true;
}
