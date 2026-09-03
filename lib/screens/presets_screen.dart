import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';
import '../services/preset_store.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/swipe_back.dart';
import 'watermark_studio_screen.dart';

/// 常用浮水印範本管理：黑底預覽卡（浮水印按真實位置渲染），
/// 點卡直接進編輯模式，長按開「改名／刪除」選單
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
      MaterialPageRoute(builder: (_) => WatermarkStudioScreen(edit: p)),
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
    final ctrl = TextEditingController(text: p.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          '範本改名',
          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
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
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
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
      builder: (context) => SafeArea(
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
              leading: const Icon(
                Icons.delete_outline,
                size: 20,
                color: Color(0xFFFF6B6B),
              ),
              title: const Text(
                '刪除',
                style: TextStyle(fontSize: 13.5, color: Color(0xFFFF6B6B)),
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
  }

  Future<void> _addNew() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WatermarkStudioScreen()),
    );
    _reload();
  }

  /// 「＋ 新增範本」卡：開浮水印工坊，做完回來清單自動刷新
  Widget _addCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(kPresetRadius),
      onTap: _addNew,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kPresetRadius),
          border: Border.all(color: kLBorder),
        ),
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
    return InkWell(
      borderRadius: BorderRadius.circular(kPresetRadius),
      onTap: () => _edit(p),
      onLongPress: () => _showActions(p),
      child: Container(
        // 內容（黑底＋照實渲染的浮水印，可能是一張鋪滿的圖）一律
        // 切成跟卡片同一個圓角，四角才不會被方形的內容頂出去
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kPresetRadius),
          border: Border.all(color: kLBorder),
        ),
        // 不放名稱膠囊（使用者指定）：卡片本身就是內容，
        // 名字在長按選單（改名/刪除）還看得到
        child: Container(
          color: Colors.black,
          child: IgnorePointer(
            child: WatermarkLayer(settings: p.settings, onChanged: () {}),
          ),
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
