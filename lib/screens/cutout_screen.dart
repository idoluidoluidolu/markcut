import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/cutout.dart' show kCutoutColors;
import '../services/cutout_detect.dart';
import '../services/cutout_photo.dart';
import '../services/diagnostics.dart';
import '../services/photo_export.dart';
import '../services/video_picker.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart' show CheckerPainter;

/// 照片去背：進來自動找主體（人、寵物、物品）全部留下，點畫面上的主體
/// 切換留不留、筆刷「保留／擦除」修邊、換背景（透明／純色／原圖模糊／
/// 另一張照片），匯出透明 PNG（有背景就出 JPEG）。
///
/// 全部在手機上算（iOS Vision、Android ML Kit，見 CutoutDetect）。預覽
/// 跟匯出畫的是同一支 paintCutout，只是匯出換成原尺寸的照片與遮罩
class CutoutScreen extends StatefulWidget {
  const CutoutScreen({super.key, required this.photo});

  final XFile photo;

  @override
  State<CutoutScreen> createState() => _CutoutScreenState();
}

enum _Tool { subject, brush, background }

/// 預覽用的照片長邊（遮罩也算到這麼大）
const _kPreviewSide = 1600;

/// 分析與匯出的長邊上限
const _kFullSide = 4096;

class _CutoutScreenState extends State<CutoutScreen> {
  ui.Image? _photo;
  CutoutPhoto? _cut;
  ui.Image? _mask;
  bool _analyzing = false;
  bool _maskBusy = false;
  int _maskSeq = 0;
  bool _exporting = false;

  /// 上一趟去背做到一半 App 被關掉：先不自動做，按「重新找主體」才做
  bool _blocked = false;

  PhotoCutState _st = const PhotoCutState(
    ids: {},
    strokes: [],
    bg: PhotoCutBg.clear,
    color: 0xFFFFFFFF,
    bgPath: null,
    feather: 0.2,
  );
  final _undo = <PhotoCutState>[];

  /// 上次匯出（或剛分析完）的樣子：一樣就不用問要不要放棄
  String _savedSig = '';

  _Tool _tool = _Tool.subject;
  bool _keep = true;
  double _brush = 0.06;
  ui.Image? _bgImg;
  String? _bgImgPath;
  CutStroke? _drawing;

  // 預覽縮放（兩指）：以照片框中心為準
  double _zoom = 1;
  Offset _pan = Offset.zero;
  double _zoomStart = 1;
  Offset _panStart = Offset.zero;
  Offset _focalStart = Offset.zero;
  bool _pinching = false;

  /// 照片畫在預覽區的哪裡（每次 build 算）
  Rect _photoRect = Rect.zero;

  @override
  void initState() {
    super.initState();
    _blocked = Diag.fusePaused.containsKey(CutoutDetect.fuseKey);
    unawaited(_load());
  }

