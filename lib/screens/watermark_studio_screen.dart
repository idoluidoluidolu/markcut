import 'dart:convert';

import 'package:flutter/material.dart';

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
      _sync++;
    });
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
                Center(
                  child: AspectRatio(
                    aspectRatio: _ratios[_ratioIdx].$2,
                    child: Container(
                      color: _lightBg ? Colors.white : Colors.black,
                      child: Stack(
                        clipBehavior: Clip.none,
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: Icon(Icons.landscape_outlined,
                                size: 56,
                                color: _lightBg
                                    ? Colors.black12
                                    : Colors.white12),
                          ),
                          WatermarkLayer(
                            settings: _settings,
                            onChanged: () => setState(() {}),
                            onDragStart: _pushUndo,
                          ),
                        ],
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
            ),
          ),
        ],
      ),
      ),
    );
  }
}
