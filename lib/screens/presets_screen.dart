import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';
import '../services/preset_store.dart';
import '../services/storage_usage.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/swipe_back.dart';
import '../widgets/library_selection.dart';
import '../widgets/library_tile_menu.dart';
import 'watermark_studio_screen.dart';

/// 範本大卡的形狀：超橢圓（形狀與半徑的來由見 theme.dart 的 tileShape）
final _kCardShape = tileShape(
  radius: kPresetRadius,
  side: const BorderSide(color: kLBorder),
);

/// 常用浮水印範本（範本的「查看全部」）：黑底預覽卡（浮水印按真實
/// 位置渲染），點卡直接進編輯模式；長按旁邊跳小選單（改名／刪除）；
/// 批次刪除＝每一張標出多大，選好按底下的紅鈕
class PresetsScreen extends StatefulWidget {
  /// 一進來就是批次刪除（從「容量與清理」點範本進來的）
  final bool batch;

  const PresetsScreen({super.key, this.batch = false});

  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  List<WatermarkPreset> _presets = [];
  bool _loading = true;
  late bool _selecting = widget.batch;
  bool _deleting = false;
  final Set<String> _picked = {};

  /// 每個範本存起來多大（名字 → 位元組；Logo 圖也存在裡面，大的就是
  /// 那幾張）。批次刪除時標在卡上、加總寫在紅鈕上
  Map<String, int> _sizes = const {};