  @override
  void dispose() {
    _photo?.dispose();
    _mask?.dispose();
    _bgImg?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final img = await decodePhoto(widget.photo.path, maxSide: _kPreviewSide);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _photo = img);
    } catch (e) {
      if (mounted) showHint(context, '讀不到照片：$e', error: true);
      return;
    }
    if (_blocked) {
      if (mounted) {
        showHint(context, '上次去背到一半被關掉了，按「重新找主體」再試一次');
      }
      return;
    }
    await _analyze();
  }

  Future<void> _analyze() async {
    if (_analyzing) return;
    setState(() {
      _analyzing = true;
      _blocked = false;
    });
    // Android 的主體分割每個像素一個 float（全尺寸 12MP 就是幾十 MB），
    // 分析做到 2048 就好，匯出時遮罩放大（邊緣本來就是柔的）
    final cut = await CutoutDetect.analyzePhoto(
      widget.photo.path,
      maxSide: defaultTargetPlatform == TargetPlatform.android
          ? 2048
          : _kFullSide,
    );
    if (!mounted) return;
    if (cut == null) {
      setState(() => _analyzing = false);
      final why = CutoutDetect.lastErrorBrief;
      showHint(
        context,
        why == null ? '這張照片沒辦法自動去背' : '自動去背失敗\n$why',
        error: true,
      );
      return;
    }
    final mask = await maskToImage(cut.mask, cut.w, cut.h);
    if (!mounted) {
      mask.dispose();
      return;
    }
    final old = _mask;
    setState(() {
      _cut = cut;
      _mask = mask;
      _analyzing = false;
      _st = PhotoCutState(
        ids: {for (final s in cut.subjects) s.id},
        strokes: _st.strokes,
        bg: _st.bg,
        color: _st.color,
        bgPath: _st.bgPath,
        feather: _st.feather,
      );
      _savedSig = _st.signature;
    });
    old?.dispose();
    if (cut.subjects.isEmpty) {
      showHint(context, '沒找到主體，用筆刷「保留」塗出要留下的地方');
      setState(() => _tool = _Tool.brush);
    } else if (cut.person && cut.note != null) {
      // Android：主體模型還沒好（第一次用要下載），這次先只去人
      showHint(context, '這次先只認得出人，之後再開就能認其他東西');
    }
  }

  // ===== 狀態與上一步 =====

  void _push() {
    _undo.add(_st.copy());
    if (_undo.length > 40) _undo.removeAt(0);
  }

  void _undoOne() {
    if (_undo.isEmpty) return;
    final prev = _undo.removeLast();
    final idsChanged = !_sameIds(prev.ids, _st.ids);
    setState(() => _st = prev);
    if (idsChanged) unawaited(_refreshMask());
    if (prev.bg == PhotoCutBg.image && prev.bgPath != _bgImgPath) {
      unawaited(_loadBg(prev.bgPath));
    }
  }

  static bool _sameIds(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  void _toggle(int id) {
    _push();
    final ids = Set.of(_st.ids);
    if (!ids.remove(id)) ids.add(id);
    setState(() => _st = _with(ids: ids));
    unawaited(_refreshMask());
  }

  PhotoCutState _with({
    Set<int>? ids,
    List<CutStroke>? strokes,
    PhotoCutBg? bg,
    int? color,
    String? bgPath,
    double? feather,
  }) => PhotoCutState(
    ids: ids ?? _st.ids,
    strokes: strokes ?? _st.strokes,
    bg: bg ?? _st.bg,
    color: color ?? _st.color,
    bgPath: bgPath ?? _st.bgPath,
    feather: feather ?? _st.feather,
  );

  /// 選的主體變了：跟原生要這幾個的遮罩（最後一次勝出）
  Future<void> _refreshMask() async {
    final cut = _cut;
    if (cut == null) return;
    final seq = ++_maskSeq;
    final ids = _st.ids.toList()..sort();
    setState(() => _maskBusy = true);
    Uint8List? m;
    var w = cut.w, h = cut.h;
    if (ids.isEmpty) {
      m = Uint8List(w * h);
    } else if (_sameIds(_st.ids, {for (final s in cut.subjects) s.id})) {
      m = cut.mask;
    } else {
      final r = await CutoutDetect.photoMask(
        widget.photo.path,
        ids,
        maxSide: math.max(cut.w, cut.h),
      );
      if (r != null) (m, w, h) = r;
    }
    if (seq != _maskSeq || !mounted) return;
    if (m == null) {
      setState(() => _maskBusy = false);
      showHint(context, '主體切換失敗', error: true);
      return;
    }
    final img = await maskToImage(m, w, h);
    if (seq != _maskSeq || !mounted) {
      img.dispose();
      return;
    }
    final old = _mask;
    setState(() {
      _mask = img;
      _maskBusy = false;
    });
    old?.dispose();
  }

  Future<void> _loadBg(String? path) async {
    if (path == null) return;
    try {
      final img = await decodePhoto(path, maxSide: _kPreviewSide);
      if (!mounted) {
        img.dispose();
        return;
      }
      final old = _bgImg;
      setState(() {
        _bgImg = img;
        _bgImgPath = path;
      });
      old?.dispose();
    } catch (e) {
      if (mounted) showHint(context, '讀不到背景照片：$e', error: true);
    }
  }

  // ===== 手勢 =====

  /// 預覽區的一點 → 照片的 0~1 座標（框外回 null）
  Offset? _toPhoto(Offset p) {
    final r = _photoRect;
    if (r.width <= 0 || r.height <= 0) return null;
    return Offset((p.dx - r.left) / r.width, (p.dy - r.top) / r.height);
  }

  void _onTapUp(TapUpDetails d) {
    if (_tool != _Tool.subject) return;
    final cut = _cut;
    final q = _toPhoto(d.localPosition);
    if (cut == null || q == null) return;
    if (q.dx < 0 || q.dy < 0 || q.dx > 1 || q.dy > 1) return;
    final id = cut.subjectAt(q.dx, q.dy);
    if (id > 0) _toggle(id);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _pinching = d.pointerCount >= 2;
    _zoomStart = _zoom;
    _panStart = _pan;
    _focalStart = d.localFocalPoint;
    if (!_pinching && _tool == _Tool.brush) {
      final q = _toPhoto(d.localFocalPoint);
      if (q == null) return;
      _push();
      _drawing = CutStroke(keep: _keep, width: _brush / _zoom, points: [q]);
      setState(() => _st = _with(strokes: [..._st.strokes, _drawing!]));
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2 || _pinching) {
      if (!_pinching) {
        // 一指畫到一半第二指放下來：這一筆收掉（不留一條歪線）
        _pinching = true;
        _endStroke();
      }
      setState(() {
        _zoom = (_zoomStart * d.scale).clamp(1.0, 8.0);
        _pan = _panStart + (d.localFocalPoint - _focalStart);
      });
      return;
    }
    final s = _drawing;
    if (s == null) return;
    final q = _toPhoto(d.localFocalPoint);
    if (q == null) return;
    setState(() => s.points.add(q));
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _endStroke();
    if (_zoom <= 1.001) setState(() => _pan = Offset.zero);
  }

  void _endStroke() {
    _drawing = null;
  }

  // ===== 匯出 =====

  bool get _dirty => _st.signature != _savedSig;

  Future<void> _export() async {
    final photo = _photo;
    if (_exporting || photo == null) return;
    if (_analyzing) {
      showHint(context, '還在找主體，等一下再匯出');
      return;
    }
    if (_st.ids.isEmpty && !_st.strokes.any((s) => s.keep)) {
      showHint(context, '還沒有留下任何主體', error: true);
      return;
    }
    setState(() => _exporting = true);
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('匯出中…'),
          content: SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);
    var ok = true;
    var message = '';
    final st = _st.copy();
    ui.Image? full, mask, bg, out;
    try {
      final path = widget.photo.path;
      full = await decodePhoto(path, maxSide: _kFullSide);
      final long = math.max(full.width, full.height);
      final cut = _cut;
      if (cut != null && st.ids.isNotEmpty) {
        final r = await CutoutDetect.photoMask(
          path,
          st.ids.toList()..sort(),
          maxSide: long,
        );
        if (r == null) throw StateError('原尺寸遮罩做不出來');
        mask = await maskToImage(r.$1, r.$2, r.$3);
      }
      if (st.bg == PhotoCutBg.image && st.bgPath != null) {
        bg = await decodePhoto(st.bgPath!, maxSide: long);
      }
      out = await renderCutout(
        w: full.width,
        h: full.height,
        photo: full,
        mask: mask,
        strokes: st.strokes,
        bg: st.bg,
        color: st.color,
        bgImage: bg,
        feather: st.feather,
      );
      // 透明背景要 PNG（JPEG 沒有透明）；換了背景就是一般照片，出 JPEG
      final (msg, _) = await savePhotoImage(
        out,
        jpeg: st.bg != PhotoCutBg.clear,
        quality: 92,
        name: 'cutout_${DateTime.now().millisecondsSinceEpoch}',
        sourcePath: path,
      );
      message = msg;
    } catch (e) {
      ok = false;
      message = '匯出失敗：$e';
    } finally {
      full?.dispose();
      mask?.dispose();
      bg?.dispose();
      out?.dispose();
    }
    if (!mounted) return;
    if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    setState(() => _exporting = false);
    if (!ok) {
      showHint(context, message, error: true);
      return;
    }
    _savedSig = st.signature;
    final act = await askAfterExport(context, message);
    if (act == 'home' && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    return showConfirm(
      context,
      title: '放棄這次去背？',
      action: '放棄',
    );
  }

  // ===== 畫面 =====

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg,
          title: const Text('去背'),
          actions: [
            IconButton(
              tooltip: '上一步',
              icon: const Icon(Icons.undo),
              onPressed: _undo.isEmpty ? null : _undoOne,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _photo == null || _exporting ? null : _export,
                child: const Text('匯出'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(child: _preview()),
              _panel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    final photo = _photo;
    return LayoutBuilder(
      builder: (context, box) {
        if (photo == null) {
          return const Center(child: CircularProgressIndicator());
        }
        const pad = 12.0;
        final aw = math.max(1.0, box.maxWidth - pad * 2);
        final ah = math.max(1.0, box.maxHeight - pad * 2);
        final pa = photo.width / photo.height;
        var w = aw, h = aw / pa;
        if (h > ah) {
          h = ah;
          w = ah * pa;
        }
        final c = Offset(box.maxWidth / 2, box.maxHeight / 2) + _pan;
        _photoRect = Rect.fromCenter(center: c, width: w * _zoom, height: h * _zoom);
        return ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CutoutPreviewPainter(
                      rect: _photoRect,
                      photo: photo,
                      // 分析還沒好：先畫原圖（遮罩 null＋沒有筆畫會是全空）
                      mask: _mask,
                      raw: _cut == null && _st.strokes.isEmpty,
                      strokes: _st.strokes,
                      bg: _st.bg,
                      color: _st.color,
                      bgImage: _st.bg == PhotoCutBg.image ? _bgImg : null,
                      feather: _st.feather,
                      version: _paintVersion,
                    ),
                  ),
                ),
                if (_analyzing || _maskBusy)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(child: _busyPill(_analyzing ? '找主體中…' : '更新中…')),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 筆畫一直加點（同一個 list），painter 靠這個數字知道要重畫
  int get _paintVersion =>
      _st.strokes.fold<int>(0, (n, s) => n + s.points.length) +
      _st.strokes.length * 100003;

  Widget _busyPill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
      ],
    ),
  );

  Widget _panel() {
    return Container(
      color: kBg,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 150, child: _toolBody()),
          const SizedBox(height: 8),
          _toolTabs(),
        ],
      ),
    );
  }

  Widget _toolTabs() {
    Widget tab(_Tool t, IconData icon, String label) {
      final on = _tool == t;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _tool = t),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: on ? kText : kIcon),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    color: on ? kText : kTextDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(_Tool.subject, Icons.person_outline, '主體'),
        tab(_Tool.brush, Icons.brush_outlined, '修邊'),
        tab(_Tool.background, Icons.wallpaper_outlined, '背景'),
      ],
    );
  }

  Widget _toolBody() => switch (_tool) {
    _Tool.subject => _subjectBody(),
    _Tool.brush => _brushBody(),
    _Tool.background => _bgBody(),
  };

  Widget _subjectBody() {
    final cut = _cut;
    final photo = _photo;
    final retry = _tile(
      icon: Icons.auto_fix_high_outlined,
      label: '重新找主體',
      on: false,
      onTap: _analyzing ? null : _analyze,
    );
    if (cut == null || photo == null || cut.subjects.isEmpty) {
      return Row(
        children: [
          SizedBox(width: 84, child: retry),
          if (cut != null && cut.subjects.isEmpty) ...[
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '沒找到主體',
                style: TextStyle(color: kTextDim, fontSize: 13),
              ),
            ),
          ],
        ],
      );
    }
    return ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final s in cut.subjects)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _SubjectAvatar(
              photo: photo,
              box: s.box,
              on: _st.ids.contains(s.id),
              onTap: () => _toggle(s.id),
            ),
          ),
        SizedBox(width: 84, child: retry),
      ],
    );
  }

  Widget _brushBody() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      SizedBox(
        height: 62,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _tile(
                icon: Icons.brush_outlined,
                label: '保留',
                on: _keep,
                onTap: () => setState(() => _keep = true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tile(
                icon: Icons.cleaning_services_outlined,
                label: '擦除',
                on: !_keep,
                onTap: () => setState(() => _keep = false),
              ),
            ),
          ],
        ),
      ),
      _slider('大小', _brush, 0.01, 0.2, (v) => setState(() => _brush = v)),
      _slider(
        '柔邊',
        _st.feather,
        0,
        1,
        (v) => setState(() => _st = _with(feather: v)),
        onStart: (_) => _push(),
      ),
    ],
  );

  Widget _bgBody() {
    final st = _st;
    Future<void> setBg(PhotoCutBg bg, {int? color, String? path}) async {
      if (bg == st.bg &&
          (color == null || color == st.color) &&
          (path == null || path == st.bgPath)) {
        return;
      }
      _push();
      setState(() => _st = _with(bg: bg, color: color, bgPath: path));
      if (bg == PhotoCutBg.image) await _loadBg(path ?? _st.bgPath);
    }

    Future<void> pickBgPhoto() async {
      final f = await pickPhotoFile();
      if (f == null || !mounted) return;
      await setBg(PhotoCutBg.image, path: f.path);
    }

    Future<void> customColor() async {
      final v = await pickColor(context, Color(st.color), title: '背景顏色');
      if (v == null || !mounted) return;
      await setBg(PhotoCutBg.color, color: v);
    }

    final swatches = <Widget>[
      for (final c in kCutoutColors)
        _Swatch(
          color: Color(c),
          on: st.bg == PhotoCutBg.color && st.color == c,
          onTap: () => setBg(PhotoCutBg.color, color: c),
        ),
      _Swatch(
        color: null,
        on: st.bg == PhotoCutBg.color && !kCutoutColors.contains(st.color),
        onTap: customColor,
      ),
    ];
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 62,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _tile(
                  icon: Icons.grid_4x4,
                  label: '透明',
                  on: st.bg == PhotoCutBg.clear,
                  onTap: () => setBg(PhotoCutBg.clear),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _tile(
                  icon: Icons.blur_on,
                  label: '模糊',
                  on: st.bg == PhotoCutBg.blur,
                  onTap: () => setBg(PhotoCutBg.blur),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _tile(
                  icon: Icons.image_outlined,
                  label: '照片',
                  on: st.bg == PhotoCutBg.image,
                  onTap: pickBgPhoto,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 30,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: swatches.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) => swatches[i],
          ),
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double v,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    ValueChanged<double>? onStart,
  }) => Row(
    children: [
      SizedBox(
        width: kSliderLabelW,
        child: Text(label, style: const TextStyle(color: kText, fontSize: 13)),
      ),
      Expanded(
        child: Slider(
          value: v.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeStart: onStart,
        ),
      ),
    ],
  );

  Widget _tile({
    required IconData icon,
    required String label,
    required bool on,
    required VoidCallback? onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 62),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      decoration: BoxDecoration(
        color: on ? kPanelHi : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: on ? kAmber : kClipBorder, width: on ? 1.5 : 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 24, color: onTap == null ? kTextDim : (on ? kText : kIcon)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                color: onTap == null ? kTextDim : kText,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CutoutPreviewPainter extends CustomPainter {
  _CutoutPreviewPainter({
    required this.rect,
    required this.photo,
    required this.mask,
    required this.raw,
    required this.strokes,
    required this.bg,
    required this.color,
    required this.bgImage,
    required this.feather,
    required this.version,
  });

  final Rect rect;
  final ui.Image photo;
  final ui.Image? mask;

  /// 還沒去背（分析中）：直接畫原圖
  final bool raw;
  final List<CutStroke> strokes;
  final PhotoCutBg bg;
  final int color;
  final ui.Image? bgImage;
  final double feather;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    if (raw) {
      canvas.drawImageRect(
        photo,
        Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    if (bg == PhotoCutBg.clear) {
      canvas.save();
      canvas.translate(rect.left, rect.top);
      const CheckerPainter(cell: 14).paint(canvas, rect.size);
      canvas.restore();
    }
    paintCutout(
      canvas,
      rect,
      photo: photo,
      mask: mask,
      strokes: strokes,
      bg: bg,
      color: color,
      bgImage: bgImage,
      feather: feather,
    );
  }

  @override
  bool shouldRepaint(_CutoutPreviewPainter o) =>
      o.rect != rect ||
      o.photo != photo ||
      o.mask != mask ||
      o.raw != raw ||
      o.version != version ||
      o.bg != bg ||
      o.color != color ||
      o.bgImage != bgImage ||
      o.feather != feather;
}

/// 一個主體的小頭像：從預覽照片裁它的外框，選著白框、沒選壓暗
class _SubjectAvatar extends StatelessWidget {
  const _SubjectAvatar({
    required this.photo,
    required this.box,
    required this.on,
    required this.onTap,
  });

  final ui.Image photo;
  final Rect box;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 72,
      height: 96,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: on ? kAmber : kClipBorder, width: on ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: on ? 1 : 0.35,
        child: CustomPaint(painter: _CropPainter(photo, box)),
      ),
    ),
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.photo, this.box);

  final ui.Image photo;
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    final pw = photo.width.toDouble(), ph = photo.height.toDouble();
    // 外框放大一點、補成頭像的比例（cover）
    var src = Rect.fromLTWH(
      box.left * pw,
      box.top * ph,
      math.max(1, box.width * pw),
      math.max(1, box.height * ph),
    ).inflate(math.max(box.width * pw, box.height * ph) * 0.06);
    final want = size.width / size.height;
    if (src.width / src.height > want) {
      src = Rect.fromCenter(
        center: src.center,
        width: src.width,
        height: src.width / want,
      );
    } else {
      src = Rect.fromCenter(
        center: src.center,
        width: src.height * want,
        height: src.height,
      );
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = kPanelHi);
    canvas.drawImageRect(
      photo,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CropPainter o) => o.photo != photo || o.box != box;
}

/// 背景色的一顆圓點；[color] 是 null＝自訂（彩虹圈）
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.on, required this.onTap});

  final Color? color;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        gradient: color == null
            ? const SweepGradient(
                colors: [
                  Colors.red,
                  Colors.yellow,
                  Colors.green,
                  Colors.cyan,
                  Colors.blue,
                  Colors.purple,
                  Colors.red,
                ],
              )
            : null,
        border: Border.all(color: on ? kAmber : kClipBorder, width: on ? 2.5 : 1),
      ),
    ),
  );
}
