import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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

/// 一筆：路徑點＋顏色＋粗細（或橡皮擦）
class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool eraser;

  _Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.eraser,
  });
}

class _DrawScreen extends StatefulWidget {
  const _DrawScreen();

  @override
  State<_DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<_DrawScreen> {
  final List<_Stroke> _strokes = [];
  _Stroke? _live;

  Color _color = Colors.white;
  double _width = 8;
  bool _eraser = false;

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

  void _start(Offset p) {
    setState(() {
      _live = _Stroke(
        points: [p],
        color: _color,
        width: _width,
        eraser: _eraser,
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
    });
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
      for (final p in s.points) {
        final r = Rect.fromCircle(center: p, radius: s.width / 2 + 2);
        bounds = first ? r : bounds.expandToInclude(r);
        first = false;
      }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        actions: [
          IconButton(
            tooltip: '上一步',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() => _strokes.removeLast()),
            icon: const Icon(Icons.undo, size: 20),
          ),
          IconButton(
            tooltip: '全部清掉',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(_strokes.clear),
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
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
                        // 畫圖是單指的事；縮放手勢這一頁用不到
                        onPanStart: (d) => _start(d.localPosition),
                        onPanUpdate: (d) => _move(d.localPosition),
                        onPanEnd: (_) => _end(),
                        child: CustomPaint(
                          painter: const CheckerPainter(),
                          foregroundPainter: _BoardPainter(
                            strokes: _strokes,
                            live: _live,
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顏色一排＋橡皮擦
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 34,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _palette.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) {
                              final c = _palette[i];
                              final on = !_eraser && c == _color;
                              return InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: () => setState(() {
                                  _color = c;
                                  _eraser = false;
                                }),
                                child: Container(
                                  width: 34,
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: on ? kSelect : kClipBorder,
                                      width: on ? 2.5 : 1,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 橡皮擦：跟顏色互斥，同一排看得出「現在拿的是誰」
                      InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => setState(() => _eraser = !_eraser),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: _eraser ? kPanelHi : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _eraser ? kSelect : kClipBorder,
                              width: _eraser ? 2.5 : 1,
                            ),
                          ),
                          child: const Icon(Icons.cleaning_services_outlined,
                              size: 16, color: kIcon),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 粗細：拖的時候右邊那顆點即時變大小
                  Row(
                    children: [
                      const Text('粗細',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: kText)),
                      Expanded(
                        child: Slider(
                          value: _width,
                          min: 2,
                          max: 36,
                          onChanged: (v) => setState(() => _width = v),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: Container(
                            width: _width.clamp(2, 36),
                            height: _width.clamp(2, 36),
                            decoration: BoxDecoration(
                              color: _eraser ? kPanelHi : _color,
                              shape: BoxShape.circle,
                              border: Border.all(color: kClipBorder),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
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
/// 橡皮擦用 BlendMode.clear——不開圖層的話 clear 會把棋盤格也擦掉
void _paintStrokes(
  Canvas canvas,
  List<_Stroke> strokes,
  _Stroke? live,
  Rect area,
) {
  canvas.saveLayer(area, Paint());
  for (final s in [...strokes, ?live]) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (s.eraser) {
      paint.blendMode = BlendMode.clear;
    } else {
      paint.color = s.color;
    }
    if (s.points.length == 1) {
      // 點一下＝一個圓點
      canvas.drawCircle(
        s.points.first,
        s.width / 2,
        Paint()
          ..color = s.eraser ? Colors.transparent : s.color
          ..blendMode = s.eraser ? BlendMode.clear : BlendMode.srcOver,
      );
      continue;
    }
    final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
    // 相鄰點取中點畫二次貝茲：折線的稜角會被抹掉，看起來像真的筆
    for (var i = 1; i < s.points.length - 1; i++) {
      final mid = (s.points[i] + s.points[i + 1]) / 2;
      path.quadraticBezierTo(
          s.points[i].dx, s.points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(s.points.last.dx, s.points.last.dy);
    canvas.drawPath(path, paint);
  }
  canvas.restore();
}

class _BoardPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _Stroke? live;

  const _BoardPainter({required this.strokes, required this.live});

  @override
  void paint(Canvas canvas, Size size) {
    _paintStrokes(canvas, strokes, live, Offset.zero & size);
  }

  // 筆跡的點是就地 add 的，列表比對看不出變化——每次都重畫。
  // 這一頁只有一塊畫板在動，重畫成本可以接受
  @override
  bool shouldRepaint(_BoardPainter old) => true;
}
