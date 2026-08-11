import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../models/watermark_settings.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';
import 'presets_screen.dart';

/// 製作浮水印：在示意畫面上設計浮水印、存成範本。
/// 帶 [edit] 進來＝編輯既有範本（載入它的設定、儲存鈕預選它的名字）
class WatermarkStudioScreen extends StatefulWidget {
  final WatermarkPreset? edit;

  const WatermarkStudioScreen({super.key, this.edit});

  @override
  State<WatermarkStudioScreen> createState() => _WatermarkStudioScreenState();
}

class _WatermarkStudioScreenState extends State<WatermarkStudioScreen> {
  final _settings = WatermarkSettings();
  bool _lightBg = false; // 示意畫面底色：黑 / 白

  /// 示意畫面比例：直式影片的浮水印要在對的比例下設計才準
  static const _ratios = [('16:9', 16 / 9), ('9:16', 9 / 16), ('1:1', 1.0)];
  int _ratioIdx = 0;

  /// 進來時的設定快照，離開時比對有沒有改過
  late String _initialJson;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    if (e != null) {
      _settings.text = e.settings.text.copy();
      _settings.logo = e.settings.logo.copy();
      // 動畫設定也要帶過來，不然存回去時會把範本的動畫洗掉
      _settings.animation = e.settings.animation;
      _settings.animSpeed = e.settings.animSpeed;
      _settings.animRange = e.settings.animRange;
    }
    _initialJson = jsonEncode(_settings.toJson());
  }

  bool get _dirty => jsonEncode(_settings.toJson()) != _initialJson;

  /// 離開保護：改過但沒存範本就問一下
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final ok = await showConfirm(
      context,
      title: '放棄這個浮水印？',
      message: '還沒儲存成範本，離開後設計會消失',
      action: '放棄離開',
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  // ===== 上一步（改壞了可以救；連續滑桿拖動 0.7 秒內併成一步）=====
  final List<String> _undo = [];
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _sync = 0; // 通知面板同步內部狀態

  /// 拖曳浮水印時只重畫預覽區——整頁 setState 會連下面整片
  /// 設定面板一起重建，拖起來會頓
  final ValueNotifier<int> _wmTick = ValueNotifier(0);

  @override
  void dispose() {
    _wmTick.dispose();
    super.dispose();
  }

  void _pushUndo() {
    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < 700) return;
    _lastPush = now;
    _undo.add(jsonEncode(_settings.toJson()));
    if (_undo.length > 60) _undo.removeAt(0);
    setState(() {}); // 讓上一步鈕亮起來
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    final wm = WatermarkSettings.fromJson(
        jsonDecode(_undo.removeLast()) as Map<String, dynamic>);
    setState(() {
      _settings.text = wm.text;
      _settings.logo = wm.logo;
      _settings.animation = wm.animation;
      _settings.animSpeed = wm.animSpeed;
      _settings.animRange = wm.animRange;
      _wmPart = WmPart.none; // 復原可能讓被選的部件消失，選取殘留會卡死拖曳
      _sync++;
    });
  }

  // ===== 選取（選了圖片就鎖定圖片：拖曳/縮放都只動它）=====
  WmPart _wmPart = WmPart.none;

  /// 被選部件還活著嗎（存在、非平鋪）；不活一律當沒選
  WmPart get _wmPartAlive {
    final t = _settings.text;
    final lg = _settings.logo;
    return switch (_wmPart) {
      WmPart.text when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
        WmPart.text,
      WmPart.logo when lg.enabled && !lg.tiled => WmPart.logo,
      _ => WmPart.none,
    };
  }

  // ===== 雙指縮放（示意畫面上直接捏）=====
  final Map<int, Offset> _pvPts = {};
  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;

  void _pinchDown(PointerDownEvent e) {
    _pvPts[e.pointer] = e.position;
    if (_pvPts.length != 2) return;
    final p = _pvPts.values.toList();
    final d = (p[0] - p[1]).distance;
    if (d <= 20) return;
    _pvBaseDist = d;
    _pvBaseText = _settings.text.sizeFrac;
    _pvBaseLogo = _settings.logo.sizeFrac;
    _pushUndo();
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    final t = _settings.text;
    final hasText = t.enabled && t.text.trim().isNotEmpty;
    final hasLogo = _settings.logo.enabled;
    // 有選取只動被選的；都沒選而兩個都在才一起動
    final part = _wmPartAlive;
    final doText = hasText && (part != WmPart.logo || !hasLogo);
    final doLogo = hasLogo && (part != WmPart.text || !hasText);
    if (doText) t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
    if (doLogo) {
      _settings.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
    }
    _wmTick.value++;
  }

  void _pinchUp(int pointer) {
    _pvPts.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) {
      _pvBaseDist = null;
      setState(() {}); // 面板的大小滑桿要跟上捏完的值
    }
  }

  // ===== 選取路由的置中吸附（跟其他編輯器同手感）=====
  double? _stRawX, _stRawY;
  bool _stGuideV = false, _stGuideH = false;
  bool _stSnapped = false;

  double _snapC(double v) => (v - 0.5).abs() < 0.015 ? 0.5 : v;

  void _stSetGuides(double x, double y) {
    final v = x == 0.5, hh = y == 0.5;
    if (v != _stGuideV || hh != _stGuideH) {
      _stGuideV = v;
      _stGuideH = hh;
    }
    final on = v || hh;
    if (on != _stSnapped) {
      _stSnapped = on;
      if (on) HapticFeedback.selectionClick();
    }
    _wmTick.value++;
  }

  void _stClearGuides() {
    _stRawX = null;
    _stRawY = null;
    _stSnapped = false;
    if (_stGuideV || _stGuideH) {
      _stGuideV = false;
      _stGuideH = false;
      _wmTick.value++;
    }
  }

  /// 底色切換：迷你分段控制（黑／白）
  Widget _bgSegment() {
    Widget seg(String label, bool light) {
      final active = _lightBg == light;
      return InkWell(
        onTap: () => setState(() => _lightBg = light),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          color: active ? kPanelHi : Colors.transparent,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: active ? kAmber : kTextDim,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        decoration: BoxDecoration(
          color: kPanel.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [seg('黑', false), seg('白', true)],
        ),
      ),
    );
  }

  /// 比例切換：迷你分段控制（16:9／9:16／1:1）
  Widget _ratioSegment() {
    Widget seg(int i) {
      final active = _ratioIdx == i;
      return InkWell(
        onTap: () => setState(() => _ratioIdx = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          color: active ? kPanelHi : Colors.transparent,
          child: Text(
            _ratios[i].$1,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: active ? kAmber : kTextDim,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        decoration: BoxDecoration(
          color: kPanel.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < _ratios.length; i++) seg(i)],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('製作浮水印'),
        actions: [
          IconButton(
            tooltip: '上一步',
            icon: const Icon(Icons.undo),
            onPressed: _undo.isEmpty ? null : _undoLast,
          ),
          IconButton(
            tooltip: '我的範本',
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const PresetsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          // 示意畫面（拖曳浮水印調位置）；固定高度，比例改變時畫布置中縮放
          Container(
            height: 250,
            width: double.infinity,
            color: const Color(0xFF1B1B1F),
            child: Stack(
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: _wmTick,
                  builder: (context, _, _) => Listener(
                    // 雙指縮放（用 Listener 不搶單指拖曳手勢）
                    onPointerDown: _pinchDown,
                    onPointerMove: _pinchMove,
                    onPointerUp: (e) => _pinchUp(e.pointer),
                    onPointerCancel: (e) => _pinchUp(e.pointer),
                    child: GestureDetector(
                      // 點空白＝取消選取
                      onTap: () {
                        if (_wmPart != WmPart.none) {
                          setState(() => _wmPart = WmPart.none);
                        }
                      },
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _ratios[_ratioIdx].$2,
                          child: Container(
                            color: _lightBg ? Colors.white : Colors.black,
                            child: Stack(
                              clipBehavior: Clip.none,
                              fit: StackFit.expand,
                              children: [
                                // 底就是純色，不放示意圖示——那個山形圖案
                                // 會被誤認成浮水印的一部分
                                WatermarkLayer(
                                  settings: _settings,
                                  onChanged: () => _wmTick.value++,
                                  onDragStart: _pushUndo,
                                  // 選取鎖定：選了圖片就只動圖片
                                  selectedPart: _wmPartAlive,
                                  onSelectPart: (p) =>
                                      setState(() => _wmPart = p),
                                  panLocked: () => _pvPts.length >= 2,
                                ),
                                // 置中輔助線（路由拖曳吸中線時）
                                if (_stGuideV || _stGuideH)
                                  Positioned.fill(
                                    child: CenterGuides(
                                      vertical: _stGuideV,
                                      horizontal: _stGuideH,
                                    ),
                                  ),
                                // 選取路由：有部件被選取時，整個示意
                                // 畫面的拖曳都只動被選的那個
                                if (_wmPartAlive != WmPart.none)
                                  Positioned.fill(
                                    child: LayoutBuilder(
                                      builder: (context, box) {
                                        final w = box.maxWidth;
                                        final h = box.maxHeight;
                                        return GestureDetector(
                                          behavior:
                                              HitTestBehavior.translucent,
                                          onPanStart: (_) {
                                            _stClearGuides();
                                            if (_pvPts.length < 2) {
                                              _pushUndo();
                                            }
                                          },
                                          onPanUpdate: (d) {
                                            if (_pvPts.length >= 2) return;
                                            final t = _settings.text;
                                            final lg = _settings.logo;
                                            final part = _wmPartAlive;
                                            // 原始座標累積、顯示值吸中線
                                            if (part == WmPart.text) {
                                              _stRawX ??= t.x;
                                              _stRawY ??= t.y;
                                              _stRawX =
                                                  (_stRawX! +
                                                          d.delta.dx / w)
                                                      .clamp(0.0, 1.0);
                                              _stRawY =
                                                  (_stRawY! +
                                                          d.delta.dy / h)
                                                      .clamp(0.0, 1.0);
                                              t.x = _snapC(_stRawX!);
                                              t.y = _snapC(_stRawY!);
                                              _stSetGuides(t.x, t.y);
                                            } else if (part ==
                                                WmPart.logo) {
                                              _stRawX ??= lg.x;
                                              _stRawY ??= lg.y;
                                              _stRawX =
                                                  (_stRawX! +
                                                          d.delta.dx / w)
                                                      .clamp(0.0, 1.0);
                                              _stRawY =
                                                  (_stRawY! +
                                                          d.delta.dy / h)
                                                      .clamp(0.0, 1.0);
                                              lg.x = _snapC(_stRawX!);
                                              lg.y = _snapC(_stRawY!);
                                              _stSetGuides(lg.x, lg.y);
                                            }
                                          },
                                          onPanEnd: (_) => _stClearGuides(),
                                          onPanCancel: _stClearGuides,
                                          child: const SizedBox.expand(),
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 比例＋底色切換：測試浮水印在不同畫面上的可讀性
                Positioned(
                  right: 8,
                  top: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ratioSegment(),
                      const SizedBox(width: 6),
                      _bgSegment(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: kBorder),
          Expanded(
            child: WatermarkPanel(
              settings: _settings,
              onChanged: () => setState(() {}),
              onBeforeChange: _pushUndo,
              syncVersion: _sync,
              initialPresetName: widget.edit?.name,
              // 存過就把基準對齊現況：沒再改動的話離開不用問放棄
              onSaved: () =>
                  _initialJson = jsonEncode(_settings.toJson()),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
