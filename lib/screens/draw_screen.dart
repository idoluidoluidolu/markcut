import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// flutter_colorpicker 也輸出一個叫 CheckerPainter 的類別，藏掉它
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    hide CheckerPainter;

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

/// 形狀工具：自由畫之外的基本形狀（拖一下＝從起點畫到終點）
enum _Tool { free, line, rect, oval }

extension _ToolInfo on _Tool {
  String get label => switch (this) {
        _Tool.free => '自由',
        _Tool.line => '直線',
        _Tool.rect => '方框',
        _Tool.oval => '圓形',
      };

  IconData get icon => switch (this) {
        _Tool.free => Icons.gesture,
        _Tool.line => Icons.show_chart,
        _Tool.rect => Icons.crop_square,
        _Tool.oval => Icons.circle_outlined,
      };
}

/// 一筆：路徑點＋顏色＋粗細＋筆刷＋工具。
/// 形狀工具只用第一點和最後一點（起點→終點）
class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final _Brush brush;
  final _Tool tool;

  _Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.brush,
    required this.tool,
  });

  bool get eraser => brush == _Brush.eraser;

  /// 實際畫出來的寬度
  double get drawWidth => width * brush.widthK;

  /// 這一筆的外框（輸出裁圖用）
  Rect get bounds {
    final pad = drawWidth / 2 + 2;
    if (tool != _Tool.free) {
      return Rect.fromPoints(points.first, points.last).inflate(pad);
    }
    var r = Rect.fromCircle(center: points.first, radius: pad);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromCircle(center: p, radius: pad));
    }
    return r;
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

  Color _color = Colors.white;

  /// 調色盤挑出來的自訂色（顯示成色列的第一顆）
  Color _custom = const Color(0xFF9B7BFF);
  double _width = 8;
  _Brush _brush = _Brush.pen;
  _Tool _tool = _Tool.free;

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
        brush: _brush,
        tool: _tool,
      );
    });
  }

  void _move(Offset p) {
    final s = _live;
    if (s == null) return;
    if (s.tool != _Tool.free) {
      // 形狀：只追蹤終點（起點固定），拖到哪畫到哪
      setState(() {
        if (s.points.length == 1) {
          s.points.add(p);
        } else {
          s.points[s.points.length - 1] = p;
        }
      });
      return;
    }
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

  /// 筆刷／工具共用的小圓片選項
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
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        actions: [
          IconButton(
            tooltip: '上一步',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() => _undone.add(_strokes.removeLast())),
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
            tooltip: '全部清掉',
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() {
                      _undone
                        ..clear()
                        ..addAll(_strokes.reversed);
                      _strokes.clear();
                    }),
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
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 筆刷一排＋形狀一排：各自單選
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
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 32,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final t in _Tool.values) ...[
                          _chip(
                            label: t.label,
                            icon: t.icon,
                            on: _tool == t,
                            onTap: () => setState(() => _tool = t),
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
                        // 調色盤：長按直接重開挑色；顯示目前的自訂色
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
                  // 粗細：拖的時候右邊那顆點即時變大小（含筆刷倍率）
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
                            width: (_width * _brush.widthK).clamp(2, 40),
                            height: (_width * _brush.widthK).clamp(2, 40),
                            decoration: BoxDecoration(
                              color: _brush == _Brush.eraser
                                  ? kPanelHi
                                  : _color.withValues(alpha: _brush.alpha),
                              shape: BoxShape.circle,
                              border: Border.all(color: kClipBorder),
                            ),
                          ),
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

    // 形狀工具：起點→終點
    if (s.tool != _Tool.free && s.points.length >= 2) {
      final a = s.points.first;
      final b = s.points.last;
      switch (s.tool) {
        case _Tool.line:
          canvas.drawLine(a, b, paint);
        case _Tool.rect:
          canvas.drawRect(Rect.fromPoints(a, b), paint);
        case _Tool.oval:
          canvas.drawOval(Rect.fromPoints(a, b), paint);
        case _Tool.free:
          break;
      }
      continue;
    }

    if (s.points.length == 1) {
      // 點一下＝一個圓點
      canvas.drawCircle(
        s.points.first,
        s.drawWidth / 2,
        Paint()
          ..color = s.eraser
              ? Colors.transparent
              : s.color.withValues(alpha: s.brush.alpha)
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
