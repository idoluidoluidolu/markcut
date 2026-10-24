import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/mosaic.dart';
import 'mosaic_patch_painter.dart' show strokeBoundsPx, strokeFeatherPx;

/// 影片筆刷馬賽克的筆畫：範圍與遮罩的「唯一算法」。
///
/// 規則跟照片的 paintMosaicStroke、iOS 合成器的 CIMosaicSpec 同一套：
/// 圓頭圓角的粗線，粗細＝畫布短邊×brush；柔邊＝線寬先收掉柔邊寬、
/// 再整筆高斯暈開（σ＝柔邊÷2）；效果鋪滿包圍盒，筆畫決定哪裡吃效果。
/// FFmpeg 匯出（遮罩 PNG）跟 Flutter 預覽都從這裡拿，三邊碼到的範圍
/// 才是同一塊

/// 筆畫的點換成畫布像素座標（0~1，x,y 交錯攤平 → Offset）
List<ui.Offset> brushStrokePoints(List<double> stroke, double w, double h) => [
  for (var i = 0; i + 1 < stroke.length; i += 2)
    ui.Offset(stroke[i] * w, stroke[i + 1] * h),
];

/// 筆刷馬賽克在輸出畫面上要處理的那一塊（像素，左上原點）。
///
/// 包圍盒外推半個筆刷＋柔邊尾巴（strokeBoundsPx，跟 iOS 的 rect 同一個
/// 算法），夾進畫面、四邊對齊偶數：crop 跟 overlay 在 yuv420 上都會把
/// 座標捨到偶數，遮罩先對齊才不會跟效果錯開一格。
/// 整塊都在畫面外（筆畫被拖出去了）回 null
({int x, int y, int w, int h})? brushStrokeBox(
  List<double> stroke,
  double brush,
  MosaicStyle st,
  int outW,
  int outH,
) {
  if (stroke.length < 2) return null;
  final brushPx = brush * math.min(outW, outH);
  final b = strokeBoundsPx(
    brushStrokePoints(stroke, outW.toDouble(), outH.toDouble()),
    brushPx,
    strokeFeatherPx(st, brushPx),
  );
  var x = math.max(0, b.left.floor());
  var y = math.max(0, b.top.floor());
  x -= x % 2;
  y -= y % 2;
  var w = math.min(outW, b.right.ceil()) - x;
  var h = math.min(outH, b.bottom.ceil()) - y;
  if (w < 2 || h < 2) return null;
  w = math.min(w + w % 2, (outW - x) - (outW - x) % 2);
  h = math.min(h + h % 2, (outH - y) - (outH - y) % 2);
  if (w < 2 || h < 2) return null;
  return (x: x, y: y, w: w, h: h);
}

/// 畫一筆筆刷（[pts] 是像素座標）。遮罩用白色；純色遮蓋直接畫那個顏色
void paintBrushStroke(
  ui.Canvas canvas,
  List<ui.Offset> pts,
  double brushPx,
  double featherPx,
  ui.Color color,
) {
  if (pts.isEmpty) return;
  final soft = featherPx >= 1;
  final lineW = math.max(1.0, brushPx - (soft ? featherPx : 0));
  final paint = ui.Paint()..color = color;
  // 柔邊用 MaskFilter：暈開算在筆畫本身的形狀上，伸出畫布的那一截
  // 也一起暈進來——貼著畫面邊緣的筆畫，邊上照樣是實的（iOS 那邊是
  // clampedToExtent 再模糊，同一個結果）
  if (soft) {
    paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, featherPx / 2);
  }
  if (pts.length == 1) {
    canvas.drawCircle(pts.first, lineW / 2, paint);
    return;
  }
  final path = ui.Path()..moveTo(pts.first.dx, pts.first.dy);
  for (final p in pts.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(
    path,
    paint
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = lineW
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round,
  );
}

/// FFmpeg 匯出用的遮罩 PNG：只有 [brushStrokeBox] 那一塊大小，
/// 透明底、白色筆畫，alpha＝這一格吃多少效果（濾鏡圖那邊用 alphaextract
/// 取出來給 alphamerge）。整筆在畫面外回 null
Future<Uint8List?> renderBrushMaskPng(
  List<double> stroke,
  double brush,
  MosaicStyle st,
  int outW,
  int outH,
) async {
  final box = brushStrokeBox(stroke, brush, st, outW, outH);
  if (box == null) return null;
  final brushPx = brush * math.min(outW, outH);
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec)
    ..translate(-box.x.toDouble(), -box.y.toDouble());
  paintBrushStroke(
    canvas,
    brushStrokePoints(stroke, outW.toDouble(), outH.toDouble()),
    brushPx,
    strokeFeatherPx(st, brushPx),
    const ui.Color(0xFFFFFFFF),
  );
  final img = await rec.endRecording().toImage(box.w, box.h);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    img.dispose();
  }
}

/// 預覽用的裁切形狀：筆畫往外長 [half] 的範圍（圓頭圓角粗線的外輪廓）。
///
/// dart:ui 沒有「把粗線轉成填色外框」，所以拼出來：每一小段一個長方形、
/// 兩端和轉彎處各一個圓，全部同一個繞行方向，nonZero 填色＝聯集
///（方向不一的話重疊處會變成破洞）。圓用自己算的多邊形，不靠 addOval
/// 的預設方向。幾乎沒轉彎的接點不補圓：兩個長方形之間的縫不到 1%
/// 個半徑，手畫的點很密，每點都補圓只是白白多幾千個頂點
ui.Path brushStrokeOutline(List<ui.Offset> pts, double half) {
  final path = ui.Path();
  if (pts.isEmpty || half <= 0) return path;
  void circle(ui.Offset c) {
    // 弦高誤差壓在 0.5px 內，邊數 8~32
    final n = (math.pi / math.acos(math.max(-1.0, 1 - 0.5 / half)))
        .ceil()
        .clamp(8, 32);
    // 螢幕座標 y 朝下：角度遞增＝順時針
    path.moveTo(c.dx + half, c.dy);
    for (var i = 1; i < n; i++) {
      final t = 2 * math.pi * i / n;
      path.lineTo(c.dx + math.cos(t) * half, c.dy + math.sin(t) * half);
    }
    path.close();
  }

  circle(pts.first);
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final d = b - a;
    final len = d.distance;
    if (len < 1e-6) continue;
    // 法線轉 90°（y 朝下時指向行進方向的右手邊）；
    // a−n → b−n → b+n → a+n 在螢幕上是順時針，跟圓一致
    final n = ui.Offset(-d.dy, d.dx) / len * half;
    path
      ..moveTo((a - n).dx, (a - n).dy)
      ..lineTo((b - n).dx, (b - n).dy)
      ..lineTo((b + n).dx, (b + n).dy)
      ..lineTo((a + n).dx, (a + n).dy)
      ..close();
    if (i < pts.length - 1) {
      final e = pts[i + 1] - b;
      final el = e.distance;
      // 轉超過 10° 才補圓（cos 10° ≈ 0.985）
      if (el > 1e-6 && (d.dx * e.dx + d.dy * e.dy) / (len * el) < 0.985) {
        circle(b);
      }
    }
  }
  if (pts.length > 1) circle(pts.last);
  return path;
}
