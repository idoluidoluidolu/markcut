import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 去背遮罩檔（.mcmk）：一支影片每一格的人像遮罩。
///
/// 原生端（iOS Vision／Android ML Kit）邊解碼邊算、邊寫；預覽（Android
/// 的 Flutter 圖層）、匯出（原生合成器、FFmpeg）都讀同一份，所以三條路
/// 看到的是同一張遮罩。格式刻意簡單，Swift／Kotlin／Dart 各寫一份讀寫：
///
/// ```text
/// 0   'MCMK'
/// 4   u16 版本（1）
/// 6   u16 旗標（0）
/// 8   u16 寬
/// 10  u16 高
/// 12  u32 格數
/// 16  u64 索引的位置
/// 24  每一格的資料：寬×高個位元組（0＝背景、255＝人），raw deflate 壓縮
/// 索引 每格 24 位元組：f64 素材秒數、u64 資料位置、u32 長度、u32 保留
/// ```
///
/// 全部小端序。遮罩是「轉正後」的畫面（跟播放器、相簿看到的同一個
/// 方向），座標 0~1 直接對到整張畫面；寬高比不一定跟畫面一樣（ML Kit
/// 固定 256×256），用的時候一律拉滿整張畫面
class CutoutMaskFile {
  CutoutMaskFile._(
    this.path,
    this.width,
    this.height,
    this.pts,
    this._off,
    this._len,
    this._raf,
  );

  static const magic = 0x4B4D434D; // 'MCMK' 小端序讀成 u32
  static const version = 1;
  static const headerBytes = 24;
  static const indexEntryBytes = 24;

  final String path;
  final int width;
  final int height;

  /// 每一格的素材秒數（遞增）
  final Float64List pts;
  final Int64List _off;
  final Uint32List _len;
  RandomAccessFile? _raf;

  int get length => pts.length;

