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

/// 首頁：logo ＋ 四張入口卡（浮水印／照片拼圖／GIF／影片編輯），
/// 每一張直接進那個功能。以前是一顆「加入浮水印」先跳一個選單問
/// 「影片、照片、拼圖、GIF 還是空白專案」，現在少那一層。
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

  /// 四張入口共用的重入鎖：選取器（或推出去的頁）還開著就別再開第二個
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

  /// 浮水印：相簿混選（影片、照片都行、可多選），不先問「影片還是照片」
  ///（卡片上寫的「影片照片單支、批次快速上浮水印」）。
  /// 一個進單檔編輯器、多個問要接成一支還是各自上浮水印（見 _openBatch）。
  /// iOS 拿相簿原檔：image_picker 會把每張照片重壓成 JPEG，
  /// HEIC 變 8-bit、HDR 增益圖在這一步就沒了（見 pickMediaFiles）
  Future<void> _pickMedia() => _guarded(() async {
    final list = await pickMediaFiles();
    final videos = list.where(_isVideoFile).length;
    // 提示交給批次頁進場後顯示——在這裡 show 會馬上被
    // 推上來的新頁面蓋住，使用者根本看不到
    final hints = [
      _countHint(count: videos, unit: '部影片', soft: 30),
      _countHint(count: list.length - videos, unit: '張照片', soft: 200),
    ].nonNulls;
    await _openBatch(list, hint: hints.isEmpty ? null : hints.join('；'));
  });

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

  /// 影片編輯：不挑素材，直接開一條空的時間軸（卡片上寫的「開啟空軌道
  /// 編輯照片或影片」），照片、影片進去再加
  Future<void> _openBlank() => _guarded(() async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => const VideoEditorScreen(blank: true)),
    );
    _checkDraft();
  });

  /// 選完才講的提醒（數量偏多）。
  /// 數量上限以前寫在選單上，但使用者還沒開始挑就先看到限制沒什麼用，
  /// 挑完才講才是他真的需要知道的時候
  String? _countHint({
    required int count,
    required String unit,
    required int soft,
  }) => count > soft ? '選了 $count $unit，處理會比較久' : null;

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
              // 四張卡加間距是固定的（372）；剩下的高度給 logo 跟上下留白。
              // 手機直立（SE 的 375×667 起）都放得下完整的 logo；矮一點
              //（超大字級）logo 等比縮小；連四張卡都放不下（橫向）就不畫
              // logo、卡片自己捲——什麼高度都不會溢出
              const cards = 4 * kHomeCardH + 3 * kHomeCardGap;
              final spare = c.hasBoundedHeight
                  ? c.maxHeight - cards
                  : double.infinity;
              if (spare < 0) {
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _cards(),
                  ),
                );
              }
              final logoH = spare >= kHomeLogoSize.height + _kLogoAir
                  ? kHomeLogoSize.height
                  : (spare - _kLogoAir).clamp(0.0, kHomeLogoSize.height);
              final logoW = logoH * kHomeLogoSize.width / kHomeLogoSize.height;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // logo 的高度位置＝上下這兩個 Spacer 的比例。
                  // 卡片群本來就佔掉底部一大塊，所以「上下等分」看起來
                  // 已經略偏上了；再往上拉會變頭重腳輕
                  const Spacer(flex: 38),
                  Center(
                    child: SizedBox(
                      width: logoW,
                      height: logoH,
                      // 直接用圖檔原本的樣子，不套任何顏色。
                      // 三隻的淡出是烘在 PNG 的 alpha 裡的（左 75／中 42／
                      // 右 16，各佔 x 132-378、382-628、632-878），程式這邊
                      // 調不動，要改得動圖檔。
                      // icon_foreground.png 是啟動圖示前景，別共用
                      child: Image.asset(
                        'assets/icon/home_logo.png',
                        fit: BoxFit.cover, // 裁掉原圖四周的留白
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                  const Spacer(flex: 32),
                  ..._cards(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 四張入口卡由上而下，中間隔 kHomeCardGap。全部靠底。
  /// 說明文字是使用者親自定的，一字不改
  List<Widget> _cards() => [
    _HomeCard(
      icon: Icons.branding_watermark_outlined,
      label: '浮水印',
      sub: '影片照片單支、批次快速上浮水印',
      onTap: _pickMedia,
    ),
    const SizedBox(height: kHomeCardGap),
    _HomeCard(
      icon: Icons.grid_view_rounded,
      label: '照片拼圖',
      sub: '快速組圖',
      onTap: _openCollage,
    ),
    const SizedBox(height: kHomeCardGap),
    _HomeCard(
      icon: Icons.gif_box_outlined,
      label: 'GIF',
      sub: '影片轉成GIF',
      onTap: _makeGif,
    ),
    const SizedBox(height: kHomeCardGap),
    _HomeCard(
      icon: Icons.smart_display_outlined,
      label: '影片編輯',
      sub: '開啟空軌道編輯照片或影片',
      onTap: _openBlank,
    ),
  ];
}

/// 首頁入口卡的高度、間距、圓角（版面算「放不放得下」也用這幾個數，見 build）。
/// 改這裡四張一起變
const double kHomeCardH = 84;
const double kHomeCardGap = 12;
const double kHomeCardRadius = 18;

/// 卡片左邊那個淡灰底的圖示方塊：邊長、圓角、跟文字的間距。
/// 方塊固定寬、貼卡片左緣，四張的圖示跟文字自然落在同一個 x
const double kHomeTileSize = 44;
const double kHomeTileRadius = 12;
const double kHomeTileGap = 16;

/// 圖示方塊裡的圖示大小
const double kHomeTileIcon = 24;

/// logo 的版面尺寸（home_logo.png 裁掉四周留白後的比例）
const Size kHomeLogoSize = Size(190, 76);

/// 縮小 logo 之前至少要留給它上下的一點喘息空間
const double _kLogoAir = 24;

/// 卡片右邊那個「>」：比 kLTextDim 再淡一階，只是提示可以點，不搶文字
const Color _kChevron = Color(0xFFB0B0BA);

/// 首頁入口卡：白底描邊、淡灰圖示方塊＋名稱＋一行說明＋右邊一個「>」。
/// 四張同一個樣子——不反白任何一張（使用者定的：不要黑底）。
/// 卡片本體是 Material（水波紋才畫得在白底上面，Container 會把它蓋掉）
class _HomeCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;

  const _HomeCard({
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kLCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kHomeCardRadius),
        side: const BorderSide(color: kLBorder, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: kHomeCardH,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 18, 0),
            child: Row(
              children: [
                Container(
                  width: kHomeTileSize,
                  height: kHomeTileSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kLTile,
                    borderRadius: BorderRadius.circular(kHomeTileRadius),
                  ),
                  child: Icon(icon, size: kHomeTileIcon, color: kLText),
                ),
                const SizedBox(width: kHomeTileGap),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 名稱放不下（字級放大到極端）就淡出，不折行、
                      // 不觸發溢出條紋
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: kLText,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // 說明最長那句在 SE 的寬度一行擠不下，讓它折成兩行
                      //（84 高的卡兩行也放得下），再不夠才省略
                      Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          color: kLTextDim,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 22, color: _kChevron),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
