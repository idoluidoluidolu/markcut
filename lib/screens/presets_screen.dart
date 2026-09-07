import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';
import '../services/preset_store.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/swipe_back.dart';
import 'watermark_studio_screen.dart';

/// 常用浮水印範本管理：黑底預覽卡（浮水印按真實位置渲染），
/// 點卡直接進編輯模式，長按開「改名／刪除」選單
/// 範本大卡的形狀：超橢圓（形狀與半徑的來由見 theme.dart 的 tileShape）
final _kCardShape = tileShape(
  radius: kPresetRadius,
  side: const BorderSide(color: kLBorder),
);

class PresetsScreen extends StatefulWidget {
  const PresetsScreen({super.key});

  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  List<WatermarkPreset> _presets = [];
  bool _loading = true;

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

  Future<void> _confirmDelete(WatermarkPreset p) async {
    final ok = await showConfirm(
      context,
      title: '刪除範本「${p.name}」？',
      message: '刪除後無法復原',
      action: '刪除',
    );
    if (ok) {
      await PresetStore.remove(p.name);
      _reload();
    }
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

  /// 長按：改名／刪除選單
  void _showActions(WatermarkPreset p) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      // 面板自己管高度、裝不下就捲（跟首頁、GIF 夾的面板同一套）：
      // 預設的 9/16 上限在橫向只剩 211，這三列剛好貼著上限
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        // 刪除用淺色佈景的 error（#D1373A）：以前寫死深色頁的 #FF6B6B，
        // 白底上對比只有 2.8:1
        final error = Theme.of(context).colorScheme.error;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: kLText,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.drive_file_rename_outline,
                    size: 20,
                    color: kLIcon,
                  ),
                  title: const Text('改名', style: TextStyle(fontSize: 13.5)),
                  onTap: () {
                    Navigator.pop(context);
                    _rename(p);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, size: 20, color: error),
                  title: Text(
                    '刪除',
                    style: TextStyle(fontSize: 13.5, color: error),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _confirmDelete(p);
                  },
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
    );
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

  Widget _presetCard(WatermarkPreset p) {
    // 內容（黑底＋照實渲染的浮水印，可能是一張鋪滿的圖）一律切成跟
    // 卡片同一個形狀，四角才不會被方形的內容頂出去。
    // 底色交給 Material 自己畫（同一條路徑上色，不會有兩層邊界對不齊）
    return Material(
      color: Colors.black,
      shape: _kCardShape,
      clipBehavior: Clip.antiAlias,
      // 不放名稱膠囊（使用者指定）：卡片本身就是內容，
      // 名字在長按選單（改名/刪除）還看得到
      child: InkWell(
        onTap: () => _edit(p),
        onLongPress: () => _showActions(p),
        child: IgnorePointer(
          child: WatermarkLayer(settings: p.settings, onChanged: () {}),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
        appBar: AppBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            // 兩欄瀑布流：卡片照各自的設計比例（16:9 扁、9:16 高、
            // 1:1 方），比塞進同一種格子誠實——預覽就是設計時的樣子
            : Builder(
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
                    // 底部多留一段：最後一張卡不被浮動 + 蓋住
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
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
        // 新增改成右下角浮動黑圓 +（使用者指定）：清單裡不再
        // 混一張「新增卡」
        floatingActionButton: FloatingActionButton(
          onPressed: _addNew,
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          child: const Icon(Icons.add, size: 28),
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
