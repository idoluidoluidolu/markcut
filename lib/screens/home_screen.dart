import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/preset_store.dart';
import '../theme.dart';
import 'batch_watermark_screen.dart';
import 'collage_screen.dart';
import 'photo_editor_screen.dart';
import 'profile_screen.dart';
import 'video_editor_screen.dart';
import 'watermark_studio_screen.dart';

/// 「加入浮水印」的五種入口
enum _PickKind { oneVideo, onePhoto, manyVideos, manyPhotos, collage }

/// 選取視窗裡的方塊：大圖示＋標題，多支的再加一個「批次」註記
class _PickTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final _PickKind kind;

  const _PickTile({
    required this.icon,
    required this.label,
    required this.kind,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kPanel,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pop(context, kind),
        child: Container(
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26, color: kAmber),
              const SizedBox(height: 8),
              Text(label,
                  style: const TextStyle(fontSize: 13.5, color: kText)),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(hint!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: kTextDim)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _draft; // 上次沒完成的專案
  Uint8List? _draftThumb; // 已驗證可解碼的縮圖（壞掉就是 null）

  @override
  void initState() {
    super.initState();
    // 預設範本補種：任何一步失敗都不該讓首頁跳錯誤橫幅，
    // 也不該讓後面幾批預設從此不再補
    PresetStore.ensureSeeded()
        .then((_) => PresetStore.ensureSeededV2())
        .then((_) => PresetStore.ensureSeededV3())
        .then((_) => PresetStore.ensureSeededV4())
        .catchError((_) {});
    _checkDraft();
  }

  Future<void> _checkDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(kDraftKey);
    if (!mounted) return;
    Map<String, dynamic>? found;
    Uint8List? thumb;
    if (s != null) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if ((j['clips'] as List?)?.isNotEmpty ?? false) found = j;
      } catch (_) {}
    }
    // 縮圖先在這裡解好：base64 壞掉時 build 裡解會每一幀都丟例外，
    // 首頁變成永遠的紅畫面，連重開 App 都救不回來
    if (found != null && found['thumb'] is String) {
      try {
        thumb = base64Decode(found['thumb'] as String);
      } catch (_) {
        thumb = null;
      }
    }
    setState(() {
      _draft = found;
      _draftThumb = thumb;
    });
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

  /// 加入浮水印：先問要單支還是多支、影片還是照片
  /// 選單開著就別再開第二個（連點兩下會疊兩層）
  bool _picking = false;

  Future<void> _addWatermark() async {
    if (_picking) return;
    _picking = true;
    try {
      await _addWatermarkInner();
    } finally {
      _picking = false;
    }
  }

  Future<void> _addWatermarkInner() async {
    final kind = await showDialog<_PickKind>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: kBg,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: kBorder),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('加入浮水印',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                // 2×2：上排單支、下排多支
                Row(children: [
                  Expanded(
                      child: _PickTile(
                          icon: Icons.videocam_outlined,
                          label: '單支影片',
                          kind: _PickKind.oneVideo)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _PickTile(
                          icon: Icons.image_outlined,
                          label: '單張照片',
                          kind: _PickKind.onePhoto)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: _PickTile(
                          icon: Icons.video_library_outlined,
                          label: '多支影片',
                          hint: '建議 30 部以內',
                          kind: _PickKind.manyVideos)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _PickTile(
                          icon: Icons.photo_library_outlined,
                          label: '多張照片',
                          hint: '建議 200 張以內',
                          kind: _PickKind.manyPhotos)),
                ]),
                const SizedBox(height: 10),
                const Row(children: [
                  Expanded(
                      child: _PickTile(
                          icon: Icons.grid_view,
                          label: '照片拼圖',
                          hint: '2/4/6/9 宮格',
                          kind: _PickKind.collage)),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    if (kind == null || !mounted) return;

    switch (kind) {
      case _PickKind.oneVideo:
        final f = await ImagePicker().pickVideo(source: ImageSource.gallery);
        if (f != null && mounted) await _openVideo(f);
      case _PickKind.onePhoto:
        final f = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (f != null && mounted) await _openPhoto(f);
      case _PickKind.manyPhotos:
        final list = await ImagePicker().pickMultiImage();
        await _openBatch(list);
      case _PickKind.collage:
        final list = await ImagePicker().pickMultiImage();
        if (list.length < 2) {
          if (list.isNotEmpty && mounted) {
            showHint(context, '拼圖至少要選兩張照片');
          }
          return;
        }
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => CollageScreen(photos: list)),
        );
      case _PickKind.manyVideos:
        // image_picker 沒有「只選多支影片」的 API，用混合選取再濾掉照片，
        // 這樣才留得住系統原生的相簿選取器
        final list = await ImagePicker().pickMultipleMedia();
        final videos = list.where(_isVideoFile).toList();
        // 提示交給批次頁進場後顯示——在這裡 show 會馬上被
        // 推上來的新頁面蓋住，使用者根本看不到
        final skipped = list.length - videos.length;
        await _openBatch(
          videos,
          hint: skipped > 0 ? '已略過 $skipped 個非影片檔案' : null,
        );
    }
  }

  /// 一支就進單檔編輯器，多支才進批次
  Future<void> _openBatch(List<XFile> list, {String? hint}) async {
    if (list.isEmpty || !mounted) return;
    if (list.length == 1) {
      final f = list.first;
      await (_isVideoFile(f) ? _openVideo(f) : _openPhoto(f));
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BatchWatermarkScreen(files: list, initialHint: hint),
      ),
    );
  }

  Future<void> _openPhoto(XFile picked) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PhotoEditorScreen(photo: picked)),
    );
  }

  Future<void> _openVideo(XFile picked) async {
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
  }

  void _makeWatermark() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const WatermarkStudioScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 近黑底（標準 dark mode）：吉祥物黑底圖用「變亮混合」融進背景
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        // logo 當品牌標識放在頂部這一列（跟個人中心同高），
        // 不再孤零零地浮在畫面正中央。titleSpacing 對齊 body 的左邊距
        titleSpacing: 24,
        title: SizedBox(
          width: 96,
          height: 38,
          child: ColorFiltered(
            colorFilter: const ColorFilter.matrix(<double>[
              0.85, 0, 0, 0, 0, //
              0, 0.85, 0, 0, 0, //
              0, 0, 0.85, 0, 0, //
              0, 0, 0, 1, 0, //
            ]),
            child: Image.asset(
              'assets/icon/home_logo.png',
              fit: BoxFit.cover, // 裁掉原圖四周的留白
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
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
              // logo 移到頂部那一列了，中間刻意留白
              const Spacer(),
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
                        if (_draftThumb != null)
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
                              _draftThumb!,
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
