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
      borderRadius: BorderRadius.circular(8),
      onTap: _addNew,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
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
      borderRadius: BorderRadius.circular(8),
      onTap: () => _edit(p),
      onLongPress: () => _showActions(p),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kLBorder),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 黑底滿版預覽：浮水印照真實位置／顏色／效果渲染
            Container(
              color: Colors.black,
              child: IgnorePointer(
                child: WatermarkLayer(settings: p.settings, onChanged: () {}),
              ),
            ),
            // 名字＝左上角小膠囊（UI 感明確，不會被誤認成浮水印）
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: kLTile.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: kLBorder),
                ),
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: kLIcon,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
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
            : GridView.builder(
                padding: const EdgeInsets.all(14),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 16 / 10,
                ),
                // 最後永遠多一格「＋ 新增範本」
                itemCount: _presets.length + 1,
                itemBuilder: (context, i) =>
                    i < _presets.length ? _presetCard(_presets[i]) : _addCard(),
              ),
      ),
    );
  }
}