  /// 打開一個遮罩檔；檔案不在、格式不對（寫到一半、舊版）回 null
  static CutoutMaskFile? openSync(String path) {
    RandomAccessFile? raf;
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      raf = f.openSync();
      final size = raf.lengthSync();
      if (size < headerBytes) {
        raf.closeSync();
        return null;
      }
      final h = ByteData.sublistView(raf.readSync(headerBytes));
      if (h.getUint32(0, Endian.little) != magic ||
          h.getUint16(4, Endian.little) != version) {
        raf.closeSync();
        return null;
      }
      final w = h.getUint16(8, Endian.little);
      final hh = h.getUint16(10, Endian.little);
      final n = h.getUint32(12, Endian.little);
      final idx = h.getUint64(16, Endian.little);
      if (w == 0 || hh == 0 || n == 0 || idx + n * indexEntryBytes > size) {
        raf.closeSync();
        return null;
      }
      raf.setPositionSync(idx);
      final ib = ByteData.sublistView(raf.readSync(n * indexEntryBytes));
      final pts = Float64List(n);
      final off = Int64List(n);
      final len = Uint32List(n);
      for (var i = 0; i < n; i++) {
        final o = i * indexEntryBytes;
        pts[i] = ib.getFloat64(o, Endian.little);
        off[i] = ib.getUint64(o + 8, Endian.little);
        len[i] = ib.getUint32(o + 16, Endian.little);
        if (off[i] + len[i] > size) {
          raf.closeSync();
          return null;
        }
      }
      return CutoutMaskFile._(path, w, hh, pts, off, len, raf);
    } catch (_) {
      try {
        raf?.closeSync();
      } catch (_) {}
      return null;
    }
  }

  void close() {
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    _cache.clear();
  }

  /// [t]（素材秒數）那一刻要用哪一格：秒數不超過 t 的最後一格（播放器
  /// 顯示的也是這一格）。比第一格早就用第一格
  int indexAt(double t) {
    final n = pts.length;
    if (n == 0) return -1;
    // 容一點浮點尾數：剛好落在格子上的 t 不要掉到前一格
    final q = t + 1e-4;
    if (q < pts[0]) return 0;
    var lo = 0, hi = n - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (pts[mid] <= q) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 解好的最近幾格（預覽來回拖、匯出一格對到好幾格輸出都會重複要）
  final Map<int, Uint8List> _cache = {};
  final List<int> _order = [];
  static const _cacheMax = 8;

  /// 第 [i] 格的遮罩（寬×高位元組）。讀不到回 null
  Uint8List? frame(int i) {
    if (i < 0 || i >= pts.length) return null;
    final hit = _cache[i];
    if (hit != null) return hit;
    final raf = _raf;
    if (raf == null) return null;
    try {
      raf.setPositionSync(_off[i]);
      final z = raf.readSync(_len[i]);
      final raw = Uint8List.fromList(ZLibDecoder(raw: true).convert(z));
      if (raw.length != width * height) return null;
      _cache[i] = raw;
      _order.add(i);
      if (_order.length > _cacheMax) _cache.remove(_order.removeAt(0));
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// [t]（素材秒數）那一刻的遮罩
  Uint8List? frameAt(double t) => frame(indexAt(t));
}

/// 寫遮罩檔（測試、以及 Dart 端要自己產遮罩時用；原生端各有一份同格式的）
class CutoutMaskWriter {
  CutoutMaskWriter(String path, this.width, this.height)
    : _raf = File(path).openSync(mode: FileMode.write) {
    _raf.writeFromSync(Uint8List(CutoutMaskFile.headerBytes));
  }

  final int width;
  final int height;
  final RandomAccessFile _raf;
  final _entries = <(double, int, int)>[];

  void add(double pts, Uint8List mask) {
    assert(mask.length == width * height);
    final z = ZLibEncoder(raw: true, level: 6).convert(mask);
    final at = _raf.positionSync();
    _raf.writeFromSync(z);
    _entries.add((pts, at, z.length));
  }

  void close() {
    final idx = _raf.positionSync();
    final ib = ByteData(_entries.length * CutoutMaskFile.indexEntryBytes);
    for (var i = 0; i < _entries.length; i++) {
      final (p, o, l) = _entries[i];
      final b = i * CutoutMaskFile.indexEntryBytes;
      ib.setFloat64(b, p, Endian.little);
      ib.setUint64(b + 8, o, Endian.little);
      ib.setUint32(b + 16, l, Endian.little);
    }
    _raf.writeFromSync(ib.buffer.asUint8List());
    final h = ByteData(CutoutMaskFile.headerBytes)
      ..setUint32(0, CutoutMaskFile.magic, Endian.little)
      ..setUint16(4, CutoutMaskFile.version, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, width, Endian.little)
      ..setUint16(10, height, Endian.little)
      ..setUint32(12, _entries.length, Endian.little)
      ..setUint64(16, idx, Endian.little);
    _raf.setPositionSync(0);
    _raf.writeFromSync(h.buffer.asUint8List());
    _raf.closeSync();
  }
}

/// 匯出（FFmpeg）用的遮罩串流：[times] 是每一格輸出畫面要的遮罩秒數，
/// 依序取格、縮到長邊不超過 [maxSide]，攤成 gray 原始位元組寫進
/// [outPath]（FFmpeg 用 -f rawvideo -pix_fmt gray 讀）。
/// 回 (寬, 高)；遮罩檔讀不到回 null。在背景 isolate 跑，匯出的進度條不卡
Future<(int, int)?> writeCutoutRaw({
  required String maskPath,
  required String outPath,
  required List<double> times,
  int maxSide = 320,
}) => Isolate.run(
  () => writeCutoutRawSync(
    maskPath: maskPath,
    outPath: outPath,
    times: times,
    maxSide: maxSide,
  ),
);

/// [writeCutoutRaw] 的本體（同步，測試直接叫）
(int, int)? writeCutoutRawSync({
  required String maskPath,
  required String outPath,
  required List<double> times,
  int maxSide = 320,
}) {
  final m = CutoutMaskFile.openSync(maskPath);
  if (m == null) return null;
  try {
    final long = m.width > m.height ? m.width : m.height;
    var rw = m.width, rh = m.height;
    if (long > maxSide) {
      rw = (m.width * maxSide / long).round();
      rh = (m.height * maxSide / long).round();
    }
    // 偶數：FFmpeg 的 scale 之後還要跟 yuv 畫面 alphamerge
    rw = (rw + 1) & ~1;
    rh = (rh + 1) & ~1;
    final sink = File(outPath).openSync(mode: FileMode.write);
    try {
      var lastI = -2;
      Uint8List? last;
      final blank = Uint8List(rw * rh); // 讀壞的格子：當成全背景
      for (final t in times) {
        final i = m.indexAt(t);
        if (i != lastI) {
          final f = m.frame(i);
          last = f == null ? null : resizeMask(f, m.width, m.height, rw, rh);
          lastI = i;
        }
        sink.writeFromSync(last ?? blank);
      }
    } finally {
      sink.closeSync();
    }
    return (rw, rh);
  } finally {
    m.close();
  }
}

/// 遮罩縮放（雙線性）。尺寸一樣直接回原本那份
Uint8List resizeMask(Uint8List src, int sw, int sh, int dw, int dh) {
  if (sw == dw && sh == dh) return src;
  final out = Uint8List(dw * dh);
  final sx = sw / dw, sy = sh / dh;
  for (var y = 0; y < dh; y++) {
    final fy = ((y + 0.5) * sy - 0.5).clamp(0.0, sh - 1.0);
    final y0 = fy.floor();
    final y1 = y0 + 1 < sh ? y0 + 1 : y0;
    final wy = fy - y0;
    for (var x = 0; x < dw; x++) {
      final fx = ((x + 0.5) * sx - 0.5).clamp(0.0, sw - 1.0);
      final x0 = fx.floor();
      final x1 = x0 + 1 < sw ? x0 + 1 : x0;
      final wx = fx - x0;
      final a = src[y0 * sw + x0] * (1 - wx) + src[y0 * sw + x1] * wx;
      final b = src[y1 * sw + x0] * (1 - wx) + src[y1 * sw + x1] * wx;
      out[y * dw + x] = (a * (1 - wy) + b * wy).round();
    }
  }
  return out;
}

/// 遮罩（寬×高位元組）→ 給 Flutter 畫的 RGBA：白色、alpha＝遮罩。
/// ShaderMask／dstIn 只看 alpha
Uint8List maskToRgba(Uint8List mask) {
  final out = Uint8List(mask.length * 4);
  for (var i = 0, o = 0; i < mask.length; i++, o += 4) {
    final a = mask[i];
    // 預乘：RGB 不超過 alpha，當成預乘或未預乘讀都一樣是「alpha＝遮罩」
    out[o] = a;
    out[o + 1] = a;
    out[o + 2] = a;
    out[o + 3] = a;
  }
  return out;
}
