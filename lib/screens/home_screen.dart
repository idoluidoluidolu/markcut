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

/// 首頁：整片留給 logo，功能全收在底部那顆「＋ 開始」（使用者指定
/// 「首頁整個下方收掉，改成＋號叫出選單」，樣式從八種裡挑了滿版膠囊）。
///
/// ＋叫出來的是一張底部面板，四列：浮水印／照片拼圖／GIF／剪輯，各帶
/// 一行說明，右邊不畫箭頭（使用者指定；原本只有浮水印那列有，一列有
/// 三列沒有反而像壞掉）。第二層也是同一種面板，左上角一個返回——按下去
/// 回第一層，不是把整個選單關掉（見 _showSheet 的 backValue 與
/// _openMenu 的迴圈）：
///   浮水印 → 照片／影片（挑完的流程跟以前一樣，見 _openBatch）
///   照片拼圖 → 直接進拼圖頁
///   GIF → 直接開影片選取器，挑一支進 GIF 製作頁。這裡只有「製作」
///          一條路：把現成的 GIF 收進來是 個人中心 →「我的 GIF」那顆＋
///          的事（使用者指定，見 addGifFromDevice）
///   剪輯 → 直接開一條空的時間軸
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
  }

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

  /// ＋選單共用的重入鎖：選取器（或推出去的頁）還開著就別再開第二個
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
  /// 一個進單檔編輯器，多個直接進批次頁（見 _openBatch）。
  /// iOS 拿相簿原檔：image_picker 會把每張照片重壓成 JPEG，
  /// HEIC 變 8-bit、HDR 增益圖在這一步就沒了（見 pickPhotoFiles）
  ///
  /// 不再自己上重入鎖：唯一的呼叫點是 [_openMenu]，而它整段都在鎖裡
  /// ——巢狀呼叫會被自己的鎖擋掉，第二層面板永遠開不出來
  ///
  /// 回傳「要不要回到第一層」：第二層按了返回是 true，其餘（挑完了、
  /// 整個關掉、選取器按取消）都是 false
  Future<bool> _pickForWatermark() async {
    final kind = await _askPhotoOrVideo();
    if (kind == null || !mounted) return false;
    if (kind == _Media.back) return true;
    final video = kind == _Media.video;
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
    return false;
  }

  /// 浮水印的第二層：要上在哪一種素材上。[_Media.back]＝按了左上角的
  /// 返回（要回第一層）、null＝整個關掉（往下滑、點面板外面）
  Future<_Media?> _askPhotoOrVideo() => _showSheet<_Media>(
    back: '浮水印',
    backValue: _Media.back,
    rows: const [
      _SheetRow(
        icon: Icons.photo_outlined,
        label: '照片',
        sub: '單張或整批',
        value: _Media.photo,
      ),
      _SheetRow(
        icon: Icons.movie_outlined,
        label: '影片',
        sub: '單支或整批',
        value: _Media.video,
      ),
    ],
  );

  /// GIF：挑一支影片進 GIF 製作頁。一次做一支；多選了就拿第一支，
  /// 這裡不值得再多問一輪。
  ///
  /// 只有「製作」這一條（使用者指定：「GIF 不要有匯入現成的，就是製作
  /// 就好」）——把現成的 GIF 收進來是 個人中心 →「我的 GIF」那顆＋的事
  /// （見 addGifFromDevice），兩邊不重複。
  ///
  /// 跟 [_pickForWatermark] 一樣不自己上重入鎖：唯一的呼叫點 [_openMenu]
  /// 整段都在鎖裡，巢狀呼叫會被自己的鎖擋掉
  Future<void> _makeGif() async {
    final list = await pickVideoFiles();
    final v = list.where(_isVideoFile).toList();
    if (v.isEmpty || !mounted) return;
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => GifScreen(path: v.first.path, name: v.first.name),
      ),
    );
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

  /// 一支就進單檔編輯器，多支直接進批次頁。
  ///
  /// 中間本來還有一問:多支影片問「剪成一支影片／統一上浮水印」、多張
  /// 照片問「串成一段影片／統一上浮水印」。使用者指定拿掉——這條路是從
  /// 「浮水印」進來的，要的就是上浮水印;要把素材接起來是「剪輯」那一列
  /// 的事，在這裡多問一句等於每次都要再答一次已經答過的問題
  Future<void> _openBatch(List<XFile> list, {String? hint}) async {
    if (list.isEmpty || !mounted) return;
    if (list.length == 1) {
      final f = list.first;
      await (_isVideoFile(f) ? _openVideo(f) : _openPhoto(f));
      return;
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

  Future<void> _openVideo(XFile picked) async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => VideoEditorScreen(videoPath: picked.path)),
    );
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
            // 草稿可以有很多份（見 DraftStore），開新專案不會蓋掉任何
            // 一份，所以首頁回來不用重讀「有沒有草稿」
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LightPage(child: ProfileScreen()),
              ),
            ),
          ),
        ],
      ),
      // 整頁唯一的入口，所以給它整條寬度（使用者挑的樣式）
      floatingActionButton: SizedBox(
        width: _startWidth(context),
        height: kHomeStartH,
        child: FloatingActionButton.extended(
          tooltip: '開始',
          onPressed: _openMenu,
          backgroundColor: kLAccent,
          foregroundColor: kLBg,
          shape: const StadiumBorder(),
          // 預設的 6 在一片白底上太重（測試回報）。黑膠囊本來就跟白底
          // 對比到底了，陰影只要交代它浮在內容上面，不用再撐體積；
          // 按下去也不跳成 12，那一下的影子比按鈕本身還顯眼
          elevation: kHomeStartElevation,
          focusElevation: kHomeStartElevation,
          hoverElevation: kHomeStartElevation,
          highlightElevation: kHomeStartElevation,
          icon: const Icon(Icons.add, size: 22),
          label: const Text(
            '開始',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: const _StartFabLocation(),
      // AppBar 佔掉的高度本來會把 body 整個往下推，logo 因此落在畫面
      // 中線下面約 50（測試回報「寶寶沒置中」）。讓 body 從畫面最上緣
      // 開始畫，AppBar 浮在上面——它是不透明的白底，蓋住的也是白的。
      // 這裡不包 SafeArea：包了等於又把上下的安全區扣掉一次，中線又歪
      extendBodyBehindAppBar: true,
      body: Center(
        // logo 置中在整片留白裡。直接用圖檔原本的樣子，不套任何顏色：
        // 三隻的淡出是烘在 PNG 的 alpha 裡的（左 75／中 42／右 16，
        // 各佔 x 132-378、382-628、632-878），程式這邊調不動。
        // icon_foreground.png 是啟動圖示前景，別共用
        child: SizedBox(
          width: kHomeLogoSize.width,
          height: kHomeLogoSize.height,
          child: Image.asset(
            'assets/icon/home_logo.png',
            fit: BoxFit.cover, // 裁掉原圖四周的留白
            filterQuality: FilterQuality.medium,
            // 檔案是 868×361，畫出來只有 190×76：不給解碼寬度的話整張
            // 以原尺寸進圖快取（868×361×4 ≈ 1.25MB），而首頁一直開著，
            // 那 1.25MB 就一直佔著。cover 在這個框是貼寬
            //（190/868 > 76/361），照「畫出來的寬 × dpr」解就夠
            cacheWidth:
                (kHomeLogoSize.width * MediaQuery.devicePixelRatioOf(context))
                    .round(),
          ),
        ),
      ),
    );
  }

  /// 「＋ 開始」的寬度：左右各留 [kHomeStartPad]，但不讓它在平板／
  /// 橫向上拉成一條誇張的長棒（[kHomeStartMaxW] 封頂）
  double _startWidth(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width - kHomeStartPad * 2;
    return w > kHomeStartMaxW ? kHomeStartMaxW : w;
  }

  /// ＋：叫出第一層面板，再照選到的往下走。
  ///
  /// 這裡是一個迴圈，不是一次性的：第二層左上角的返回要回到這一層
  /// （[_pickForWatermark] 回 true），不是把整個選單關掉。整段都在
  /// [_guarded] 裡，所以來回幾次都不會疊出第二個面板
  Future<void> _openMenu() => _guarded(() async {
    var again = true;
    while (again) {
      again = false;
      final pick = await _askAction();
      if (pick == null || !mounted) return;
      switch (pick) {
        case _HomeAction.watermark:
          again = await _pickForWatermark();
        case _HomeAction.collage:
          // 直接進畫面，照片進去再挑：先挑照片的話，使用者還沒看到宮格
          // 就得決定要幾張，挑錯還要退出去重來
          await Navigator.push(
            context,
            editRoute(builder: (_) => const CollageScreen()),
          );
        case _HomeAction.gif:
          await _makeGif();
        case _HomeAction.cut:
          // 不挑素材，直接開一條空的時間軸，照片、影片進去再加
          await Navigator.push(
            context,
            editRoute(builder: (_) => const VideoEditorScreen(blank: true)),
          );
      }
    }
  });

  /// 第一層：四個去處
  Future<_HomeAction?> _askAction() => _showSheet<_HomeAction>(
    rows: const [
      _SheetRow(
        icon: Icons.branding_watermark_outlined,
        label: '浮水印',
        sub: '照片、影片，單支或整批快速加入浮水印',
        value: _HomeAction.watermark,
      ),
      _SheetRow(
        icon: Icons.grid_view_rounded,
        label: '照片拼圖',
        sub: '多張照片拼成一張',
        value: _HomeAction.collage,
      ),
      _SheetRow(
        icon: Icons.gif_box_outlined,
        label: 'GIF',
        sub: '影片轉成 GIF',
        value: _HomeAction.gif,
      ),
      _SheetRow(
        icon: Icons.smart_display_outlined,
        label: '剪輯',
        sub: '開啟一個空專案自由編輯',
        value: _HomeAction.cut,
      ),
    ],
  );

  /// 這一頁的面板長相：白底、上緣圓角、一根抓把，每列是
  /// 圖示方塊＋名稱＋一行說明。
  /// [back] 有值＝第二層，最上面多一行「‹ 那一項的名字」；按下去 pop 出
  /// [backValue]，呼叫端據此重開第一層（不給就跟關掉一樣是 null）
  Future<T?> _showSheet<T>({
    List<_SheetRow<T>> rows = const [],
    String? back,
    T? backValue,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: kLBg,
      showDragHandle: true,
      // 面板自己管高度：showModalBottomSheet 預設把面板壓在畫面高度的
      // 9/16 以下，橫向時（375／390 高）四列（48 抓把＋4×68＋16＝336）
      // 根本裝不下——GIF、剪輯兩列被切在畫面外按不到，320×568 直向也
      // 差 17。iOS 允許橫向、Android 沒鎖方向，這是真的會遇到的情境。
      // 放開上限之後內容多高面板就多高，裝不下的那一截交給底下的
      // SingleChildScrollView 捲；useSafeArea 讓它躲開狀態列
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 它長得就是一顆返回鍵，那就要真的能按：本來只是畫上去的
                // 一行字，使用者按了沒反應。整條（含文字右邊的空白）都是
                // 熱區——箭頭才 22，只有那一小塊按得到等於按不到
                if (back != null)
                  InkWell(
                    onTap: () => Navigator.pop(context, backValue),
                    child: SizedBox(
                      height: kHomeSheetBackH,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.chevron_left,
                            size: 22,
                            color: kLText,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            back,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                              color: kLText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final r in rows)
                  InkWell(
                    onTap: () => Navigator.pop(context, r.value),
                    // 高度是下限不是定值：320 寬時第一列的說明會折成兩行
                    // （見下面的 maxLines），列要跟著長，不然字級 1.2 時
                    // 兩行說明＋名稱就超過 68、從底下溢出
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: kHomeSheetRowH,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: ShapeDecoration(
                              color: kLTile,
                              shape: tileShape(),
                            ),
                            child: Icon(r.icon, size: 22, color: kLText),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                    color: kLText,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                // 說明是使用者給的整句（「照片、影片，單支或
                                // 整批快速加入浮水印」18 個字），320 寬扣掉
                                // 圖示與留白只剩 218，連 1.0 字級都放不下一行
                                // ——與其截成「…」不如折成兩行
                                Text(
                                  r.sub,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: kLTextDim,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ＋選單第一層的四個去處
enum _HomeAction { watermark, collage, gif, cut }

/// 浮水印第二層的結果：兩種素材，加上「回上一層」
enum _Media { photo, video, back }

/// 面板上的一列
class _SheetRow<T> {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.sub,
    required this.value,
  });

  final IconData icon;
  final String label;

  /// 名稱底下那一行說明
  final String sub;

  /// 點下去 pop 出來的值
  final T value;
}

/// 底部「＋ 開始」的高度
const double kHomeStartH = 56;

/// 它左右各留的邊
const double kHomeStartPad = 24;

/// 再寬也不超過這個（平板、橫向）
const double kHomeStartMaxW = 420;

/// 「＋ 開始」離畫面底邊多遠（沒有 home indicator 的機子）。
/// 30 是使用者挑的那張比稿圖上的距離
const double kHomeStartGap = 30;

/// 有 home indicator 時，至少要離安全區這麼遠
const double kHomeStartSafeGap = 8;

/// 陰影（預設 6 太重，測試回報）
const double kHomeStartElevation = 2;

/// 「＋ 開始」的落點：離畫面底邊 [kHomeStartGap]，但不壓到 home
/// indicator——安全區上面至少留 [kHomeStartSafeGap]。
///
/// 本來用 centerFloat，它是「安全區再加 16」：沒有安全區的機子上剛好，
/// 有 home indicator 的就變成 16＋34＝50 起跳，看起來浮得太高
/// （測試回報「位置太上面」）。這裡改成從畫面底邊算，安全區只當下限
class _StartFabLocation extends FloatingActionButtonLocation {
  const _StartFabLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry g) {
    final floor = g.minViewPadding.bottom + kHomeStartSafeGap;
    final gap = floor > kHomeStartGap ? floor : kHomeStartGap;
    return Offset(
      (g.scaffoldSize.width - g.floatingActionButtonSize.width) / 2,
      g.scaffoldSize.height - gap - g.floatingActionButtonSize.height,
    );
  }

  @override
  String toString() => 'HomeStartFabLocation';
}

/// 面板上一列的高度
const double kHomeSheetRowH = 68;

/// 第二層最上面那條返回列的高度（＝它的觸控熱區）
const double kHomeSheetBackH = 44;

/// logo 的版面尺寸（home_logo.png 裁掉四周留白後的比例）
const Size kHomeLogoSize = Size(190, 76);
