import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'cutout_decont.dart';
import 'cutout_mask.dart' show maskToRgba;

/// 照片去背的背景
enum PhotoCutBg { clear, color, blur, image }

/// 一筆修邊：保留＝把畫到的地方加回主體、擦除＝從主體挖掉。
/// 座標是照片的 0~1（轉正後、左上原點）；[width] 是筆刷直徑佔照片短邊
/// 的比例——預覽跟原尺寸匯出各自換算成像素，粗細才一樣
class CutStroke {
  final bool keep;
  final double width;
  final List<Offset> points;

  CutStroke({required this.keep, required this.width, List<Offset>? points})
    : points = points ?? [];

  CutStroke copy() =>
      CutStroke(keep: keep, width: width, points: List.of(points));
}

/// 一個可以上一步的狀態（選了哪些主體、修邊、背景）
class PhotoCutState {
  final Set<int> ids;
  final List<CutStroke> strokes;
  final PhotoCutBg bg;
  final int color;
  final String? bgPath;
  final double feather;

  const PhotoCutState({
    required this.ids,
    required this.strokes,
    required this.bg,
    required this.color,
    required this.bgPath,
    required this.feather,
  });

  PhotoCutState copy() => PhotoCutState(
    ids: Set.of(ids),
    strokes: [for (final s in strokes) s.copy()],
    bg: bg,
    color: color,
    bgPath: bgPath,
    feather: feather,
  );

  /// 比對有沒有改過（離開要不要問）
  String get signature =>
      '${(ids.toList()..sort()).join(',')}|${strokes.length}:'
      '${strokes.fold<int>(0, (n, s) => n + s.points.length)}|'
      '${bg.index}|$color|$bgPath|${feather.toStringAsFixed(3)}';
}

/// 遮罩（寬×高位元組）→ 可以拿來畫的 alpha 影像
Future<ui.Image> maskToImage(Uint8List mask, int w, int h) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(maskToRgba(mask));
  final desc = ui.ImageDescriptor.raw(
    buf,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  try {
    final codec = await desc.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    desc.dispose();
    buf.dispose();
  }
}

/// 背景模糊的強度：長邊的比例（影片去背是 2%；照片當人像模式用，糊一點）
const kPhotoCutBlur = 0.03;

/// 柔邊的最大強度（長邊的比例），滑桿 0~1 乘上它
const kPhotoCutFeatherMax = 0.01;

/// 遮罩那一層的內容：自動遮罩＋修邊筆畫（白色、alpha＝遮罩）。成品、
/// 去色要的最終遮罩（[renderCutoutAlpha]）都畫這一支
void _paintMaskContent(
  Canvas canvas,
  Rect dst,
  ui.Image? mask,
  List<CutStroke> strokes,
) {
  final short = math.min(dst.width, dst.height);
  final m = mask;
  if (m != null) {
    canvas.drawImageRect(
      m,
      Rect.fromLTWH(0, 0, m.width.toDouble(), m.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    final w = math.max(1.0, s.width * short);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFFFFFFF)
      ..blendMode = s.keep ? BlendMode.srcOver : BlendMode.clear
      // 筆刷邊緣帶一點柔：硬邊的筆畫在頭髮、毛邊旁邊很假
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.12);
    Offset at(Offset o) =>
        Offset(dst.left + o.dx * dst.width, dst.top + o.dy * dst.height);
    if (s.points.length == 1) {
      final c = at(s.points.first);
      canvas.drawCircle(
        c,
        w / 2,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..blendMode = p.blendMode
          ..maskFilter = p.maskFilter,
      );
      continue;
    }
    final path = Path()..moveTo(at(s.points.first).dx, at(s.points.first).dy);
    for (final o in s.points.skip(1)) {
      final q = at(o);
      path.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(path, p);
  }
}

/// 畫去背成品：背景 → 照片乘上遮罩（自動遮罩＋修邊）。預覽與匯出共用
/// 這一支，預覽看到的就是成品。
///
/// [dst]＝照片畫在哪；[mask] 是 alpha 遮罩（null＝自動的一塊都沒有，只剩
/// 修邊「保留」塗出來的）。[fg]＝去色後的照片（[decontaminatePhoto]，邊緣
/// 那一圈不帶舊背景的顏色；還沒算好就畫原照片）。透明背景這裡什麼都不畫
///（預覽自己墊棋盤格）。
///
/// 柔邊只往內：遮罩乘上「模糊過的遮罩」——主體外面還是 0（不會把舊背景
/// 往外帶出一圈光暈），裡面靠邊的地方漸漸變透明
void paintCutout(
  Canvas canvas,
  Rect dst, {
  required ui.Image photo,
  required ui.Image? mask,
  required List<CutStroke> strokes,
  required PhotoCutBg bg,
  int color = 0xFFFFFFFF,
  ui.Image? bgImage,
  double feather = 0,
  ui.Image? fg,
}) {
  final long = math.max(dst.width, dst.height);
  final photoSrc = Rect.fromLTWH(
    0,
    0,
    photo.width.toDouble(),
    photo.height.toDouble(),
  );
  final hq = Paint()..filterQuality = FilterQuality.high;
  canvas.save();
  canvas.clipRect(dst);
  switch (bg) {
    case PhotoCutBg.clear:
      break;
    case PhotoCutBg.color:
      canvas.drawRect(dst, Paint()..color = Color(color));
    case PhotoCutBg.blur:
      final s = long * kPhotoCutBlur;
      canvas.saveLayer(
        dst,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: s,
            sigmaY: s,
            tileMode: TileMode.clamp,
          ),
      );
      canvas.drawImageRect(photo, photoSrc, dst, hq);
      canvas.restore();
    case PhotoCutBg.image:
      final b = bgImage;
      if (b != null) {
        // 鋪滿（cover）：比例不同就裁掉多的那一邊
        final bw = b.width.toDouble(), bh = b.height.toDouble();
        final k = math.max(dst.width / bw, dst.height / bh);
        final sw = dst.width / k, sh = dst.height / k;
        final src = Rect.fromLTWH((bw - sw) / 2, (bh - sh) / 2, sw, sh);
        canvas.drawImageRect(b, src, dst, hq);
      }
  }
  // 主體：照片（去色後的）一層，遮罩一層用 dstIn 疊上去（只留遮罩不透明
  // 的地方）；有柔邊再疊一層模糊過的遮罩（兩層相乘＝只往內柔）
  canvas.saveLayer(dst, Paint());
  final face = fg ?? photo;
  canvas.drawImageRect(
    face,
    Rect.fromLTWH(0, 0, face.width.toDouble(), face.height.toDouble()),
    dst,
    hq,
  );
  canvas.saveLayer(dst, Paint()..blendMode = BlendMode.dstIn);
  _paintMaskContent(canvas, dst, mask, strokes);
  canvas.restore();
  if (feather > 0.001) {
    final f = long * kPhotoCutFeatherMax * feather;
    canvas.saveLayer(
      dst,
      Paint()
        ..blendMode = BlendMode.dstIn
        // clamp：主體碰到照片邊的地方（例如下半身被切掉）不會往邊緣漸透明
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: f,
          sigmaY: f,
          tileMode: TileMode.clamp,
        ),
    );
    _paintMaskContent(canvas, dst, mask, strokes);
    canvas.restore();
  }
  canvas.restore();
  canvas.restore();
}

