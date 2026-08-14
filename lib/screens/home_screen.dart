import 'dart:convert';

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

/// 「加入浮水印」的入口。
/// 不分單支/多支——選一個就進單檔編輯器、選多個才進批次，
/// 這件事程式自己判斷得出來，不用先問使用者
enum _PickKind { video, photo, collage, blank }

/// 選取視窗裡的一列：圖示＋標題＋一句說明。
/// 用清單不用方塊——眼睛只要走一條直線，不必在網格裡跳
class _PickRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String hint;
  final _PickKind kind;

  /// 最後一列不畫分隔線
  final bool divider;

  const _PickRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.kind,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.pop(context, kind),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 17),
        decoration: divider
            ? const BoxDecoration(
                border: Border(bottom: BorderSide(color: kBorder)),
              )
            : null,
        child: Row(
          children: [
            Icon(icon, size: 22, color: kAmber),
            const SizedBox(width: 15),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 標題給實體字重（字體已經有 700 的檔案），
                // 兩行的行高也收緊一點，不然標題跟說明看起來像兩件事
                Text(label,
                    style: const TextStyle(
                        fontSize: 14.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: kText)),
                const SizedBox(height: 3),
                Text(hint,
                    style: const TextStyle(
                        fontSize: 12, height: 1.25, color: kTextDim)),
              ],
            ),
          ],
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
  /// 上次沒完成的影片專案。首頁不列出來——草稿一律去
  /// 個人中心的草稿夾拿；這裡只用來判斷「開新影片會不會蓋掉它」
  Map<String, dynamic>? _draft;

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
    if (s != null) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if ((j['clips'] as List?)?.isNotEmpty ?? false) found = j;
      } catch (_) {}
    }
    setState(() => _draft = found);
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
          borderRadius: BorderRadius.circular(kDialogRadius),
          side: const BorderSide(color: kBorder),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: const [
                Text('加入浮水印',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                SizedBox(height: 16),
                _PickRow(
                    icon: Icons.videocam_outlined,
                    label: '影片',
                    hint: '單支或多支',
                    kind: _PickKind.video),
                _PickRow(
                    icon: Icons.image_outlined,
                    label: '照片',
                    hint: '單張或多張',
                    kind: _PickKind.photo),
                _PickRow(
                    icon: Icons.grid_view,
                    label: '照片拼圖',
                    hint: '多張照片組圖',
                    kind: _PickKind.collage),
                _PickRow(
                    icon: Icons.playlist_add,
                    label: '空白專案',
                    hint: '進去再加素材',
                    kind: _PickKind.blank,
                    divider: false),
              ],
            ),
          ),
        ),
      ),
    );
    if (kind == null || !mounted) return;

    switch (kind) {
      case _PickKind.video:
        // image_picker 沒有「只選影片」的 API，用混合選取再濾掉照片，
        // 這樣才留得住系統原生的相簿選取器
        final list = await ImagePicker().pickMultipleMedia();
        final videos = list.where(_isVideoFile).toList();
        // 提示交給批次頁進場後顯示——在這裡 show 會馬上被
        // 推上來的新頁面蓋住，使用者根本看不到
        await _openBatch(
          videos,
          hint: _countHint(
            skipped: list.length - videos.length,
            count: videos.length,
            unit: '部影片',
            soft: 30,
          ),
        );
      case _PickKind.photo:
        final list = await ImagePicker().pickMultiImage();
        await _openBatch(
          list,
          hint: _countHint(count: list.length, unit: '張照片', soft: 200),
        );
      case _PickKind.collage:
        // 直接進畫面，照片進去再挑。先挑照片的話，使用者還沒看到
        // 宮格就得決定要幾張，挑錯還要退出去重來
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CollageScreen()),
        );
      case _PickKind.blank:
        await _openBlank();
    }
  }

  /// 選完才講的提醒（略過的檔案、數量偏多）。
  /// 數量上限以前寫在選單上，但使用者還沒開始挑就先看到限制沒什麼用，
  /// 挑完才講才是他真的需要知道的時候
  String? _countHint({
    int skipped = 0,
    required int count,
    required String unit,
    required int soft,
  }) {
    final parts = [
      if (skipped > 0) '已略過 $skipped 個非影片檔案',
      if (count > soft) '選了 $count $unit，處理會比較久',
    ];
    return parts.isEmpty ? null : parts.join('；');
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

  /// 空白專案：不挑素材直接進影片編輯器。
  /// 跟開新影片一樣會蓋掉草稿，先問過
  Future<void> _openBlank() async {
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
      MaterialPageRoute(builder: (_) => const VideoEditorScreen(blank: true)),
    );
    _checkDraft();
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
              // logo 的高度位置＝上下這兩個 Spacer 的比例。
              // 按鈕群本來就佔掉底部一大塊，所以「上下等分」看起來
              // 已經略偏上了；再往上拉會變頭重腳輕
              const Spacer(flex: 38),
              Center(
                child: SizedBox(
                  width: 190,
                  height: 76,
                  // 透明背景版 logo：直接融進近黑背景，不用底板
                  // （icon_foreground.png 是啟動圖示前景，別共用）。
                  // 壓暗一階（0.85）不跟白色主按鈕搶注意力——
                  // 改這個數字就能微調「整組」亮度。
                  // 三隻各自的透明度是烘在 PNG 的 alpha 裡
                  // （左 75／中 42／右 16，各佔 x 132-378、382-628、
                  // 632-878），這裡調不動，要改得動圖檔
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
              ),
              const Spacer(flex: 32),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// 首頁三顆按鈕的圓角。改這一個數字三顆一起變。
/// 給一個夠大的值＝膠囊（全圓）：Skia 會自動把半徑夾到高度的一半，
/// 所以三顆高度不同也一樣圓。想改回一般圓角就填 18 之類的實際值
const double kHomeBtnRadius = 999;

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
      borderRadius: BorderRadius.circular(kHomeBtnRadius),
      onTap: onTap,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? kAmber : Colors.transparent,
          borderRadius: BorderRadius.circular(kHomeBtnRadius),
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
