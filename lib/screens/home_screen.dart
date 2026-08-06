import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/preset_store.dart';
import '../theme.dart';
import 'batch_watermark_screen.dart';
import 'photo_editor_screen.dart';
import 'profile_screen.dart';
import 'video_editor_screen.dart';
import 'watermark_studio_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _draft; // 上次沒完成的專案

  @override
  void initState() {
    super.initState();
    PresetStore.ensureSeeded()
        .then((_) => PresetStore.ensureSeededV2())
        .then((_) => PresetStore.ensureSeededV3())
        .then((_) => PresetStore.ensureSeededV4());
    _checkDraft();
  }

  Future<void> _checkDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(kDraftKey);
    if (!mounted) return;
    Map<String, dynamic>? found;
    if (s != null) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if ((j['clips'] as List?)?.isNotEmpty ?? false) found = j;
      } catch (_) {}
    }
    setState(() => _draft = found);
  }

  Future<void> _resumeDraft() async {
    final d = _draft;
    if (d == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VideoEditorScreen(draft: d)),
    );
    _checkDraft();
  }

  bool _isVideoFile(XFile f) {
    final mime = f.mimeType;
    if (mime != null && mime.isNotEmpty) return mime.startsWith('video/');
    final ext = f.name.toLowerCase().split('.').last;
    return const {
      'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts', 'mts'
    }.contains(ext);
  }

  /// 加入浮水印：選一個進對應編輯器；一次選多個進批次浮水印
  Future<void> _addWatermark() async {
    final list = await ImagePicker().pickMultipleMedia();
    if (list.isEmpty || !mounted) return;
    if (list.length > 1) {
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => BatchWatermarkScreen(files: list)),
      );
      return;
    }
    final picked = list.first;
    if (_isVideoFile(picked)) {
      // 新影片專案會覆蓋現有草稿，先問過
      if (_draft != null) {
        final ok = await showConfirm(
          context,
          title: '覆蓋上次的草稿？',
          message: '開新專案後，未完成的草稿會被取代',
          action: '開新專案',
        );
        if (!ok || !mounted) return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => VideoEditorScreen(videoPath: picked.path)),
      );
      _checkDraft();
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PhotoEditorScreen(photo: picked)),
      );
    }
  }

  void _makeWatermark() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const WatermarkStudioScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 純黑底：跟吉祥物原圖的黑底融為一體
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: '個人中心',
            iconSize: 28,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            icon: const Icon(Icons.person_outline),
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ProfileScreen()));
              _checkDraft(); // 草稿可能在裡面被刪掉或接續了
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 吉祥物置中（使用者的原圖，跟 App 圖示同一張），
              // 佔滿上方剩餘空間垂直置中
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 300,
                    height: 120,
                    child: Image.asset(
                      'assets/icon/icon_foreground.png',
                      fit: BoxFit.cover, // 裁掉原圖四周的留白
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
              // 三個動作全部靠底
              _HomeButton(
                primary: true,
                label: '加入浮水印',
                onTap: _addWatermark,
              ),
              const SizedBox(height: 12),
              _HomeButton(
                primary: false,
                label: '製作浮水印',
                onTap: _makeWatermark,
              ),
              if (_draft != null) ...[
                const SizedBox(height: 18),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _resumeDraft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 14, horizontal: 18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kBorder),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_draft?['thumb'] is String)
                          Container(
                            width: (26 *
                                    ((_draft?['thumbAspect'] as num?) ??
                                            16 / 9)
                                        .toDouble())
                                .clamp(16.0, 46.0),
                            height: 26,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4)),
                            child: Image.memory(
                              base64Decode(_draft!['thumb'] as String),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          )
                        else
                          const Icon(Icons.history,
                              size: 18, color: kTextDim),
                        const SizedBox(width: 10),
                        const Text('繼續上次的專案',
                            style: TextStyle(
                                fontSize: 14, color: kTextDim)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 首頁按鈕（B 版型）：主鍵反白填滿、次鍵描邊，主次分明
class _HomeButton extends StatelessWidget {
  final bool primary;
  final String label;
  final VoidCallback onTap;

  const _HomeButton({
    required this.primary,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? kAmber : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border:
              primary ? null : Border.all(color: kClipBorder, width: 1.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: primary ? kBg : kText,
          ),
        ),
      ),
    );
  }
}
