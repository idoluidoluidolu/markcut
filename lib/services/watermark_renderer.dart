import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/color_grade.dart';
import 'diagnostics.dart';
import '../models/mosaic.dart';
import '../models/watermark_settings.dart';
import 'logo_mark_painter.dart';
import 'mosaic_patch_painter.dart';
import 'text_mark_painter.dart';

/// 把浮水印設定畫成點陣圖。
/// 預覽和輸出走同一套繪製邏輯，所以「看到的就是輸出的」。
/// 全部以 bytes 操作，手機與 Web 通用。
class WatermarkRenderer {
  /// 產生一張透明背景、大小等於輸出解析度的浮水印圖層 PNG，
  /// 之後交給 FFmpeg overlay 疊到影片上。
  static Future<Uint8List> renderOverlayPng(
    WatermarkSettings s,
    int outW,
    int outH,
  ) async {
    return _renderOverlay(s, outW, outH, ui.ImageByteFormat.png);
  }

  static Future<Uint8List> _renderOverlay(
    WatermarkSettings s,
    int outW,
    int outH,
    ui.ImageByteFormat fmt, {
    bool pad = false,
  }) async {
    final t0 = DateTime.now();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (pad) canvas.translate(outW * 0.5, outH * 0.5);
    await drawMarks(canvas, s, outW.toDouble(), outH.toDouble());
    final picture = recorder.endRecording();
    final t1 = DateTime.now();
    final image = await picture.toImage(
      pad ? outW * 2 : outW,
      pad ? outH * 2 : outH,
    );
    final t2 = DateTime.now();
    final data = await image.toByteData(format: fmt);
    final t3 = DateTime.now();
    WmDiag.noteBakeDetail(
      t1.difference(t0).inMilliseconds,
      t2.difference(t1).inMilliseconds,
      t3.difference(t2).inMilliseconds,
    );
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 即時路：raw RGBA（預乘）直出，免 PNG 編碼——調樣式拖動中用，
  /// 尺寸就是 [outW]x[outH]
  /// [pad]＝外擴烘圖：畫布放大成 2 倍、內容置中——拖出畫框再拉
  /// 回來，框外那截也在圖裡（實機 161：被切掉的先消失才回來）。
  /// 輸出尺寸是 2*outW x 2*outH
  static Future<Uint8List> renderOverlayRaw(
    WatermarkSettings s,
    int outW,
    int outH, {
    bool pad = false,
  }) async {
    return _renderOverlay(s, outW, outH, ui.ImageByteFormat.rawRgba, pad: pad);
  }

  /// 只烘「部件的包圍盒」：點陣只有部件本身（含陰影／描邊／底色的外擴），
  /// 連同它落在畫布的哪一塊一起回。整版烘圖 540p 一張 raw 就是 2MB、
  /// 過通道還要複製一次，而一顆文字浮水印其實只佔畫布幾個百分點。
  ///
  /// - 像素格跟整版烘圖一模一樣（整數對齊、同一個縮放）：原生用 rect
  ///   擺回去就是整版那張「裁下來的一塊」，不是重取樣
  /// - 有滿版平鋪的部件（整面都是內容）或 [fullCanvas]：box＝整個畫布
  /// - 畫布外的部分裁掉（整版烘圖本來就只有畫布這麼大，行為一致）；
  ///   整個都在畫布外＝沒東西可畫，回 null
  /// [margin] 包圍盒每邊再多留的像素（取樣邊緣的餘裕）
  static Future<OverlayPartImage?> renderPart(
    WatermarkSettings s,
    int outW,
    int outH,
    ui.ImageByteFormat fmt, {
    bool fullCanvas = false,
    double margin = 2,
  }) async {
    if (outW < 2 || outH < 2) return null;
    final w = outW.toDouble(), h = outH.toDouble();
    final canvasRect = ui.Rect.fromLTWH(0, 0, w, h);
    final bounds = fullCanvas ? null : await partBounds(s, w, h);
    var box = bounds == null ? canvasRect : bounds.inflate(margin);
    box = box.intersect(canvasRect);
    if (box.isEmpty) return null;
    // 整數對齊；原生端（CIOverlaySpec）要求兩邊都大於 1px
    final l = box.left.floor().clamp(0, outW - 2);
    final t = box.top.floor().clamp(0, outH - 2);
    final r = box.right.ceil().clamp(l + 2, outW);
    final b = box.bottom.ceil().clamp(t + 2, outH);
    final bw = r - l, bh = b - t;
    final t0 = DateTime.now();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, bw.toDouble(), bh.toDouble()),
    );
    // 原點搬到包圍盒左上：畫的還是整版那套座標，只是只留這一塊
    canvas.translate(-l.toDouble(), -t.toDouble());
    await drawMarks(canvas, s, w, h);
    final picture = recorder.endRecording();
    final t1 = DateTime.now();
    final image = await picture.toImage(bw, bh);
    picture.dispose();
    final t2 = DateTime.now();
    final data = await image.toByteData(format: fmt);
    final t3 = DateTime.now();
    image.dispose();
    WmDiag.noteBakeDetail(
      t1.difference(t0).inMilliseconds,
      t2.difference(t1).inMilliseconds,
      t3.difference(t2).inMilliseconds,
    );
    if (data == null) return null;
    return OverlayPartImage(
      bytes: data.buffer.asUint8List(),
      width: bw,
      height: bh,
      box: ui.Rect.fromLTWH(
        l.toDouble(),
        t.toDouble(),
        bw.toDouble(),
        bh.toDouble(),
      ),
      canvasW: outW,
      canvasH: outH,
    );
  }

  /// 這組設定裡所有「單顆」部件的包圍盒聯集（畫布像素、左上原點，
  /// 可以超出畫布）。有滿版平鋪的部件回 null（整面都是內容，沒有
  /// 包圍盒可言）；一個部件都沒有回 [ui.Rect.zero]
  static Future<ui.Rect?> partBounds(
    WatermarkSettings s,
    double w,
    double h,
  ) async {
    ui.Rect? acc;
    for (final logo in s.logos) {
      final bytes = logo.bytes;
      if (!logo.enabled || bytes == null) continue;
      if (logo.tiled) return null;
      final img = await _logoImage(bytes);
      final r = logoBounds(logo, img.width / img.height, w, h);
      acc = acc == null ? r : acc.expandToInclude(r);
    }
    for (final t in s.texts) {
      if (!t.enabled || t.text.trim().isEmpty) continue;
      if (t.tiled) return null;
      final r = textMarkBounds(t, w, h);
      acc = acc == null ? r : acc.expandToInclude(r);
    }
    return acc ?? ui.Rect.zero;
  }

  /// 單顆文字的包圍盒（畫布像素）：版面框往外擴「陰影／描邊／加粗／
  /// 墨水餘裕」的量，再併入底色塊，最後以中心為軸轉（跟 [_drawText]
  /// 同一個軸心）。
  ///
  /// 外擴量是 [paintMarkGlyphs] 裡離屏層邊界的同一組算式（inkSlack
  /// 0.3、加粗 0.06、陰影位移 0.03、模糊 3σ）：那邊的內容最多畫到
  /// 層邊界為止，所以這個框一定包得住。改那邊的常數要一起改這裡
  ///（test/wm_part_bbox_test.dart 會抓「框包不住」）
  static ui.Rect textMarkBounds(TextMark t, double w, double h) {
    final fontSize = t.sizeFrac * math.min(w, h);
    final m = measureMark(t, fontSize);
    final c = ui.Offset(t.x * w, t.y * h);
    final ink = ui.Rect.fromCenter(center: c, width: m.width, height: m.height);
    final boldPx = t.weight > 0.005 ? fontSize * 0.06 * t.weight : 0.0;
    final outlinePx = t.outline ? fontSize * t.outlineWidth + boldPx : 0.0;
    final hasShadow = t.shadow && t.shadowOpacity > 0.01;
    final sigma = hasShadow ? fontSize * t.shadowBlur : 0.0;
    final spread = math.max(outlinePx, boldPx) / 2;
    final reach =
        fontSize * 0.3 +
        spread +
        (hasShadow ? fontSize * 0.03 + sigma * 3 : 0.0);
    var box = ink.inflate(reach);
    if (t.bg) {
      final padH = fontSize * 0.35 * t.bgPad;
      final padV = fontSize * 0.18 * t.bgPad;
      box = box.expandToInclude(
        ui.Rect.fromLTRB(
          ink.left - padH,
          ink.top - padV,
          ink.right + padH,
          ink.bottom + padV,
        ),
      );
    }
    return rotatedBounds(box, c, t.rotation);
  }

  /// 單張 Logo 的包圍盒（畫布像素）：跟 [drawMarks] 同一套定位
  ///（短邊基準、中心定位、以中心為軸轉）。[imgAspect]＝圖片寬/高
  static ui.Rect logoBounds(
    LogoMark logo,
    double imgAspect,
    double w,
    double h,
  ) {
    final targetW = logo.sizeFrac * math.min(w, h);
    final targetH = targetW / imgAspect;
    final c = ui.Offset(logo.x * w, logo.y * h);
    return rotatedBounds(
      ui.Rect.fromCenter(center: c, width: targetW, height: targetH),
      c,
      logo.rotation,
    );
  }

  /// [r] 以 [c] 為軸轉 [deg] 度之後的軸對齊包圍盒。角度小到畫的時候
  /// 不會轉的（門檻跟 [drawMarks] 一樣 0.01°），這裡也不轉
  static ui.Rect rotatedBounds(ui.Rect r, ui.Offset c, double deg) {
    if (deg.abs() <= 0.01) return r;
    final a = deg * math.pi / 180;
    final ca = math.cos(a), sa = math.sin(a);
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final dx = p.dx - c.dx, dy = p.dy - c.dy;
      final x = c.dx + dx * ca - dy * sa;
      final y = c.dy + dx * sa + dy * ca;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 照片浮水印：以原始解析度合成照片 + 馬賽克 + 浮水印，輸出 PNG（無損）。
  static Future<Uint8List> renderPhotoComposite(
    Uint8List photoBytes,
    WatermarkSettings s, {
    ColorGrade? grade,
    List<PhotoMosaic>? mosaics,
    List<WatermarkSettings>? extraMarks,
    double? canvasAspect,
  }) async {
    final image = await renderPhotoImage(
      photoBytes,
      s,
      grade: grade,
      mosaics: mosaics,
      extraMarks: extraMarks,
      canvasAspect: canvasAspect,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 同 [renderPhotoComposite]，但回傳合成好的 [ui.Image] 而不是 PNG。
  /// 呼叫端自己決定要把像素怎麼帶出去（PNG、raw RGBA…），
  /// 也要自己 dispose。批次匯出走這裡：存 JPEG 時不必先過一手 PNG
  static Future<ui.Image> renderPhotoImage(
    Uint8List photoBytes,
    WatermarkSettings s, {
    ColorGrade? grade,
    List<PhotoMosaic>? mosaics,
    List<WatermarkSettings>? extraMarks,
    // 畫布比例（null＝跟照片一樣）：照片置中 contain 貼在黑底
    // 畫布上，之後所有座標與馬賽克取樣都以畫布為準（跟預覽同一套）
    double? canvasAspect,
    String? sourcePath,
  }) async {
    // On mobile the engine reads the source directly; no full-file copy over
    // the Dart heap. Byte input remains available for web and existing callers.
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec codec;
    try {
      if (sourcePath != null) {
        buffer = await ui.ImmutableBuffer.fromFilePath(sourcePath);
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        codec = await descriptor.instantiateCodec();
      } else {
        codec = await ui.instantiateImageCodec(photoBytes);
      }
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
    final frame = await codec.getNextFrame();
    codec.dispose();
    final decoded = frame.image;
    try {
      return await compositePhoto(
        decoded,
        s,
        grade: grade,
        mosaics: mosaics,
        extraMarks: extraMarks,
        canvasAspect: canvasAspect,
      );
    } finally {
      decoded.dispose();
    }
  }

  /// [renderPhotoImage] 的後半：照片已經解好了，只做合成。
  /// 單張編輯器手上本來就有解好的全尺寸照片（預覽跟馬賽克取樣用的
  /// 那張），匯出時直接拿來合成，不必把 12MP 再解一次。
  /// 像素跟 [renderPhotoImage] 一字不差（同一份解碼結果、同一段合成）。
  /// 不 dispose 傳進來的 [photo]——呼叫端的東西呼叫端收；回傳的圖要自己 dispose
  static Future<ui.Image> compositePhoto(
    ui.Image photo,
    WatermarkSettings s, {
    ColorGrade? grade,
    List<PhotoMosaic>? mosaics,
    List<WatermarkSettings>? extraMarks,
    double? canvasAspect,
  }) async {
    // 中途產生的（貼黑底、調完色）才是我們的，換掉時要收；傳進來的不碰
    var owned = false;
    var w = photo.width;
    var h = photo.height;

    if (canvasAspect != null && (canvasAspect - w / h).abs() > 0.001) {
      // 畫布尺寸：照片一邊貼滿、另一邊補黑，像素不縮水
      final int cw, ch;
      if (canvasAspect >= w / h) {
        ch = h;
        cw = (h * canvasAspect).round();
      } else {
        cw = w;
        ch = (w / canvasAspect).round();
      }
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      c.drawRect(
        ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
      c.drawImageRect(
        photo,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Rect.fromLTWH(
          (cw - w) / 2,
          (ch - h) / 2,
          w.toDouble(),
          h.toDouble(),
        ),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final canvased = await rec.endRecording().toImage(cw, ch);
      // 這時 photo 還是傳進來的那張，不收
      photo = canvased;
      owned = true;
      w = cw;
      h = ch;
    }

    // 有調色時先把「調完色的照片」烙成一張圖——
    // 馬賽克要取樣的是調色後的畫面（跟預覽/影片匯出一致）
    if (grade?.hasColor ?? false) {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawImage(
        photo,
        ui.Offset.zero,
        ui.Paint()..colorFilter = grade!.filter,
      );
      final graded = await rec.endRecording().toImage(w, h);
      if (owned) photo.dispose();
      photo = graded;
      owned = true;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(photo, ui.Offset.zero, ui.Paint());
    // 馬賽克畫在浮水印下面（打碼的是照片，不是浮水印）
    for (final m in mosaics ?? const <PhotoMosaic>[]) {
      _drawMosaic(canvas, photo, m, w, h);
    }
    await drawMarks(canvas, s, w.toDouble(), h.toDouble());
    // 更多浮水印：一組一組疊上去（照片模式可加好幾組）
    for (final e in extraMarks ?? const <WatermarkSettings>[]) {
      await drawMarks(canvas, e, w.toDouble(), h.toDouble());
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    if (owned) photo.dispose();
    return image;
  }

  /// 在照片上畫一塊馬賽克。這裡只算「畫在哪」，
  /// 效果本身交給共用畫家 paintMosaicPatch（跟預覽同一段程式碼）
  static void _drawMosaic(
    ui.Canvas canvas,
    ui.Image photo,
    PhotoMosaic m,
    int w,
    int h,
  ) {
    // 筆刷筆畫：範圍＝筆畫包圍盒，效果交給共用畫家
    if (m.isStroke) {
      final pts = <ui.Offset>[
        for (var i = 0; i + 1 < m.stroke!.length; i += 2)
          ui.Offset(m.stroke![i] * w, m.stroke![i + 1] * h),
      ];
      final brushPx = m.brush * math.min(w, h);
      final box = strokeBoundsPx(
        pts,
        brushPx,
        strokeFeatherPx(m.style, brushPx),
      );
      paintMosaicStroke(canvas, photo, m.style, pts, brushPx, box, box);
      return;
    }
    final side = m.scale * math.min(w, h);
    final rect = ui.Rect.fromCenter(
      center: ui.Offset(m.x * w, m.y * h),
      width: side,
      height: side,
    ).intersect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    if (rect.width < 2 || rect.height < 2) return;
    // 畫布就是照片座標：src＝dst，效果全交給共用畫家
    //（跟照片編輯器的預覽補丁同一段程式碼）
    paintMosaicPatch(canvas, photo, m.style, rect, rect);
  }

  /// 文字素材：以完整樣式＋位置＋縮放渲染成整版透明 PNG（匯出 overlay 用）
  static Future<Uint8List> renderTextClipPng(
    TextMark style,
    double px,
    double py,
    double scale,
    int outW,
    int outH,
  ) async {
    final t = style.copy()
      ..enabled = true
      ..x = px
      ..y = py
      ..sizeFrac = style.sizeFrac * scale;
    final s = WatermarkSettings(text: t, logo: LogoMark(enabled: false));
    return renderOverlayPng(s, outW, outH);
  }

  /// 在指定大小的畫布上畫出文字與 Logo 浮水印
  /// logo 解碼快取：每次烘圖都重新解碼的話，大圖一次幾百 ms——
  /// 實機 158「烘圖平均 292ms／最久 1299ms」的大頭。鍵是 bytes
  /// 物件本身（b64 解碼結果有池，同一顆 logo 拿到同一個物件），
  /// Expando 跟著物件活、物件回收快取自然消
  static final Expando<ui.Image> _logoDecoded = Expando();

  static Future<ui.Image> _logoImage(Uint8List bytes) async {
    final hit = _logoDecoded[bytes];
    if (hit != null) return hit;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    _logoDecoded[bytes] = frame.image;
    return frame.image;
  }

  static Future<void> drawMarks(
    ui.Canvas canvas,
    WatermarkSettings s,
    double w,
    double h,
  ) async {
    // 圖片先畫（讓文字可以壓在圖片上面）。多張時照清單順序，
    // 後加的那張蓋在前面的上面——跟預覽的疊法一致
    for (final logo in s.logos) {
      final logoBytes = logo.bytes;
      if (!logo.enabled || logoBytes == null) continue;
      final img = await _logoImage(logoBytes);

      // 縮放/圓角/透明度/平鋪全交給共用畫家（跟預覽同一段程式碼）
      if (logo.tiled) {
        paintLogoTiled(canvas, logo, img, w, h);
        continue; // 平鋪的這張畫完，換下一張
      }

      // 不夾限：跟預覽同一套——拖出畫面的部分就讓它被畫布切掉
      final targetW = logo.sizeFrac * math.min(w, h); // 短邊基準
      final targetH = targetW * img.height / img.width;
      final left = logo.x * w - targetW / 2;
      final top = logo.y * h - targetH / 2;
      final rect = ui.Rect.fromLTWH(left, top, targetW, targetH);
      canvas.save();
      // 旋轉：以圖片中心為軸（預覽是 Transform.rotate 同軸心）
      if (logo.rotation.abs() > 0.01) {
        final c = rect.center;
        canvas.translate(c.dx, c.dy);
        canvas.rotate(logo.rotation * math.pi / 180);
        canvas.translate(-c.dx, -c.dy);
      }
      paintLogoUnit(canvas, logo, img, rect);
      canvas.restore();
    }

    _drawText(canvas, s, w, h);
  }

  /// 文字浮水印（含平鋪、底色、描邊、旋轉）。
  /// 文字可以有很多個，照清單順序畫（後加的在上）
  /// 把每一顆文字浮水印畫上畫布。
  ///
  /// 字形（陰影/描邊/本體）一律交給 [paintMarkGlyphs]——那是預覽
  /// 與匯出共用的「唯一畫法」，同一段程式碼跑兩次，輸出跟預覽
  /// 在數學上是同一件事。這裡只管：位置、旋轉、底色、滿版平鋪
  static void _drawText(
    ui.Canvas canvas,
    WatermarkSettings s,
    double w,
    double h,
  ) {
    for (final t in s.texts) {
      if (!t.enabled || t.text.trim().isEmpty) continue;
      // 不自動換行、也不自動縮小：使用者調多大就多大，
      // 超出畫面是允許的
      final fontSize = t.sizeFrac * math.min(w, h); // 短邊基準（跟預覽一致）
      final m = measureMark(t, fontSize);
      final padH = fontSize * 0.35 * t.bgPad;
      final padV = fontSize * 0.18 * t.bgPad;

      void bgRect(double x, double y) {
        if (!t.bg) return;
        canvas.drawRRect(
          ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(
              x - padH,
              y - padV,
              m.width + padH * 2,
              m.height + padV * 2,
            ),
            ui.Radius.circular(fontSize * t.bgCorner),
          ),
          ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
        );
      }

      // 滿版平鋪（棋盤格）：整個畫面交錯重複，忽略 x/y
      if (t.tiled) {
        final stepX = m.width + fontSize * 2.2;
        final stepY = m.height + fontSize * 2.6;
        canvas.save();
        if (t.rotation.abs() > 0.01) {
          canvas.translate(w / 2, h / 2);
          canvas.rotate(t.rotation * math.pi / 180);
          canvas.translate(-w / 2, -h / 2);
        }
        var row = 0;
        for (var y = -h; y < h * 2; y += stepY, row++) {
          final shift = row.isOdd ? stepX / 2 : 0.0;
          for (var x = -w - shift; x < w * 2; x += stepX) {
            bgRect(x, y);
            paintMarkGlyphs(canvas, t, fontSize, ui.Offset(x, y));
          }
        }
        canvas.restore();
        continue;
      }

      // 單顆：中心點定位（不夾限，可拖出畫面）＋以中心為軸旋轉
      final left = t.x * w - m.width / 2;
      final top = t.y * h - m.height / 2;
      canvas.save();
      if (t.rotation.abs() > 0.01) {
        final cx = left + m.width / 2;
        final cy = top + m.height / 2;
        canvas.translate(cx, cy);
        canvas.rotate(t.rotation * math.pi / 180);
        canvas.translate(-cx, -cy);
      }
      bgRect(left, top);
      paintMarkGlyphs(canvas, t, fontSize, ui.Offset(left, top));
      canvas.restore();
    }
  }
}

/// [WatermarkRenderer.renderPart] 的結果：部件包圍盒的點陣＋它在畫布的位置
class OverlayPartImage {
  const OverlayPartImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.box,
    required this.canvasW,
    required this.canvasH,
  });

  /// 點陣（raw RGBA 預乘或 PNG，看烘的時候要的格式）
  final Uint8List bytes;
  final int width;
  final int height;

  /// 點陣落在畫布的哪一塊（畫布像素、左上原點、整數對齊、在畫布內）
  final ui.Rect box;

  /// 烘圖時的畫布大小（像素）
  final int canvasW;
  final int canvasH;

  /// 包圍盒佔畫布的比例 [x, y, w, h]（左上原點）——原生 CIOverlaySpec
  /// 的 rect 語意；整版時是 [0, 0, 1, 1]
  List<double> get fraction => [
    box.left / canvasW,
    box.top / canvasH,
    box.width / canvasW,
    box.height / canvasH,
  ];

  /// 整版（沒有裁掉任何一邊）
  bool get fullCanvas =>
      box.left == 0 &&
      box.top == 0 &&
      box.width == canvasW &&
      box.height == canvasH;
}
