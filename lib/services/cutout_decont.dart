import 'dart:math' as math;
import 'dart:typed_data';

import '../models/cutout.dart';

/// 去背的去色（照片用；影片在 FFmpeg 的 cutoutDecontFilter、iOS 合成器的
/// MCCutoutDecont，同一套）：邊緣半透明那一圈的顏色混著舊背景，換背景就是
/// 一圈光暈——照 Forte & Pitié 2021 的 blur-fusion 兩段解開：
///
///   F̂＝blur(F·α)/blur(α)、B̂＝blur(B·(1−α))/blur(1−α)
///   F＝F̂＋α(I−αF̂−(1−α)B̂)
///
/// 第一段 F=B=I、模糊大（[kCutoutDecontSigma1]），第二段拿第一段的 F、B̂、
/// 模糊小（[kCutoutDecontSigma2]）。估計（F̂、B̂）在長邊 [workLong] 的縮圖上
/// 算（本來就是模糊量），最後一步在原尺寸、拿原尺寸的 I 跟 α 套公式——
/// 髮絲的細節還在。α=0／255 的像素原樣照抄（人裡面一個位元都不動）。
///
/// [rgba]＝照片（w×h×4，alpha 不看）、[alpha]＝最終遮罩（w×h）→ 前景色
/// RGBA（不透明，w×h×4）。整張都沒有半透明就直接回原圖的拷貝
Uint8List decontaminateRgba(
  Uint8List rgba,
  Uint8List alpha,
  int w,
  int h, {
  int workLong = 1024,
}) {
  final n = w * h;
  final out = Uint8List.fromList(rgba);
  for (var i = 0; i < n; i++) {
    out[i * 4 + 3] = 255;
  }
  var band = 0;
  for (var i = 0; i < n; i++) {
    final a = alpha[i];
    if (a != 0 && a != 255) band++;
  }
  if (band == 0) return out;

  // 縮圖（面積平均）：I 三通道、α
  final long = math.max(w, h);
  final k = long > workLong ? workLong / long : 1.0;
  final qw = math.max(1, (w * k).round());
  final qh = math.max(1, (h * k).round());
  final qn = qw * qh;
  final qi = Float32List(qn * 3);
  final qa = Float32List(qn);
  _areaDown(rgba, alpha, w, h, qi, qa, qw, qh);

  final qlong = math.max(qw, qh).toDouble();
  final s1 = qlong * kCutoutDecontSigma1;
  final s2 = qlong * kCutoutDecontSigma2;

  // 第一段：F=B=I
  final (fh1, bh1) = _estimate(qi, qi, qa, qw, qh, s1);
  final f1 = Float32List(qn * 3);
  for (var p = 0; p < qn; p++) {
    final a = qa[p];
    for (var c = 0; c < 3; c++) {
      final i = p * 3 + c;
      final v = fh1[i] + a * (qi[i] - a * fh1[i] - (1 - a) * bh1[i]);
      f1[i] = v < 0 ? 0 : (v > 1 ? 1 : v);
    }
  }
  // 第二段：拿第一段的 F、B̂
  final (fh2, bh2) = _estimate(f1, bh1, qa, qw, qh, s2);

  // 原尺寸套公式（只有邊帶）；F̂、B̂ 雙線性放大
  final kx = qw / w, ky = qh / h;
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) * ky - 0.5).clamp(0.0, qh - 1.0);
    final y0 = fy.floor();
    final y1 = y0 + 1 < qh ? y0 + 1 : y0;
    final wy = fy - y0;
    for (var x = 0; x < w; x++) {
      final ai = alpha[y * w + x];
      if (ai == 0 || ai == 255) continue;
      final a = ai / 255.0;
      final fx = ((x + 0.5) * kx - 0.5).clamp(0.0, qw - 1.0);
      final x0 = fx.floor();
      final x1 = x0 + 1 < qw ? x0 + 1 : x0;
      final wx = fx - x0;
      final p00 = (y0 * qw + x0) * 3, p01 = (y0 * qw + x1) * 3;
      final p10 = (y1 * qw + x0) * 3, p11 = (y1 * qw + x1) * 3;
      final o = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        double lerp(Float32List m) {
          final t = m[p00 + c] * (1 - wx) + m[p01 + c] * wx;
          final b = m[p10 + c] * (1 - wx) + m[p11 + c] * wx;
          return t * (1 - wy) + b * wy;
        }

        final f = lerp(fh2), b = lerp(bh2);
        final iv = rgba[o + c] / 255.0;
        final v = f + a * (iv - a * f - (1 - a) * b);
        out[o + c] = (v * 255 + 0.5).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// F̂＝blur(F·α)/blur(α)、B̂＝blur(B·(1−α))/blur(1−α)（三通道交錯）
(Float32List, Float32List) _estimate(
  Float32List f,
  Float32List b,
  Float32List a,
  int w,
  int h,
  double sigma,
) {
  final n = w * h;
  final pf = Float32List(n * 3), pb = Float32List(n * 3);
  final da = Float32List.fromList(a), db = Float32List(n);
  for (var p = 0; p < n; p++) {
    final v = a[p];
    db[p] = 1 - v;
    for (var c = 0; c < 3; c++) {
      pf[p * 3 + c] = f[p * 3 + c] * v;
      pb[p * 3 + c] = b[p * 3 + c] * (1 - v);
    }
  }
  gaussBlurInPlace(pf, w, h, 3, sigma);
  gaussBlurInPlace(pb, w, h, 3, sigma);
  gaussBlurInPlace(da, w, h, 1, sigma);
  gaussBlurInPlace(db, w, h, 1, sigma);
  for (var p = 0; p < n; p++) {
    final ia = da[p] > 1e-4 ? 1 / da[p] : 0.0;
    final ib = db[p] > 1e-4 ? 1 / db[p] : 0.0;
    for (var c = 0; c < 3; c++) {
      final i = p * 3 + c;
      pf[i] = ia == 0 ? f[i] : pf[i] * ia;
      pb[i] = ib == 0 ? b[i] : pb[i] * ib;
    }
  }
  return (pf, pb);
}

/// 高斯模糊（三次 box 近似，Wells 1986／Kovesi）；邊界取最近的像素。
/// [ch] 個通道交錯
void gaussBlurInPlace(Float32List d, int w, int h, int ch, double sigma) {
  if (sigma < 0.3) return;
  // 三個 box 的寬度，讓總變異數 ≈ σ²
  final wIdeal = math.sqrt(12 * sigma * sigma / 3 + 1);
  var wl = wIdeal.floor();
  if (wl.isEven) wl--;
  final wu = wl + 2;
  final mIdeal =
      (12 * sigma * sigma - 3 * wl * wl - 12 * wl - 9) / (-4 * wl - 4);
  final m = mIdeal.round();
  final tmp = Float32List(d.length);
  for (var i = 0; i < 3; i++) {
    final r = ((i < m ? wl : wu) - 1) ~/ 2;
    if (r <= 0) continue;
    _boxH(d, tmp, w, h, ch, r);
    _boxV(tmp, d, w, h, ch, r);
  }
}

void _boxH(Float32List src, Float32List dst, int w, int h, int ch, int r) {
  final inv = 1 / (2 * r + 1);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var c = 0; c < ch; c++) {
      double at(int x) => src[(row + (x < 0 ? 0 : (x >= w ? w - 1 : x))) * ch + c];
      var s = 0.0;
      for (var x = -r; x <= r; x++) {
        s += at(x);
      }
      for (var x = 0; x < w; x++) {
        dst[(row + x) * ch + c] = s * inv;
        s += at(x + r + 1) - at(x - r);
      }
    }
  }
}

