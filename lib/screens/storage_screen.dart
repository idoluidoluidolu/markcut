import 'package:flutter/material.dart';

import '../services/storage_usage.dart';
import '../theme.dart';

class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.openDrafts,
    required this.openGifs,
    required this.openPresets,
  });

  final Future<void> Function() openDrafts;
  final Future<void> Function() openGifs;
  final Future<void> Function() openPresets;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  StorageReport? _report;
  String? _error;
  bool _busy = false;
  int _scanGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final generation = ++_scanGeneration;
    try {
      final report = await StorageUsage.scan();
      if (mounted && generation == _scanGeneration) {
        setState(() {
          _report = report;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && generation == _scanGeneration) {
        setState(() => _error = '容量讀取失敗，請重試');
      }
    }
  }

  Future<void> _manage(Future<void> Function() open) async {
    await open();
    if (mounted) await _scan();
  }

  Future<void> _clear() async {
    if (_busy) return;
    _scanGeneration++;
    setState(() => _busy = true);
    try {
      final freed = await StorageUsage.clearCaches();
      if (mounted) {
        showHint(
          context,
          freed > 0 ? '已清出 ${formatBytes(freed)}' : '目前沒有可清理的暫存',
        );
      }
      await _scan();
    } catch (_) {
      if (mounted) showHint(context, '部分暫存無法清理，請稍後重試', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('容量與清理'),
        actions: [
          IconButton(
            tooltip: '重新計算',
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: TextButton(onPressed: _scan, child: Text(_error!)),
            )
          : r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  formatBytes(r.total),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text('作品與管理中的暫存'),
                const SizedBox(height: 24),
                _row(
                  '草稿',
                  r.projectBytes,
                  '含影片、照片、拼圖與草稿使用的素材',
                  () => _manage(widget.openDrafts),
                ),
                _row(
                  'GIF',
                  r.gifBytes,
                  '已儲存的 GIF',
                  () => _manage(widget.openGifs),
                ),
                _row(
                  '範本',
                  r.presetBytes,
                  '已儲存的浮水印範本',
                  () => _manage(widget.openPresets),
                ),
                _row('貼圖', r.stickerBytes, '已儲存的自訂貼圖', null),
                const Divider(height: 32),
                _row('預覽縮圖暫存', r.thumbnailBytes, '清理後會在需要時重新產生', null),
                _row(
                  '未使用的轉檔暫存',
                  r.filesUnused,
                  r.pending > 0 ? '部分草稿無法確認，暫不清理轉檔檔案' : '目前沒有草稿使用的轉檔檔案',
                  null,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const ValueKey('clear-storage-cache'),
                  onPressed: _busy || r.clearableBytes == 0 ? null : _clear,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: Text(
                    _busy ? '清理中…' : '清理暫存 ${formatBytes(r.clearableBytes)}',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('清理暫存會保留草稿、GIF、範本和貼圖。要刪除作品，請點選上方分類進入清單。'),
              ],
            ),
    );
  }

  Widget _row(String name, int bytes, String description, VoidCallback? open) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(name),
        subtitle: Text(description),
        onTap: _busy ? null : open,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(formatBytes(bytes)),
            if (open != null) const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      );
}
