import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../nav.dart';
import '../services/crop_math.dart';
import '../theme.dart';

/// 開裁切畫面，回傳裁好的 PNG；使用者取消回 null。
///
/// 每個「加圖片」的入口都走這裡：浮水印 Logo、時間軸的圖片素材，
/// 拿到的都是一份 bytes，裁完還是一份 bytes，呼叫端不用改自己的流程。
Future<Uint8List?> cropImage(BuildContext context, Uint8List bytes) async {
  final out = await Navigator.of(context).push<Object>(
    editRoute(fullscreenDialog: true, builder: (_) => CropScreen(bytes: bytes)),
  );
  return out is Uint8List ? out : null;
}

/// 只要「裁切框」，不要裁好的圖：回傳 0~1 的比例框（取消回 null）。
///
/// 影片走這條：影片不能真的裁成一張圖，是把框換算成片段的縮放與位移
/// （預覽、合成播放器、兩條匯出管線本來就都吃這三個值），所以裁切
/// 完全不用重編碼、也不會多一份檔案。[frame] 是拿來當底圖的那一格，
/// [initial] 是現在的框（重新開啟時要回到原本的位置）
Future<Rect?> pickCropRect(
  BuildContext context,
  Uint8List frame, {
  Rect? initial,
}) async {
  final out = await Navigator.of(context).push<Object>(
    editRoute(
      fullscreenDialog: true,
      builder: (_) =>
          CropScreen(bytes: frame, rectOnly: true, initial: initial),
    ),
  );
  return out is Rect ? out : null;
}

/// 裁切比例的選項。null＝自由。
/// 自由最前，其餘照首位數字由小到大——跟影片／批次／照片編輯的比例
/// 視窗同一個順序（使用者指定全 App 統一，見 video_processor 的 ratioOrder）
const _kRatios = <(String, double?)>[
  ('自由', null),
  ('1:1', 1),
  ('3:4', 3 / 4),
  ('4:3', 4 / 3),
  ('9:16', 9 / 16),
  ('16:9', 16 / 9),
];

class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.bytes,
    this.rectOnly = false,
    this.initial,
  });

  final Uint8List bytes;

  /// true＝按完成回傳 0~1 的框，不真的把圖裁下來
  final bool rectOnly;

  /// 進來時框要停在哪（0~1）。null＝整張
  final Rect? initial;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  /// 目前要裁的那張圖。轉向是「先把圖轉好」再裁——裁切的數學只要
  /// 處理一個朝向，少一整組座標換算就少一整組會錯的地方
  ui.Image? _img;
  bool _busy = false;
  double? _ratio;

  /// 裁切框，單位是「圖片像素」。顯示時再換算成畫面座標
  Rect _crop = Rect.zero;

  @override
  void initState() {
    super.initState();
    _decode(widget.bytes);
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  Future<void> _decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _img?.dispose();
        _img = frame.image;
        final iw = frame.image.width.toDouble();
        final ih = frame.image.height.toDouble();
        final f = widget.initial;
        _crop = f == null
            ? Rect.fromLTWH(0, 0, iw, ih)
            : Rect.fromLTWH(
                f.left * iw,
                f.top * ih,
                f.width * iw,
                f.height * ih,
              );
      });
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  /// 還原：框回到整張圖。
  ///
  /// 呼叫端進來時給的是「沒裁過的原圖」，所以框拉回整張、按完成
  /// 就等於把之前裁掉的部分要回來了
  void _resetCrop() {
    final img = _img;
    if (img == null) return;
    setState(() {
      _ratio = null;
      _crop = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    });
  }

  /// 把裁切框套上比例（以中心為準往內縮，保證不會超出圖）
  void _applyRatio(double? r) {
    final img = _img;
    setState(() => _ratio = r);
    if (r == null || img == null) return;
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    var w = _crop.width;
    var h = w / r;
    if (h > ih) {
      h = ih;
      w = h * r;
    }
    if (w > iw) {
      w = iw;
      h = w / r;
    }
    final c = _crop.center;
    var x = c.dx - w / 2;
    var y = c.dy - h / 2;
    x = x.clamp(0.0, iw - w);
    y = y.clamp(0.0, ih - h);
    setState(() => _crop = Rect.fromLTWH(x, y, w, h));
  }

  Future<void> _done() async {
    final img = _img;
    if (img == null || _busy) return;
    final r = _crop;
    if (widget.rectOnly) {
      final iw = img.width.toDouble();
      final ih = img.height.toDouble();
      Navigator.pop(
        context,
        Rect.fromLTWH(r.left / iw, r.top / ih, r.width / iw, r.height / ih),
      );
      return;
    }
    setState(() => _busy = true);
    final w = math.max(1, r.width.round());
    final h = math.max(1, r.height.round());
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawImageRect(
      img,
      r,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final pic = rec.endRecording();
    final out = await pic.toImage(w, h);
    pic.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (!mounted) return;
    if (data == null) {
      setState(() => _busy = false);
      return;
    }
    Navigator.pop(context, data.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        actions: [
          IconButton(
            tooltip: '還原（框回到整張圖）',
            onPressed: _busy || img == null ? null : _resetCrop,
            icon: const Icon(Icons.restore),
          ),
          TextButton(
            onPressed: _busy || img == null ? null : _done,
            child: const Text(
              '完成',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      body: img == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _CropArea(
                    image: img,
                    crop: _crop,
                    ratio: _ratio,
                    onCrop: (r) => setState(() => _crop = r),
                  ),
                ),
                // 六格等分一排，什麼寬度都不用捲。原本是可捲的 ListView，
                // 排在最後那一格在 390 寬的機子上會被切掉一半、也沒有任何
                // 「還可以捲」的暗示；順序改成首位數字由小到大之後，最後
                // 一格正好是最常用的 16:9，不能讓它藏在畫面外
                SizedBox(
                  height: 58,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        for (final (i, (label, r)) in _kRatios.indexed)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
                              child: _RatioChip(
                                label: label,
                                on: _ratio == r,
                                onTap: () => _applyRatio(r),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
    );
  }
}

class _RatioChip extends StatelessWidget {
  const _RatioChip({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          // 左右 10：六格等分時一格約 55 寬，「16:9」要放得進去
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: on ? kAmber : kPanelHi,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: on ? Colors.black : kText,
            ),
          ),
        ),
      ),
    );
  }
}

