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
  /// 示意畫面底色：0＝透明（棋盤格）、1＝黑、2＝白。
  ///
  /// 預設透明：做浮水印時最重要的是看清楚「這張圖自己的邊緣到哪裡」，
  /// 純黑或純白底會把同色的邊緣整個吃掉
  int _bgMode = 0;

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
      // copy() 是深拷貝：改這裡不會動到範本清單裡的那一份。
      // 動畫設定也一起帶過來，不然存回去時會把範本的動畫洗掉
      _settings.copyMarksFrom(e.settings.copy());
    }
    _initialJson = jsonEncode(_settings.toJson());
  }

  bool get _dirty => jsonEncode(_settings.toJson()) != _initialJson;

  /// 離開保護：改過但沒存範本就問一下。
  /// 這裡沒有草稿可以留，所以直接給「存成範本」當出口——
  /// 只有「放棄」一條路的話，設計半天會整個蒸發
  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final act = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kBorder),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('還沒存成範本',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: kText)),
                const SizedBox(height: 8),
                const Text('離開後這個設計就會消失',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: kTextDim, height: 1.55)),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'NotoSansTC'),
                  ),
                  onPressed: () => Navigator.pop(context, 'save'),
                  child: const Text('存成範本'),
                ),
                const SizedBox(height: 6),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    foregroundColor: kText,
                    side: const BorderSide(color: kBorder),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => Navigator.pop(context, 'discard'),
                  child: const Text('放棄離開',
                      style: TextStyle(fontSize: 13.5)),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'stay'),
                  style: TextButton.styleFrom(
                    foregroundColor: kTextDim,
                    minimumSize: const Size.fromHeight(40),
                  ),
                  child: const Text('繼續編輯',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (act == 'discard') {
      Navigator.of(context).pop();
    } else if (act == 'save') {
      // 存完才離開；存到一半取消就留在這裡
      await _panelKey.currentState?.savePreset();
      if (mounted && !_dirty) Navigator.of(context).pop();
    }
  }

  /// 讓離開對話框能觸發面板裡的儲存流程
  final _panelKey = GlobalKey<WatermarkPanelState>();

  // ===== 上一步／重做（改壞了可以救；連續滑桿拖動 0.7 秒內併成一步）=====
  final List<String> _undo = [];
  final List<String> _redo = [];
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
    _undo.add(_stateJson);
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear(); // 改了新的東西，原本的重做路線就斷了
    setState(() {}); // 讓上一步鈕亮起來
  }

  String get _stateJson => jsonEncode(_settings.toJson());

  /// 把某個快照套回目前狀態
  void _applyState(String json) {
    final wm = WatermarkSettings.fromJson(
        jsonDecode(json) as Map<String, dynamic>);
    setState(() {
      _settings.copyMarksFrom(wm);
      _wmPart = WmPart.none; // 復原可能讓被選的部件消失，選取殘留會卡死拖曳
      _sync++;
    });
    _wmTick.value++;
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    // 撤銷之前先把現況存進重做堆疊，才回得來
    _redo.add(_stateJson);
    _applyState(_undo.removeLast());
  }

  void _redoLast() {
    if (_redo.isEmpty) return;
    _undo.add(_stateJson);
    _applyState(_redo.removeLast());
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

  // ===== 重疊時的循環選取 =====
  /// 文字和 Logo 畫在哪（由 WatermarkLayer 回報）。
  /// Logo 放大置中把文字整個蓋住時，這裡本來永遠點不到文字——
  /// 而工作室沒有時間軸也沒有清單，沒有第二條路可以選它
  Rect? _stTextBox;

  /// 每一張圖片畫在哪（跟 _settings.logos 一一對應）
  List<Rect?> _stLogoBoxes = const [];
  Offset? _stCycleAt;
  int _stCycleHintLeft = 2;

  void _stTapAt(Offset p) {
    // 由上往下：文字畫在圖片之後＝文字在上；圖片則是後加的在上
    final hits = <({WmPart part, int logo})>[
      if (_stTextBox?.contains(p) ?? false) (part: WmPart.text, logo: -1),
      for (var i = _stLogoBoxes.length - 1; i >= 0; i--)
        if (_stLogoBoxes[i]?.contains(p) ?? false) (part: WmPart.logo, logo: i),
    ];
    if (hits.isEmpty) {
      _stCycleAt = null;
      if (_wmPart != WmPart.none) setState(() => _wmPart = WmPart.none);
      return;
    }
    // 手指不可能點在同一個像素上，給 24px 的容忍
    final same = _stCycleAt != null && (_stCycleAt! - p).distance <= 24;
    var next = hits.first;
    if (same) {
      final cur = (
        part: _wmPart,
        logo: _wmPart == WmPart.logo ? _settings.activeLogo : -1,
      );
      final at = hits.indexOf(cur);
      if (at >= 0) next = hits[(at + 1) % hits.length];
    }
    _stCycleAt = p;
    setState(() {
      _wmPart = next.part;
      if (next.logo >= 0) _settings.activeLogo = next.logo;
    });
    _wmPanelCtrl.scrollTo(next.part);
    if (!same && hits.length > 1 && _stCycleHintLeft > 0) {
      _stCycleHintLeft--;
      showHint(context, overlapHint(hits.length));
    }
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
    // 快照延到真的縮到東西才拍：光按一下就拍會把重做堆疊清空，
    // 剛撤銷的東西再也回不來
    _stUndoPending = true;
  }

  /// 這次手勢還沒拍過快照
  bool _stUndoPending = false;

  void _stPushUndoIfNeeded() {
    if (!_stUndoPending) return;
    _stUndoPending = false;
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
    if (doText || doLogo) _stPushUndoIfNeeded();
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

  /// 點示意畫面上的浮水印時，叫下面的面板捲到對應的設定區塊
  final _wmPanelCtrl = WatermarkPanelController();
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

  /// 底色切換：迷你分段控制（透／黑／白）
  Widget _bgSegment() {
    Widget seg(String label, int mode) {
      final active = _bgMode == mode;
      return InkWell(
        onTap: () => setState(() => _bgMode = mode),
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
          children: [seg('透', 0), seg('黑', 1), seg('白', 2)],
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
          // 從範本夾點進來編輯時不顯示這顆：上一頁就是範本夾，
          // 再開一次會變成「工作室→範本夾→工作室…」一直往上疊，
          // 返回要按同樣多次才回得到首頁
          if (widget.edit == null)
            IconButton(
              tooltip: '我的範本',
              icon: const Icon(Icons.bookmarks_outlined),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) =>
                          const LightPage(child: PresetsScreen()))),
            ),
        ],
      ),
      body: Column(
        children: [
          // 示意畫面（拖曳浮水印調位置）；固定高度，比例改變時畫布置中縮放
          Container(
            height: 250,
            width: double.infinity,
            color: kPreviewBg,
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
                            color: _bgMode == 2
                                ? Colors.white
                                : (_bgMode == 1 ? Colors.black : null),
                            child: Stack(
                              clipBehavior: Clip.none,
                              fit: StackFit.expand,
                              children: [
                                // 透明模式的棋盤格：純色底會把同色的邊緣
                                // 整個吃掉，做浮水印最需要看清楚的就是
                                //「這張圖自己的邊到哪裡」
                                if (_bgMode == 0)
                                  const Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: CheckerPainter(),
                                      ),
                                    ),
                                  ),
                                // 底就是純色，不放示意圖示——那個山形圖案
                                // 會被誤認成浮水印的一部分
                                WatermarkLayer(
                                  settings: _settings,
                                  onChanged: () => _wmTick.value++,
                                  onDragStart: _pushUndo,
                                  onHitBox: (t, l) {
                                    _stTextBox = t;
                                    _stLogoBoxes = l;
                                  },
                                  // 選取鎖定：選了圖片就只動圖片
                                  selectedPart: _wmPartAlive,
                                  onSelectPart: (p) {
                                    setState(() => _wmPart = p);
                                    // 點文字就把面板捲到文字設定
                                    _wmPanelCtrl.scrollTo(p);
                                  },
                                  panLocked: () => _pvPts.length >= 2,
                                ),
                                // 點擊判定層：疊在浮水印之上，統一決定
                                // 點到誰。translucent＝只搶點擊，
                                // 拖曳照樣傳給下面的圖層與選取路由
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTapUp: (d) => _stTapAt(d.localPosition),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                                // 置中輔助線（路由拖曳吸中線時）。
                                // 永遠佔一個位置，不能用 if 增減——線一出現
                                // 會把下面手勢層的索引推掉，拖曳被中斷後
                                // 又從已吸附的中線重新開始，就再也拖不出來
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
                                    key: const ValueKey('wm-route'),
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
          // 上一步／重做跟影片、照片同一個位置（預覽下方）。
          // 原本在標題列右上角，大螢幕手機拇指按不到
          undoRedoBar(
            onUndo: _undo.isEmpty ? null : _undoLast,
            onRedo: _redo.isEmpty ? null : _redoLast,
          ),
          Expanded(
            child: WatermarkPanel(
              key: _panelKey,
              controller: _wmPanelCtrl,
              settings: _settings,
              // 這裡是「做範本」的地方，動畫當然要能設定。
              // 示意畫面沒有時間軸（time 為 null）所以不會動，
              // 但值會存進範本，套到影片上就看得到
              showAnimation: true,
              // 剛加的圖片直接選起來：接下來一定是要拖它／縮放它，
              // 不用再回畫面上找它點一下（其他三個編輯畫面本來就這樣，
              // 只有這裡跟批次漏掛）
              onLogoAdded: () => setState(() => _wmPart = WmPart.logo),
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
