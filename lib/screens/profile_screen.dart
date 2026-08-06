import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/preset_store.dart';
import '../theme.dart';
import 'about_screen.dart';
import 'presets_screen.dart';
import 'video_editor_screen.dart';

/// 個人中心：範本夾＋草稿夾
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int _presetCount = 0;
  bool _hasDraft = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final presets = await PresetStore.load();
    var hasDraft = false;
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(kDraftKey);
    if (s != null) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        hasDraft = (j['clips'] as List?)?.isNotEmpty ?? false;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _presetCount = presets.length;
        _hasDraft = hasDraft;
      });
    }
  }

  /// 大資料夾卡（同首頁大按鈕的語彙）
  Widget _bigFolder({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget Function() screen,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => screen()));
        _reload();
      },
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1D1D21), Color(0xFF17171A)],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kClipBorder, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: kPanelHi,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 27, color: kAmber),
            ),
            const SizedBox(height: 10),
            Text(title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(subtitle,
                style:
                    const TextStyle(fontSize: 12, color: kTextDim)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('個人中心')),
      body: Column(
        children: [
          // 兩張大卡：佔滿剩餘空間並垂直置中
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _bigFolder(
                      icon: Icons.bookmarks_outlined,
                      title: '範本夾',
                      subtitle: _presetCount == 0
                          ? '還沒有範本'
                          : '$_presetCount 個範本',
                      screen: () => const PresetsScreen(),
                    ),
                    const SizedBox(height: 18),
                    _bigFolder(
                      icon: Icons.folder_outlined,
                      title: '草稿夾',
                      subtitle:
                          _hasDraft ? '1 個未完成的專案' : '沒有草稿',
                      screen: () => const DraftsScreen(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 關於：釘在畫面底部置中
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TextButton.icon(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AboutScreen())),
                style: TextButton.styleFrom(
                  foregroundColor: kIcon,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                ),
                icon: const Icon(Icons.info_outline,
                    size: 14, color: kTextDim),
                label: const Text('關於這個 App',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 草稿夾：目前一個草稿位，顯示未完成的專案，可繼續或刪除
class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  Map<String, dynamic>? _draft;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    Map<String, dynamic>? found;
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(kDraftKey);
    if (s != null) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if ((j['clips'] as List?)?.isNotEmpty ?? false) found = j;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _draft = found;
        _loading = false;
      });
    }
  }

  /// 專案總長（原速秒）＝所有片段最晚的結尾
  double _draftDuration(Map<String, dynamic> j) {
    var end = 0.0;
    for (final c in (j['clips'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(c as Map);
      final e = ((m['offset'] ?? 0) as num).toDouble() +
          ((m['trimEnd'] ?? 0) as num).toDouble() -
          ((m['trimStart'] ?? 0) as num).toDouble();
      if (e > end) end = e;
    }
    return end;
  }

  String _fmt(double sec) {
    final m = sec ~/ 60;
    final s = (sec % 60).round();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _savedAtLabel(Map<String, dynamic> j) {
    final raw = j['savedAt'];
    if (raw is! String) return '';
    final t = DateTime.tryParse(raw);
    if (t == null) return '';
    return '・${t.month}/${t.day} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _resume() async {
    final d = _draft;
    if (d == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VideoEditorScreen(draft: d)),
    );
    _reload();
  }

  Future<void> _delete() async {
    final ok = await showConfirm(
      context,
      title: '刪除草稿？',
      message: '未完成的專案會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kDraftKey);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft;
    return Scaffold(
      appBar: AppBar(title: const Text('草稿夾')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      '沒有草稿。\n\n剪輯到一半離開時選「保留草稿」，'
                      '專案就會存在這裡。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kTextDim, height: 1.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPanel,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kBorder),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: _resume,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 14),
                          child: Row(
                            children: [
                              // 影片縮圖當封面：框跟著影片比例走（直片直框），
                              // 沒有縮圖才用圖示
                              Builder(builder: (context) {
                                final aspect =
                                    ((d['thumbAspect'] as num?) ?? 16 / 9)
                                        .toDouble();
                                return Container(
                                  width: (52 * aspect).clamp(30.0, 92.0),
                                  height: 52,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: kPanelHi,
                                    borderRadius:
                                        BorderRadius.circular(7),
                                  ),
                                  child: d['thumb'] is String
                                      ? Image.memory(
                                          base64Decode(
                                              d['thumb'] as String),
                                          fit: BoxFit.cover,
                                          gaplessPlayback: true,
                                        )
                                      : const Icon(
                                          Icons.movie_outlined,
                                          size: 20,
                                          color: kAmber),
                                );
                              }),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    const Text('未完成的專案',
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight:
                                                FontWeight.w700)),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${(d['clips'] as List).length} 個片段'
                                      '・${_fmt(_draftDuration(d))}'
                                      '${_savedAtLabel(d)}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: kTextDim),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: '刪除草稿',
                                icon: const Icon(Icons.delete_outline,
                                    size: 19, color: kTextDim),
                                onPressed: _delete,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