/// 圖片＋裁切框。手勢一律在「畫面座標」上算，改完再換回圖片像素
class _CropArea extends StatefulWidget {
  const _CropArea({
    required this.image,
    required this.crop,
    required this.ratio,
    required this.onCrop,
  });

  final ui.Image image;
  final Rect crop;
  final double? ratio;
  final ValueChanged<Rect> onCrop;

  @override
  State<_CropArea> createState() => _CropAreaState();
}

class _CropAreaState extends State<_CropArea> {
  /// 手指按下抓到什麼：0~3＝四個角、4~7＝左上右下四條邊、
  /// -1＝整塊搬，null＝沒在拖
  int? _grab;
  Rect? _startCrop;

  // 角落的判定半徑。26 太小：框拉滿整張圖時角落貼著邊，手指又粗，
  // 十次有八次抓成「整塊搬」——而框已經滿版根本搬不動，看起來就是
  //「無法縮放」。加大到 44（系統建議的最小觸控目標）
  static const double _handle = 44;
  static const double _edge = 30; // 邊的判定寬度
  static const double _minSide = 32; // 裁切框最小邊長（畫面像素）

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final iw = widget.image.width.toDouble();
        final ih = widget.image.height.toDouble();
        // 留白留在「手勢範圍裡面」而不是外面：本來是外層包 Padding，
        // 圖片外那一圈完全不吃觸控，而角落的把手正好畫在邊界上——
        // 手指稍微落到框外就什麼反應都沒有（右邊特別明顯，因為圖片
        // 常常是被寬度限制、左右緊貼邊）
        const pad = 18.0;
        final k = math.min(
          (box.maxWidth - pad * 2) / iw,
          (box.maxHeight - pad * 2) / ih,
        );
        final dw = iw * k;
        final dh = ih * k;
        final ox = (box.maxWidth - dw) / 2;
        final oy = (box.maxHeight - dh) / 2;
        final view = Rect.fromLTWH(ox, oy, dw, dh);

        Rect toView(Rect r) => Rect.fromLTWH(
          ox + r.left * k,
          oy + r.top * k,
          r.width * k,
          r.height * k,
        );
        Rect toImage(Rect r) => Rect.fromLTWH(
          (r.left - ox) / k,
          (r.top - oy) / k,
          r.width / k,
          r.height / k,
        );

        final cropView = toView(widget.crop);

        void onDown(Offset p) {
          _startCrop = cropView;
          final corners = [
            cropView.topLeft,
            cropView.topRight,
            cropView.bottomLeft,
            cropView.bottomRight,
          ];
          // 取「最近的那個角」而不是第一個碰到的：熱區加大之後
          // 相鄰兩個角可能同時在範圍內，抓錯角會往反方向縮
          _grab = -1;
          var best = _handle;
          for (var i = 0; i < 4; i++) {
            final d = (corners[i] - p).distance;
            if (d <= best) {
              best = d;
              _grab = i;
            }
          }
          if (_grab != -1) return;
          // 沒抓到角就試四條邊（鎖比例時邊不能單獨動，跳過）。
          // 4=左 5=上 6=右 7=下
          if (widget.ratio == null) {
            final withinY =
                p.dy >= cropView.top - _edge && p.dy <= cropView.bottom + _edge;
            final withinX =
                p.dx >= cropView.left - _edge && p.dx <= cropView.right + _edge;
            if (withinY && (p.dx - cropView.left).abs() <= _edge) {
              _grab = 4;
            } else if (withinY && (p.dx - cropView.right).abs() <= _edge) {
              _grab = 6;
            } else if (withinX && (p.dy - cropView.top).abs() <= _edge) {
              _grab = 5;
            } else if (withinX && (p.dy - cropView.bottom).abs() <= _edge) {
              _grab = 7;
            }
          }
        }