  void _cancelSelection() {
    if (_deleting) return;
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  void _togglePick(String name) {
    if (_deleting) return;
    setState(() {
      if (!_picked.remove(name)) _picked.add(name);
    });
  }

  bool get _allPicked =>
      _presets.isNotEmpty && _picked.length == _presets.length;

  void _toggleAll() {
    if (_deleting) return;
    setState(() {
      if (_allPicked) {
        _picked.clear();
      } else {
        _picked.addAll(_presets.map((p) => p.name));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _picked.isEmpty) return;
    final names = Set<String>.of(_picked);
    setState(() => _deleting = true);
    try {
      final ok = await showConfirm(
        context,
        title: '刪除 ${names.length} 個範本？',
        message: '只刪除選取的範本，刪除後無法復原',
        action: '刪除',
      );
      if (!ok || !mounted) return;
      if (!await PresetStore.removeMany(names)) {
        throw StateError('delete failed');
      }
      await _reload();
      if (!mounted) return;
      setState(() {
        _picked.clear();
        _selecting = false;
      });
    } catch (_) {
      if (mounted) showHint(context, '範本刪除失敗，請再試一次', error: true);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final p = await PresetStore.load();
    if (!mounted) return; // 載入中滑回上一頁就別再 setState
    setState(() {
      _presets = p;
      _sizes = {for (final e in p) e.name: utf8.encode(e.encode()).length};
      _picked.retainAll(p.map((e) => e.name));
      _loading = false;
    });
  }

  Future<void> _edit(WatermarkPreset p) async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => WatermarkStudioScreen(edit: p)),
    );
    _reload();
  }

  Future<void> _rename(WatermarkPreset p) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: p.name),
    );
    if (newName == null || newName.isEmpty || newName == p.name) return;
    final ok = await PresetStore.rename(p.name, newName);
    if (!mounted) return;
    if (ok) {
      showHint(context, '已改名為「$newName」');
      _reload();
    } else {
      showHint(context, '已有同名範本，換個名字', error: true);
    }
  }

  /// 長按一張：背景壓暗、那一張浮起來，旁邊跳小選單（改名／刪除）。
  /// 選單本身就是「要不要刪」，選了刪除就直接刪（使用者指定，不再跳
  /// 整頁的確認視窗）
  Future<void> _menu(BuildContext tile, WatermarkPreset p) async {
    final act = await showLibraryTileMenu<String>(
      tile,
      preview: ColoredBox(color: Colors.black, child: _marks(p)),
      title: '範本「${p.name}」',
      radius: kPresetRadius,
      actions: const [
        LibraryMenuAction(
          'rename',
          '改名',
          icon: Icons.drive_file_rename_outline,
        ),
        LibraryMenuAction(
          'delete',
          '刪除',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (!mounted) return;
    switch (act) {
      case 'rename':
        await _rename(p);
      case 'delete':
        await PresetStore.remove(p.name);
        if (mounted) _reload();
    }
  }

  Future<void> _addNew() async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => const WatermarkStudioScreen()),
    );
    _reload();
  }

  /// 「＋ 新增範本」卡：開浮水印工坊，做完回來清單自動刷新
  Widget _addCard() {
    return Material(
      color: Colors.transparent,
      shape: _kCardShape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _addNew,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 24, color: kLTextDim),
            SizedBox(height: 5),
            Text('新增範本', style: TextStyle(fontSize: 11.5, color: kLTextDim)),
          ],
        ),
      ),
    );
  }

  /// 卡面上照實位置渲染的浮水印（卡片本身與長按浮起來的那一張共用）
  Widget _marks(WatermarkPreset p) => IgnorePointer(
    child: WatermarkLayer(settings: p.settings, onChanged: () {}),
  );

  Widget _presetCard(WatermarkPreset p) {
    // 內容（黑底＋照實渲染的浮水印，可能是一張鋪滿的圖）一律切成跟
    // 卡片同一個形狀，四角才不會被方形的內容頂出去。
    // 底色交給 Material 自己畫（同一條路徑上色，不會有兩層邊界對不齊）
    return Builder(
      builder: (tile) => Material(
        color: Colors.black,
        shape: _kCardShape,
        clipBehavior: Clip.antiAlias,
        // 不放名稱膠囊（使用者指定）：卡片本身就是內容，
        // 名字在長按選單（改名/刪除）還看得到
        child: InkWell(
          key: ValueKey('preset-${p.name}'),
          onTap: () => _selecting ? _togglePick(p.name) : _edit(p),
          onLongPress: () => _selecting ? _togglePick(p.name) : _menu(tile, p),
          child: Semantics(
            selected: _selecting ? _picked.contains(p.name) : null,
            label: p.name,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _marks(p),
                if (_selecting)
                  LibrarySelectionMark(
                    selected: _picked.contains(p.name),
                    size: formatBytes(_sizes[p.name] ?? 0),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked.length;
    final freed = [
      for (final name in _picked) _sizes[name] ?? 0,
    ].fold(0, (a, b) => a + b);
    return PopScope(
      // 批次刪除中按返回／右滑＝先退出批次刪除，不是離開這一頁
      canPop: !_selecting && !_deleting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelSelection();
      },
      child: SwipeBack(
        child: Scaffold(
          // 上面只有返回鍵跟「批次刪除」；批次刪除時左邊換成「取消」、
          // 右邊換成「全選」（跟草稿的查看全部同一套）
          appBar: AppBar(
            automaticallyImplyLeading: !_selecting,
            leadingWidth: _selecting ? 76 : null,
            leading: _selecting
                ? TextButton(
                    onPressed: _deleting ? null : _cancelSelection,
                    child: const Text('取消'),
                  )
                : null,
            actions: [
              if (_selecting)
                TextButton(
                  onPressed: _deleting || _presets.isEmpty ? null : _toggleAll,
                  child: Text(_allPicked ? '取消全選' : '全選'),
                )
              else if (!_loading && _presets.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _selecting = true),
                  child: const Text('批次刪除'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          // 撐滿整個 body：Scaffold 給 body 的是鬆的約束，不撐滿的話 Stack
          // 只有內容那麼高，紅鈕就浮在畫面中間（範本少的時候）
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else
                // 兩欄瀑布流：卡片照各自的設計比例（16:9 扁、9:16 高、
                // 1:1 方），比塞進同一種格子誠實——預覽就是設計時的樣子
                Builder(
                  builder: (context) {
                    final left = <Widget>[];
                    final right = <Widget>[];
                    var hl = 0.0, hr = 0.0;
                    void put(Widget w, double h) {
                      if (hl <= hr) {
                        left.add(w);
                        hl += h;
                      } else {
                        right.add(w);
                        hr += h;
                      }
                    }

                    for (final p in _presets) {
                      final a = p.settings.designAspect;
                      put(
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AspectRatio(
                            aspectRatio: a,
                            child: _presetCard(p),
                          ),
                        ),
                        1 / a,
                      );
                    }
                    if (_presets.isEmpty) {
                      // 空的時候至少給一張入口卡，不然整頁空白
                      // 只剩右下角一顆 +
                      put(
                        AspectRatio(aspectRatio: 16 / 10, child: _addCard()),
                        10 / 16,
                      );
                    }
                    return SingleChildScrollView(
                      // 底部多留一段：最後一張卡不被浮動 +／紅鈕蓋住
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: Column(children: left)),
                          const SizedBox(width: 10),
                          Expanded(child: Column(children: right)),
                        ],
                      ),
                    );
                  },
                ),
              // 選了至少一個，刪除鈕才從底下浮上來（直接浮在內容上，
              // 後面不墊白底）
              LibraryDeleteDock(
                visible: _selecting && picked > 0,
                busy: _deleting,
                label: libraryDeleteLabel(picked, '個', freed),
                onPressed: _deleteSelected,
              ),
            ],
          ),
          // 新增改成右下角浮動黑圓 +（使用者指定）：清單裡不再
          // 混一張「新增卡」。批次刪除時收起來，底下換成紅鈕
          floatingActionButton: _selecting
              ? null
              : FloatingActionButton(
                  onPressed: _addNew,
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.add, size: 28),
                ),
        ),
      ),
    );
  }
}

/// 改名對話框。pop 出修剪過的新名字；取消是 null。
///
/// 輸入框的 controller 由這個 widget 自己持有、自己 dispose：以前是
/// `await showDialog` 一回來就 dispose，可是 pop 的 future 在收起動畫
/// 一開始就完成了，接下來的幾格 TextField 還活著、失焦時會寫回
/// controller.value，就炸「used after being disposed」（debug／profile
/// 每改一次名噴一次紅字）。State 跟著對話框的樹一起走，動畫跑完才 dispose
class _RenameDialog extends StatefulWidget {
  final String initial;

  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(
      '範本改名',
      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
    ),
    content: TextField(
      controller: _ctrl,
      autofocus: true,
      maxLength: 20,
      decoration: const InputDecoration(counterText: ''),
      onSubmitted: (v) => Navigator.pop(context, v.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
        child: const Text('確定'),
      ),
    ],
  );
}