void _boxV(Float32List src, Float32List dst, int w, int h, int ch, int r) {
  final inv = 1 / (2 * r + 1);
  for (var x = 0; x < w; x++) {
    for (var c = 0; c < ch; c++) {
      double at(int y) => src[((y < 0 ? 0 : (y >= h ? h - 1 : y)) * w + x) * ch + c];
      var s = 0.0;
      for (var y = -r; y <= r; y++) {
        s += at(y);
      }
      for (var y = 0; y < h; y++) {
        dst[(y * w + x) * ch + c] = s * inv;
        s += at(y + r + 1) - at(y - r);
      }
    }
  }
}

/// 面積平均縮圖：RGBA（只取 RGB）→ 0~1 三通道、alpha → 0~1
void _areaDown(
  Uint8List rgba,
  Uint8List alpha,
  int w,
  int h,
  Float32List qi,
  Float32List qa,
  int qw,
  int qh,
) {
  if (qw == w && qh == h) {
    for (var p = 0; p < w * h; p++) {
      qi[p * 3] = rgba[p * 4] / 255;
      qi[p * 3 + 1] = rgba[p * 4 + 1] / 255;
      qi[p * 3 + 2] = rgba[p * 4 + 2] / 255;
      qa[p] = alpha[p] / 255;
    }
    return;
  }
  final sx = w / qw, sy = h / qh;
  for (var qy = 0; qy < qh; qy++) {
    final y0 = (qy * sy).floor(), y1 = math.min(h, ((qy + 1) * sy).ceil());
    for (var qx = 0; qx < qw; qx++) {
      final x0 = (qx * sx).floor(), x1 = math.min(w, ((qx + 1) * sx).ceil());
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      var cnt = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final p = y * w + x;
          r += rgba[p * 4];
          g += rgba[p * 4 + 1];
          b += rgba[p * 4 + 2];
          a += alpha[p];
          cnt++;
        }
      }
      final q = qy * qw + qx;
      final inv = cnt == 0 ? 0.0 : 1 / (255.0 * cnt);
      qi[q * 3] = r * inv;
      qi[q * 3 + 1] = g * inv;
      qi[q * 3 + 2] = b * inv;
      qa[q] = a * inv;
    }
  }
}