        void onMove(Offset delta) {
          final start = _startCrop;
          final g = _grab;
          if (start == null || g == null) return;
          Rect next;
          if (g == -1) {
            next = start.shift(delta);
            // 整塊搬：撞到邊就停住，不要縮小
            final x = next.left
                .clamp(view.left, math.max(view.left, view.right - next.width))
                .toDouble();
            final y = next.top
                .clamp(view.top, math.max(view.top, view.bottom - next.height))
                .toDouble();
            next = Rect.fromLTWH(x, y, next.width, next.height);
          } else {
            var l = start.left;
            var t = start.top;
            var r = start.right;
            var b = start.bottom;
            if (g == 0 || g == 2 || g == 4) l = start.left + delta.dx;
            if (g == 1 || g == 3 || g == 6) r = start.right + delta.dx;
            if (g == 0 || g == 1 || g == 5) t = start.top + delta.dy;
            if (g == 2 || g == 3 || g == 7) b = start.bottom + delta.dy;
            l = l.clamp(view.left, view.right - _minSide);
            t = t.clamp(view.top, view.bottom - _minSide);
            r = r.clamp(view.left + _minSide, view.right);
            b = b.clamp(view.top + _minSide, view.bottom);
            next = Rect.fromLTRB(
              math.min(l, r - _minSide),
              math.min(t, b - _minSide),
              math.max(r, l + _minSide),
              math.max(b, t + _minSide),
            );
            // 鎖比例時，用被拖的那個角當支點重算另一邊（onDown 在
            // 鎖比例時不會給出邊，這裡只會是角）
            final ratio = widget.ratio;
            if (ratio != null && g < 4) {
              var w = next.width;
              var h = w / ratio;
              if (h > view.height) {
                h = view.height;
                w = h * ratio;
              }
              final anchorX = (g == 0 || g == 2) ? next.right : next.left;
              final anchorY = (g == 0 || g == 1) ? next.bottom : next.top;
              var x = (g == 0 || g == 2) ? anchorX - w : anchorX;
              var y = (g == 0 || g == 1) ? anchorY - h : anchorY;
              x = x.clamp(view.left, math.max(view.left, view.right - w));
              y = y.clamp(view.top, math.max(view.top, view.bottom - h));
              next = Rect.fromLTWH(x, y, w, h);
            }
          }
          widget.onCrop(toImage(next));
        }

        /// 雙指：以起手的框為基準，每次都從基準算（不累乘才不會飄）。
        ///
        /// 自由模式各軸獨立——每條邊跟著同一側的手指走同樣的距離；鎖比例
        /// 就等比，繞著兩指的中點（數學在 crop_math.dart）。手指位置從
        /// 自己記的 [_fingers] 來；拿不到手指位置（觸控板的捏合）就退回
        /// recognizer 給的單一倍率，等比
        void onPinch(ScaleUpdateDetails d) {
          final start = _startCrop;
          if (start == null) return;
          final f0 = _fingersStart;
          final f = _fingerBounds();
          final Rect next;
          if (f0 == null || f == null) {
            next = pinchCropUniform(
              start: start,
              view: view,
              minSide: _minSide,
              ratio: widget.ratio,
              scale: d.scale,
              focal: _pinchFocal ?? d.localFocalPoint,
              pan: d.localFocalPoint - (_grabStart ?? d.localFocalPoint),
            );
          } else if (widget.ratio == null) {
            next = pinchCropFree(
              start: start,
              view: view,
              minSide: _minSide,
              fingersStart: f0,
              fingers: f,
            );
          } else {
            // 兩指距離＝包住兩指那個方框的對角線
            final d0 = Offset(f0.width, f0.height).distance;
            next = pinchCropUniform(
              start: start,
              view: view,
              minSide: _minSide,
              ratio: widget.ratio,
              scale: d0 > 0 ? Offset(f.width, f.height).distance / d0 : 1,
              focal: f0.center,
              pan: f.center - f0.center,
            );
          }
          widget.onCrop(toImage(next));
        }

