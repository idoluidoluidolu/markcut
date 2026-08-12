import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/watermark_settings.dart';
import '../services/preset_store.dart';
import '../theme.dart';
import '../widgets/swipe_back.dart';
import 'about_screen.dart';
import 'donate_screen.dart';
import 'feedback_screen.dart';
import 'presets_screen.dart';
import 'video_editor_screen.dart';

/// 個人中心：範本夾＋草稿夾＋意見回饋
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<WatermarkPreset> _presets = const [];
  Map<String, dynamic>? _draft;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final presets = await PresetStore.load();
    Map<String, dynamic>? draft;
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(kDraftKey);
    if (s != null) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if ((j['clips'] as List?)?.isNotEmpty ?? false) draft = j;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _presets = presets;
        _draft = draft;
      });
    }
  }

  /// 半寬小卡（icon＋標題橫排；偶爾用的功能不佔大版面）
  Widget _miniCard({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder, width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: kAmber),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  /// 大資料夾卡（純黑＋細邊線，跟關於頁同一套）
  Widget _bigFolder({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget Function()? screen,
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        if (onTap != null) {
          onTap();
          return;
        }
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => screen!()),
        );
        _reload();
      },
      child: Container(
        height: 130,
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kBorder, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: kPanelHi,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, size: 25, color: kAmber),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: kTextDim),
            ),
          ],
        ),
      ),
    );
  }

  /// 太好用啦：進 App 內購的斗內頁（請喝飲料）
  void _openLove() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DonateScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 非編輯頁面全頁都能右滑返回（編輯畫面橫向手勢太多，刻意不放）
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg,
          title: const Text('個人中心'),
        ),
        body: Column(
          children: [
            // 三張大卡：垂直置中，放不下才變成可捲
            Expanded(
              child: LayoutBuilder(
                builder: (context, cons) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: cons.maxHeight),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      // 主次分層：常用的兩張大卡；回饋/鼓勵是偶爾用的，
                      // 縮成半寬並排小卡
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _bigFolder(
                            icon: Icons.bookmarks_outlined,
                            title: '範本夾',
                            subtitle: _presets.isEmpty
                                ? '還沒有範本'
                                : '${_presets.length} 個範本',
                            screen: () => const PresetsScreen(),
                          ),
                          const SizedBox(height: 14),
                          _bigFolder(
                            icon: Icons.folder_outlined,
                            title: '草稿夾',
                            subtitle: _draft == null ? '沒有草稿' : '1 個未完成的專案',
                            screen: () => const DraftsScreen(),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _miniCard(
                                  icon: Icons.chat_bubble_outline,
                                  title: '意見回饋',
                                  onTap: () => showFeedbackDialog(context),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _miniCard(
                                  icon: Icons.favorite_border,
                                  title: '太好用啦',
                                  onTap: _openLove,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
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
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: kIcon,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  icon: const Icon(
                    Icons.info_outline,
                    size: 14,
                    color: kTextDim,
                  ),
                  label: const Text('關於這個 App', style: TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
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

  /// 專案總長（秒）＝所有片段最晚的結尾（變速片段要除速度才準）
  double _draftDuration(Map<String, dynamic> j) {
    var end = 0.0;
    // 壞掉的草稿（欄位型別不對）不能讓整個草稿夾紅屏，
    // 不然連「刪掉這筆壞草稿」的按鈕都按不到
    double num0(Object? v) => v is num ? v.toDouble() : 0.0;
    for (final c in (j['clips'] as List? ?? [])) {
      if (c is! Map) continue;
      final m = Map<String, dynamic>.from(c);
      final speed = (m['speed'] is num ? num0(m['speed']) : 1.0).clamp(
        0.1,
        16.0,
      );
      final e =
          num0(m['offset']) +
          (num0(m['trimEnd']) - num0(m['trimStart'])) / speed;
      if (e > end) end = e;
    }
    return end;
  }

  String _fmt(double sec) {
    // 先進位到整秒再拆，不然 59.6 秒會顯示成 0:60
    final t = sec.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  /// 縮圖解碼：壞掉的 base64 不能在 build 裡丟例外（整頁會紅屏）
  Uint8List? _thumbOf(Map<String, dynamic> j) {
    final t = j['thumb'];
    if (t is! String) return null;
    try {
      return base64Decode(t);
    } catch (_) {
      return null;
    }
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
    return SwipeBack(
      child: Scaffold(
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
                          horizontal: 14,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            // 影片縮圖當封面：框跟著影片比例走（直片直框），
                            // 沒有縮圖才用圖示
                            Builder(
                              builder: (context) {
                                final aspect =
                                    ((d['thumbAspect'] as num?) ?? 16 / 9)
                                        .toDouble();
                                return Container(
                                  width: (52 * aspect).clamp(30.0, 92.0),
                                  height: 52,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: kPanelHi,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: _thumbOf(d) != null
                                      ? Image.memory(
                                          _thumbOf(d)!,
                                          fit: BoxFit.cover,
                                          gaplessPlayback: true,
                                        )
                                      : const Icon(
                                          Icons.movie_outlined,
                                          size: 20,
                                          color: kAmber,
                                        ),
                                );
                              },
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '未完成的專案',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${(d['clips'] as List? ?? const []).length} 個片段'
                                    '・${_fmt(_draftDuration(d))}'
                                    '${_savedAtLabel(d)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: kTextDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '刪除草稿',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 19,
                                color: kTextDim,
                              ),
                              onPressed: _delete,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