/// 最終遮罩（自動遮罩＋修邊筆畫，沒有柔邊）攤成 [w]×[h] 位元組——去色要的 α
Future<Uint8List> renderCutoutAlpha({
  required int w,
  required int h,
  required ui.Image? mask,
  required List<CutStroke> strokes,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final dst = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  canvas.saveLayer(dst, Paint());
  _paintMaskContent(canvas, dst, mask, strokes);
  canvas.restore();
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  try {
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final out = Uint8List(w * h);
    if (bd == null) return out;
    final b = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    for (var i = 0; i < w * h; i++) {
      out[i] = b[i * 4 + 3];
    }
    return out;
  } finally {
    img.dispose();
  }
}

/// 照片的 RGBA 位元組（去色要讀；一張照片讀一次就好）
Future<Uint8List?> photoRgba(ui.Image photo) async {
  final bd = await photo.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) return null;
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

/// 去色後的照片（邊緣那一圈解開舊背景的顏色，見 decontaminateRgba）。
/// 在背景 isolate 算；[rgba]＝[photoRgba] 讀出來的、[alpha]＝[renderCutoutAlpha]
Future<ui.Image> decontaminatePhoto({
  required Uint8List rgba,
  required Uint8List alpha,
  required int w,
  required int h,
}) async {
  final src = TransferableTypedData.fromList([rgba]);
  final a = TransferableTypedData.fromList([alpha]);
  final outT = await Isolate.run(() {
    final out = decontaminateRgba(
      src.materialize().asUint8List(),
      a.materialize().asUint8List(),
      w,
      h,
    );
    return TransferableTypedData.fromList([out]);
  });
  final out = outT.materialize().asUint8List();
  final buf = await ui.ImmutableBuffer.fromUint8List(out);
  final desc = ui.ImageDescriptor.raw(
    buf,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  try {
    final codec = await desc.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    desc.dispose();
    buf.dispose();
  }
}

/// 成品（原尺寸）：[w]×[h] 的影像，透明背景就帶 alpha
Future<ui.Image> renderCutout({
  required int w,
  required int h,
  required ui.Image photo,
  required ui.Image? mask,
  required List<CutStroke> strokes,
  required PhotoCutBg bg,
  int color = 0xFFFFFFFF,
  ui.Image? bgImage,
  double feather = 0,
  ui.Image? fg,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  paintCutout(
    canvas,
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    photo: photo,
    mask: mask,
    strokes: strokes,
    bg: bg,
    color: color,
    bgImage: bgImage,
    feather: feather,
    fg: fg,
  );
  final pic = rec.endRecording();
  try {
    return await pic.toImage(w, h);
  } finally {
    pic.dispose();
  }
}

/// 照片解成影像（轉正），長邊不超過 [maxSide]。手機上讓引擎直接讀檔、
/// 在解的時候就縮（同照片編輯器的預覽那條）
Future<ui.Image> decodePhoto(String path, {required int maxSide}) async {
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  ui.Codec? codec;
  try {
    buf = await ui.ImmutableBuffer.fromFilePath(path);
    desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width, h = desc.height;
    final long = math.max(w, h);
    if (long > maxSide) {
      final sc = maxSide / long;
      codec = await desc.instantiateCodec(
        targetWidth: (w * sc).round().clamp(1, maxSide),
        targetHeight: (h * sc).round().clamp(1, maxSide),
      );
    } else {
      codec = await desc.instantiateCodec();
    }
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    desc?.dispose();
    buf?.dispose();
  }
}
