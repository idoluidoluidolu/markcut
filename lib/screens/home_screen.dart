import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/video_picker.dart';

import '../services/preset_store.dart';
import '../nav.dart';
import '../theme.dart';
import 'batch_watermark_screen.dart';
import 'collage_screen.dart';
import 'gif_screen.dart';
import 'photo_editor_screen.dart';
import 'profile_screen.dart';
import 'video_editor_screen.dart';

/// 首頁：logo ＋ 四個入口方塊（浮水印／照片拼圖／GIF／剪輯），
/// 每一個直接進那個功能。以前是一顆「加入浮水印」先跳一個選單問
/// 「影片、照片、拼圖、GIF 還是空白專案」，現在那一層只剩浮水印
/// 自己要問的「照片還是影片」。
///
/// 「製作浮水印」（浮水印工作室）從首頁拿掉，走 個人中心 → 範本 → ＋
/// （見 profile_screen 的 _presetAddTile）
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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

  /// 草稿現在可以有很多份（見 DraftStore），開新專案不會蓋掉任何一份，
  /// 所以首頁不用再記「有沒有草稿」，也不用再問「要覆蓋嗎」。
  /// 留這個空殼是因為好幾個入口回來時都會呼叫它
  Future<void> _checkDraft() async {}

  bool _isVideoFile(XFile f) {
    final mime = f.mimeType;
    if (mime != null && mime.isNotEmpty) return mime.startsWith('video/');
    final ext = f.name.toLowerCase().split('.').last;
    return const {
      'mp4',
      'mov',
      'm4v',
      'avi',
      'mkv',
      'webm',
      '3gp',
      'ts',
      'mts',
    }.contains(ext);
  }

  /// 四個入口共用的重入鎖：選取器（或推出去的頁）還開著就別再開第二個
  /// ——連點兩下會疊兩層
  bool _picking = false;

  Future<void> _guarded(Future<void> Function() body) async {
    if (_picking) return;
    _picking = true;
    try {
      await body();
    } finally {
      _picking = false;
    }
  }

  /// 浮水印：先問要上在照片還是影片上（使用者指定），再開對應的選取器
  /// ——相簿混選看得到兩種，但兩邊之後的流程差很多（照片問要不要串成
  /// 影片、影片問要不要接成一支），先問一句比挑完才發現猜錯好。
  /// 一個進單檔編輯器、多個問要接成一支還是各自上浮水印（見 _openBatch）。
  /// iOS 拿相簿原檔：image_picker 會把每張照片重壓成 JPEG，
  /// HEIC 變 8-bit、HDR 增益圖在這一步就沒了（見 pickPhotoFiles）
  Future<void> _pickForWatermark() => _guarded(() async {
    final video = await _askPhotoOrVideo();
    if (video == null || !mounted) return;
    // 提示交給批次頁進場後顯示——在這裡 show 會馬上被
    // 推上來的新頁面蓋住，使用者根本看不到
    if (video) {
      final list = await pickVideoFiles();
      // 選取器照理只列影片，但 web／舊安卓那條路可能混進照片，這裡自己濾
      final videos = list.where(_isVideoFile).toList();
      await _openBatch(
        videos,
        hint: _countHint(
          skipped: list.length - videos.length,
          count: videos.length,
          unit: '部影片',
          soft: 30,
        ),
      );
    } else {
      final list = await pickPhotoFiles();
      await _openBatch(
        list,
        hint: _countHint(count: list.length, unit: '張照片', soft: 200),
      );
    }
  });

  /// 浮水印要上在哪一種素材上。true＝影片、false＝照片、null＝取消
  Future<bool?> _askPhotoOrVideo() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('要上浮水印的是'),
      contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      content: SizedBox(
        width: 270,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            optionRow(
              context: context,
              title: '照片',
              subtitle: '單張或整批',
              selected: false,
              first: true,
              onTap: () => Navigator.pop(context, false),
            ),
            optionRow(
              context: context,
              title: '影片',
              subtitle: '單支或整批',
              selected: false,
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    ),
  );

  /// 照片拼圖：直接進畫面，照片進去再挑。先挑照片的話，使用者還沒看到
  /// 宮格就得決定要幾張，挑錯還要退出去重來
  Future<void> _openCollage() => _guarded(() async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => const CollageScreen()),
    );
  });

  /// GIF：挑一支影片進 GIF 製作頁。一次做一支；多選了就拿第一支，
  /// 這裡不值得再多問一輪
  Future<void> _makeGif() => _guarded(() async {
    final list = await pickVideoFiles();
    final v = list.where(_isVideoFile).toList();
    if (v.isEmpty || !mounted) return;
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => GifScreen(path: v.first.path, name: v.first.name),
      ),
    );
  });

  /// 剪輯：不挑素材，直接開一條空的時間軸，照片、影片進去再加
  Future<void> _openBlank() => _guarded(() async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => const VideoEditorScreen(blank: true)),
    );
    _checkDraft();
  });

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

  /// 多支影片：問要接成一支（進剪輯）還是各自上浮水印（進批次）。
  /// 兩件事差很多，猜錯的代價是使用者整批重挑
  Future<bool?> _askMultiVideo(int n) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('選了 $n 部影片'),
      contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      content: SizedBox(
        width: 270,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            optionRow(
              context: context,
              title: '剪成一支影片',
              subtitle: '照選取順序接起來',
              selected: false,
              first: true,
              onTap: () => Navigator.pop(context, true),
            ),
            optionRow(
              context: context,
              title: '統一上浮水印',
              subtitle: '快速套用同一組浮水印',
              selected: false,
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    ),
  );

  /// 多張照片：問要串成一段影片（進剪輯）還是各自上浮水印（進批次）
  Future<bool?> _askMultiPhoto(int n) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('選了 $n 張照片'),
      contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      content: SizedBox(
        width: 270,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            optionRow(
              context: context,
              title: '串成一段影片',
              subtitle: '照選取順序串成影片',
              selected: false,
              first: true,
              onTap: () => Navigator.pop(context, true),
            ),
            optionRow(
              context: context,
              title: '統一上浮水印',
              subtitle: '快速套用同一個浮水印',
              selected: false,
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    ),
  );

  /// 一批照片串成影片：進影片編輯器，由它問每張幾秒
  Future<void> _openPhotosAsVideo(List<XFile> picked) async {
    await Navigator.push(
      context,
      editRoute(
        builder: (_) =>
            VideoEditorScreen(photoPaths: [for (final f in picked) f.path]),
      ),
    );
    _checkDraft();
  }

  /// 一支就進單檔編輯器，多支先問要剪成一支還是各自處理
  Future<void> _openBatch(List<XFile> list, {String? hint}) async {
    if (list.isEmpty || !mounted) return;
    if (list.length == 1) {
      final f = list.first;
      await (_isVideoFile(f) ? _openVideo(f) : _openPhoto(f));
      return;
    }
    if (list.every(_isVideoFile)) {
      final joinThem = await _askMultiVideo(list.length);
      if (joinThem == null || !mounted) return;
      if (joinThem) {
        await _openVideos(list);
        return;
      }
    } else if (list.every((f) => !_isVideoFile(f))) {
      // 一批照片：最常見的兩件事就是「串成一段影片」跟
      //「每張各自上浮水印」，猜錯的代價是整批重挑
      final joinThem = await _askMultiPhoto(list.length);
      if (joinThem == null || !mounted) return;
      if (joinThem) {
        await _openPhotosAsVideo(list);
        return;
      }
    }
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => BatchWatermarkScreen(files: list, initialHint: hint),
      ),
    );
  }

  Future<void> _openPhoto(XFile picked) async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => PhotoEditorScreen(photo: picked)),
    );
  }

  /// 一整批影片接成一支專案
  Future<void> _openVideos(List<XFile> picked) async {
    await Navigator.push(
      context,
      editRoute(
        builder: (_) =>
            VideoEditorScreen(videoPaths: [for (final f in picked) f.path]),
      ),
    );
    _checkDraft();
  }

  Future<void> _openVideo(XFile picked) async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => VideoEditorScreen(videoPath: picked.path)),
    );
    _checkDraft();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kLBg,
      appBar: AppBar(
        backgroundColor: kLBg,
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
                  builder: (_) => const LightPage(child: ProfileScreen()),
                ),
              );
              _checkDraft(); // 草稿可能在裡面被刪掉或接續了
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: LayoutBuilder(
            builder: (context, c) {
              // 方塊是正方形、四個等寬，所以那一排的高度是算得出來的：
              // 邊長（寬度扣掉三個間距再四等分）＋間距＋一行字。
              // 剩下的高度全給 logo，Expanded 保證它拿到的是有界的高度，
              // 放不下就等比縮小（縮到 0 也不會溢出）
              final side = (c.maxWidth - kHomeTileGap * 3) / 4;
              final labelH =
                  MediaQuery.textScalerOf(context).scale(kHomeTileLabelSize) *
                  1.4;
              final tilesH = side + kHomeTileLabelGap + labelH;
              // 連方塊那一排都放不下（橫向、超大字級）：不畫 logo、
              // 讓它自己捲，什麼高度都不溢出
              if (c.hasBoundedHeight && c.maxHeight < tilesH) {
                return SingleChildScrollView(child: _tiles());
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, lc) {
                        // 至少留 _kLogoAir 給 logo 上下喘息；不夠就縮小
                        final h = math.min(
                          kHomeLogoSize.height,
                          math.max(0.0, lc.maxHeight - _kLogoAir),
                        );
                        final w =
                            h * kHomeLogoSize.width / kHomeLogoSize.height;
                        return Center(
                          child: SizedBox(
                            width: w,
                            height: h,
                            // 直接用圖檔原本的樣子，不套任何顏色。
                            // 三隻的淡出是烘在 PNG 的 alpha 裡的（左 75／
                            // 中 42／右 16，各佔 x 132-378、382-628、
                            // 632-878），程式這邊調不動，要改得動圖檔。
                            // icon_foreground.png 是啟動圖示前景，別共用
                            child: Image.asset(
                              'assets/icon/home_logo.png',
                              fit: BoxFit.cover, // 裁掉原圖四周的留白
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  _tiles(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 四個入口方塊排成一排。第一個反白＝主要動作，其他三個淺灰
  Widget _tiles() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: _HomeTile(
          primary: true,
          icon: Icons.branding_watermark_outlined,
          label: '浮水印',
          onTap: _pickForWatermark,
        ),
      ),
      const SizedBox(width: kHomeTileGap),
      Expanded(
        child: _HomeTile(
          icon: Icons.grid_view_rounded,
          label: '照片拼圖',
          onTap: _openCollage,
        ),
      ),
      const SizedBox(width: kHomeTileGap),
      Expanded(
        child: _HomeTile(
          icon: Icons.gif_box_outlined,
          label: 'GIF',
          onTap: _makeGif,
        ),
      ),
      const SizedBox(width: kHomeTileGap),
      Expanded(
        child: _HomeTile(
          icon: Icons.smart_display_outlined,
          label: '剪輯',
          onTap: _openBlank,
        ),
      ),
    ],
  );
}

/// 入口方塊之間的間距、圓角、圖示大小，以及名稱那一行（版面算
/// 「放不放得下」也用這幾個數，見 build）。改這裡四個一起變
const double kHomeTileGap = 12;
const double kHomeTileRadius = 20;
const double kHomeTileIcon = 30;
const double kHomeTileLabelGap = 10;
const double kHomeTileLabelSize = 12;

/// logo 的版面尺寸（home_logo.png 裁掉四周留白後的比例）
const Size kHomeLogoSize = Size(190, 76);

/// 縮小 logo 之前至少要留給它上下的一點喘息空間
const double _kLogoAir = 24;

/// 首頁入口方塊：正方形圓角方塊裝一個圖示，名稱在下面。
/// 第一個反白（近黑底、白圖示）＝主要動作，其他三個淺灰底。
///
/// 方塊本身是 Material＋InkWell（水波紋要畫在底色上面）；外面再包一層
/// GestureDetector，讓下面那行字也按得到——手指本來就會落在字上，
/// 只有方塊可按的話會有一半的點擊沒反應。方塊上的點擊由比較深的
/// InkWell 贏走，不會兩邊都觸發
class _HomeTile extends StatelessWidget {
  final bool primary;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _HomeTile({
    this.primary = false,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = primary ? kLBg : kLText;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Material(
              color: primary ? kLAccent : kLTile,
              borderRadius: BorderRadius.circular(kHomeTileRadius),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Center(
                  child: Icon(icon, size: kHomeTileIcon, color: fg),
                ),
              ),
            ),
          ),
          const SizedBox(height: kHomeTileLabelGap),
          // 名稱放不下（字級放大到極端）就淡出：不折行、不裁字，
          // 也不觸發溢出條紋
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: const TextStyle(
              fontSize: kHomeTileLabelSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: kLText,
            ),
          ),
        ],
      ),
    );
  }
}