        // 用 onScale 而不是 onPan：ScaleGestureRecognizer 一根手指
        // 也收得到（scale 恆為 1），所以單指拖角／拖邊／搬整塊的行為
        // 完全照舊，兩根手指時才多一條縮放的路。
        //
        // 外面再包一層 Listener 記每根手指在哪：recognizer 只給「兩指
        // 距離變成幾倍」這種比例，自由模式要的是「每根手指各拉了多遠」。
        // 手指數一變（第二指放上、一指放開）就以那一刻重新起手——
        // recognizer 自己也是在同一刻重設基準（先 onEnd 再 onStart）
        return Listener(
          onPointerDown: (e) {
            _fingers[e.pointer] = e.localPosition;
            _fingersStart = _fingerBounds();
          },
          onPointerMove: (e) {
            _fingers[e.pointer] = e.localPosition;
          },
          onPointerUp: (e) {
            _fingers.remove(e.pointer);
            _fingersStart = _fingerBounds();
          },
          onPointerCancel: (e) {
            _fingers.remove(e.pointer);
            _fingersStart = _fingerBounds();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (d) {
              _grabStart = d.localFocalPoint;
              _pinchFocal = d.localFocalPoint;
              _startCrop = cropView;
              _pinching = d.pointerCount >= 2;
              if (!_pinching) onDown(d.localFocalPoint);
            },
            onScaleUpdate: (d) {
              final startPt = _grabStart ?? d.localFocalPoint;
              if (d.pointerCount >= 2) {
                // 第二根手指中途才放上來：以這一刻重新起手，
                // 不然框會從舊的基準瞬間跳一下
                if (!_pinching) {
                  _pinching = true;
                  _grab = null;
                  _grabStart = d.localFocalPoint;
                  _pinchFocal = d.localFocalPoint;
                  _startCrop = cropView;
                  _fingersStart = _fingerBounds();
                  return;
                }
                onPinch(d);
                return;
              }
              if (_pinching) return; // 放開一指之後不要接著單指亂拖
              onMove(d.localFocalPoint - startPt);
            },
            onScaleEnd: (_) {
              _grab = null;
              _grabStart = null;
              _pinchFocal = null;
              _pinching = false;
            },
            child: CustomPaint(
              size: Size(box.maxWidth, box.maxHeight),
              painter: _CropPainter(
                image: widget.image,
                view: view,
                crop: cropView,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 這一次拖曳的起點（localPosition），用來算「從按下到現在」的位移
  Offset? _grabStart;

  /// 雙指縮放中；起手時 recognizer 給的焦點——只有拿不到手指位置
  /// （觸控板的捏合）時才用它當等比縮放的中心
  bool _pinching = false;
  Offset? _pinchFocal;

  /// 現在按在畫面上的每根手指（pointer id → 畫面座標）
  final _fingers = <int, Offset>{};

  /// 雙指起手時「把所有手指包起來的方框」；少於兩根手指就是 null
  Rect? _fingersStart;

  Rect? _fingerBounds() {
    if (_fingers.length < 2) return null;
    var l = double.infinity;
    var t = double.infinity;
    var r = double.negativeInfinity;
    var b = double.negativeInfinity;
    for (final p in _fingers.values) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.image, required this.view, required this.crop});

  final ui.Image image;
  final Rect view;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      view,
      Paint()..filterQuality = FilterQuality.high,
    );
    // 框外壓暗
    final dim = Paint()..color = const Color(0xB3000000);
    canvas.save();
    canvas.clipRect(crop, clipOp: ui.ClipOp.difference);
    canvas.drawRect(Offset.zero & size, dim);
    canvas.restore();
    // 三分格
    final grid = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = crop.left + crop.width * i / 3;
      final y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), grid);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), grid);
    }
    // 外框
    canvas.drawRect(
      crop,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = kSelect,
    );
    // 四個角把手
    final h = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round
      ..color = kSelect;
    const arm = 20.0;
    void corner(Offset p, double sx, double sy) {
      canvas.drawLine(p, p + Offset(arm * sx, 0), h);
      canvas.drawLine(p, p + Offset(0, arm * sy), h);
    }

    corner(crop.topLeft, 1, 1);
    corner(crop.topRight, -1, 1);
    corner(crop.bottomLeft, 1, -1);
    corner(crop.bottomRight, -1, -1);
    // 四條邊的中點也給一小段把手：邊是可以單獨拉的（自由模式），
    // 沒有記號沒人知道
    const tick = 13.0;
    final cx = crop.center.dx;
    final cy = crop.center.dy;
    canvas.drawLine(
      Offset(cx - tick, crop.top),
      Offset(cx + tick, crop.top),
      h,
    );
    canvas.drawLine(
      Offset(cx - tick, crop.bottom),
      Offset(cx + tick, crop.bottom),
      h,
    );
    canvas.drawLine(
      Offset(crop.left, cy - tick),
      Offset(crop.left, cy + tick),
      h,
    );
    canvas.drawLine(
      Offset(crop.right, cy - tick),
      Offset(crop.right, cy + tick),
      h,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.view != view || old.crop != crop;
}
