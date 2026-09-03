import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/watermark_settings.dart';
import '../services/draft_store.dart';
import '../services/file_reader.dart';
import '../services/gif_store.dart';
import '../services/preset_store.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets/gif_image.dart';
import '../widgets/swipe_back.dart';
import '../widgets/watermark_layer.dart';
import 'about_screen.dart';
import 'donate_screen.dart';
import 'feedback_screen.dart';
import 'batch_watermark_screen.dart';
import 'collage_screen.dart';
import 'gif_screen.dart';
import 'photo_editor_screen.dart';
import 'presets_screen.dart';
import 'watermark_studio_screen.dart';
import 'video_editor_screen.dart';

/// 個人中心：範本夾＋草稿夾＋意見回饋
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

/// 頁面左右的留白。範本那排要出血，所以留白不放在外層，
/// 由每一段自己給
const _side = EdgeInsets.symmetric(horizontal: 22);

/// 卡片的柔和陰影（C 案的層次感：白底之上讓封面微微浮起）
const _tileShadow = [
  BoxShadow(color: Color(0x1E000000), blurRadius: 10, offset: Offset(0, 4)),
];

/// 從相簿收一個 GIF 進「我的 GIF」（跟編輯器挑 GIF 的驗證同一套）。
/// 成功回存好的參照；取消或失敗回 null（失敗會自己提示）
Future<String?> importGifFromGallery(BuildContext context) async {
  final r = await FilePicker.platform.pickFiles(type: FileType.image);
  final path = (r == null || r.files.isEmpty) ? null : r.files.first.path;
  if (path == null) return null;
  if (!path.toLowerCase().endsWith('.gif')) {
    if (context.mounted) {
      showHint(context, '這不是 GIF，請選會動的那種', error: true);
    }
    return null;
  }
  final saved = await GifStore.add(path);
  if (saved == null && context.mounted) {
    // web 存不了檔（展示模式只有內建範例）
    showHint(context, '這裡收不進來，請在手機 App 上用', error: true);
  }
  return saved;
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<WatermarkPreset> _presets = const [];

  /// 影片草稿與照片草稿（沒有就是 null）。這一頁直接把草稿畫出來，
  /// 不再只顯示「有幾個」——使用者要找的是「那一個專案」，不是數量
  /// 影片草稿清單（可以有很多份，見 DraftStore）
  List<DraftMeta> _videoDrafts = const [];

  /// 做好的 GIF（見 GifStore；Web 是內建範例）
  List<String> _gifs = const [];
  Map<String, dynamic>? _photoDraft;

  /// 批次浮水印的未完成草稿（見 kBatchDraftKey）
  Map<String, dynamic>? _batchDraft;

  /// GIF 製作／拼圖的未完成草稿（見 kGifDraftKey / kCollageDraftKey）
  Map<String, dynamic>? _gifDraft;
  Map<String, dynamic>? _collageDraft;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final presets = await PresetStore.load();
    final videoDrafts = await DraftStore.list();
    final gifs = await GifStore.list();
    final prefs = await SharedPreferences.getInstance();

    Map<String, dynamic>? readDraft(String key, String contentKey) {
      final s = prefs.getString(key);
      if (s == null) return null;
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        final v = j[contentKey];
        final has = v is List ? v.isNotEmpty : (v is String && v.isNotEmpty);
        return has ? j : null;
      } catch (_) {
        return null;
      }
    }

    if (!mounted) return;
    setState(() {
      _presets = presets;
      _videoDrafts = videoDrafts;
      _gifs = gifs;
      _photoDraft = readDraft(kPhotoDraftKey, 'photo');
      _batchDraft = readDraft(kBatchDraftKey, 'files');
      _gifDraft = readDraft(kGifDraftKey, 'path');
      _collageDraft = readDraft(kCollageDraftKey, 'photos');
    });
    unawaited(_loadCovers(videoDrafts));
  }

  /// 草稿封面：內容另外存（見 DraftStore.thumb），讀進來後放這個
  /// 快取；build 裡只查表，不解碼也不丟例外
  final Map<String, Uint8List> _covers = {};

  Future<void> _loadCovers(List<DraftMeta> metas) async {
    for (final m in metas) {
      if (!m.hasThumb || _covers.containsKey(m.id)) continue;
      final t = await DraftStore.thumb(m.id);
      if (t == null) continue;
      try {
        _covers[m.id] = base64Decode(t);
      } catch (_) {
        // 壞掉的那筆就沒有封面，不能讓整頁紅屏
      }
    }
    if (mounted) setState(() {});
  }

  // ── 區塊標題：一行大粗字，右邊放次要資訊 ────────────────────
  // 點「標題」或右邊的「全部」都能進該區的總覽（使用者指定），
  // 所以整列包一個 GestureDetector，不是只有右邊的小字能點
  Widget _sectionTitle(String title, {String? trailing, VoidCallback? onTap}) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                title,
                // 頁面大標拿掉後，區塊標題升為主角：20/w800
                //（A 案，使用者指定「標題有點小」）
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 1, left: 12),
                child: Text(
                  trailing,
                  // 跟著標題放大一點，不然比例失衡（A 案 mockup 是 13）
                  style: const TextStyle(fontSize: 13, color: kLTextDim),
                ),
              ),
          ],
        ),
      );

  /// 範本磚：深色方塊，裡面就是這組浮水印長什麼樣。
  /// 用真的 WatermarkLayer 照實渲染（多文字、多圖、平鋪全都畫）——
  /// 以前只挑第一張圖或第一行字當代表，跟實際內容對不上
  /// 範本磚：跟草稿卡同一套長相（滿版封面＋左對齊標題），
  /// 兩欄流用（使用者指定「範本也用瀑布流」）
  Widget _presetTile(WatermarkPreset preset, {required double w}) {
    return GestureDetector(
      // 點磚＝直接編輯那一組（以前是跳到範本夾，還要再找一次）；
      // 長按＝刪除。右上角「全部」才是進範本夾
      onTap: () => Navigator.push(
        context,
        editRoute(builder: (_) => WatermarkStudioScreen(edit: preset)),
      ).then((_) => _reload()),
      onLongPress: () => _confirmDeletePreset(preset),
      // 不放名字（使用者指定）：封面本身就是內容，名字進範本夾看
      child: Container(
        width: w,
        height: w,
        // 內容照卡片的圓角切齊：範本可以是一張鋪滿磚面的圖，
        // 不切的話四個角會被方形的內容頂出去
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B20),
          borderRadius: BorderRadius.circular(kPresetRadius),
          boxShadow: _tileShadow,
        ),
        child: IgnorePointer(
          child: WatermarkLayer(settings: preset.settings, onChanged: () {}),
        ),
      ),
    );
  }

  /// 長按範本磚：問一下再刪
  Future<void> _confirmDeletePreset(WatermarkPreset p) async {
    final ok = await showConfirm(
      context,
      title: '刪除範本「${p.name}」？',
      message: '刪除後無法復原',
      action: '刪除',
    );
    if (!ok) return;
    await PresetStore.remove(p.name);
    _reload();
  }

  /// 範本區最後一格：新增——直接開工作室做一組新的
  ///（使用者指定：＋就是新增，總覽走標題或「全部」）
  Widget _presetAddTile({required double w}) => GestureDetector(
    onTap: () => Navigator.push(
      context,
      editRoute(builder: (_) => const WatermarkStudioScreen()),
    ).then((_) => _reload()),
    child: Container(
      width: w,
      height: w,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kLCard,
        borderRadius: BorderRadius.circular(kPresetRadius),
        border: Border.all(color: kLBorder, width: 1.4),
      ),
      child: const Text(
        '＋',
        style: TextStyle(
          fontSize: 30,
          color: Color(0xFFB0B0BA),
          fontWeight: FontWeight.w300,
        ),
      ),
    ),
  );

  /// 草稿卡：長條的。上面一塊方形縮圖區（直式影片置中留邊，橫式也放得下），
  /// 下面名稱與時間——加起來整張是直的，直片橫片排在一起高度才一致
  /// 草稿：縮圖本身就是卡（滿版、圓角），文字放在卡片外面。
  ///
  /// 本來是「白卡包著一塊灰底、灰底裡再放縮圖」——兩層框、三種底色，
  /// 而畫面上真正有資訊的只有縮圖。拿掉外框之後縮圖可以直接鋪滿，
  /// 也就是相簿、專案列表那種長相
  /// 卡片不寫時間（使用者指定）：影片草稿只留封面；照片/批次草稿
  /// 沒有縮圖，留一行說明字不然認不出是什麼
  Widget _draftTile({
    required Widget cover,
    String? title,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF1F1F5),
              borderRadius: BorderRadius.circular(18),
              boxShadow: _tileShadow,
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: cover,
          ),
        ),
        if (title != null) ...[
          const SizedBox(height: 9),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
          ),
        ],
      ],
    ),
  );

  Future<void> _openGifs() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LightPage(child: GifsScreen())),
    );
    _reload();
  }

  /// 直接開某一份草稿：卡片點下去就是要繼續剪，不是進資料夾
  Future<void> _openDraft(DraftMeta m) async {
    final data = await DraftStore.load(m.id);
    if (!mounted) return;
    if (data == null) {
      showHint(context, '這份草稿讀不到了', error: true);
      return;
    }
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => VideoEditorScreen(draft: data, draftId: m.id),
      ),
    );
    _reload();
  }

  Future<void> _openDrafts() async {
    await Navigator.push(
      context,
      // LightPage 一定要包：這是亮色頁，漏包就掉進暗色主題
      //（背景變黑、白卡片浮在上面，超跳）
      MaterialPageRoute(builder: (_) => const LightPage(child: DraftsScreen())),
    );
    _reload();
  }

  /// 草稿區：所有影片草稿＋照片草稿，兩欄排。
  ///
  /// 卡片是「縮圖＋兩行字」的直式 Column（高度看內容），GridView 要
  /// 指定長寬比反而每台機器都要重調——直接兩張一列手排
  Widget _draftGrid(Map<String, dynamic>? p) {
    final tiles = <Widget>[
      for (final m in _videoDrafts)
        _draftTile(
          cover: _covers[m.id] != null
              ? Image.memory(
                  _covers[m.id]!,
                  // 鋪滿：這是縮圖不是預覽，留邊只會讓一排卡看起來破碎
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                )
              : const Icon(
                  Icons.movie_outlined,
                  size: 26,
                  color: Color(0xFFAFAFBB),
                ),
          onTap: () => _openDraft(m),
        ),
      if (p != null)
        _draftTile(
          // 照片草稿沒有存縮圖（那張照片還在裝置上，
          // 再存一份只是浪費空間）
          cover: const Icon(
            Icons.image_outlined,
            size: 26,
            color: Color(0xFFAFAFBB),
          ),
          title: '未完成的照片',
          onTap: _openDrafts,
        ),
      if (_batchDraft != null)
        _draftTile(
          cover: const Icon(
            Icons.collections_outlined,
            size: 26,
            color: Color(0xFFAFAFBB),
          ),
          title: '未完成的批次浮水印',
          onTap: _openDrafts,
        ),
      if (_gifDraft != null)
        _draftTile(
          cover: const Icon(
            Icons.gif_box_outlined,
            size: 26,
            color: Color(0xFFAFAFBB),
          ),
          title: '未完成的 GIF',
          onTap: _openDrafts,
        ),
      if (_collageDraft != null)
        _draftTile(
          cover: const Icon(
            Icons.grid_view,
            size: 26,
            color: Color(0xFFAFAFBB),
          ),
          title: '未完成的拼圖',
          onTap: _openDrafts,
        ),
    ];
    // 最多兩張：整片列出來會把頁面吃光，其餘按「全部」進草稿夾
    final shown = tiles.take(2).toList();
    return Column(
      children: [
        for (var i = 0; i < shown.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: shown[i]),
              const SizedBox(width: 12),
              // 奇數張時右邊補空，卡片才不會被撐成整排寬
              Expanded(
                child: i + 1 < shown.length ? shown[i + 1] : const SizedBox(),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _openLove() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LightPage(child: DonateScreen())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _photoDraft;
    final draftCount = _videoDrafts.length + (p == null ? 0 : 1);
    // 非編輯頁面全頁都能右滑返回（編輯畫面橫向手勢太多，刻意不放）
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kLBg,
        // 返回鈕浮在內容上、不畫底：內容從螢幕頂捲到底，上下都沒有
        // 釘死的白帶（實測回報「上面不要白條 sticky」）。
        // scrolledUnderElevation 也要關：Material 3 捲動時會自己
        // 補一層 tint，白條就回來了
        // 返回鍵跟著內容捲（使用者指定「上方箭頭不要 sticky」）：
        // 不掛 appBar，箭頭當捲動內容的第一列。
        // 上下都不留 SafeArea：留了就是一條釘死的白帶，
        // 內容捲不進去；狀態列/home 條的位置由內容自己的留白扛
        body: SafeArea(
          top: false,
          bottom: false,
          // 左右留白改由各段自己給：範本那排要滿版出血（捲出畫面外），
          // 外層一留白它就被切在邊上，看起來像少畫了一格
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    top: 4 + MediaQuery.of(context).padding.top,
                    bottom: 12 + MediaQuery.of(context).padding.bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 「我的東西」大字拿掉，只放上一頁箭頭（A 案，
                      // 使用者指定）；主標的重量讓給各區塊標題（20）
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 22, 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(
                              Icons.arrow_back_ios_new,
                              size: 22,
                              color: kLText,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: _side,
                        child: _sectionTitle(
                          '範本',
                          // 不顯示數量，一律「全部」（跟草稿區一致）
                          trailing: _presets.isEmpty ? '還沒有' : '全部',
                          // 點標題或「全部」都進範本總覽；
                          // ＋磚才是直接新增（見 _presetAddTile）
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const LightPage(child: PresetsScreen()),
                            ),
                          ).then((_) => _reload()),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // 範本跟草稿同一套兩欄流（使用者指定）：
                      // 只放一排、優先放兩組範本（使用者指定）：
                      // 不足兩組才用「新增」磚補位，其餘按「全部」
                      // 進範本夾
                      Padding(
                        padding: _side,
                        child: LayoutBuilder(
                          builder: (context, cons) {
                            final colW = (cons.maxWidth - 10) / 2;
                            final tiles = <Widget>[
                              for (final pr in _presets.take(2))
                                _presetTile(pr, w: colW),
                            ];
                            if (tiles.length < 2) {
                              tiles.add(_presetAddTile(w: colW));
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var i = 0; i < tiles.length; i++) ...[
                                  if (i > 0) const SizedBox(width: 10),
                                  tiles[i],
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                      // 區塊間距統一 26（以前範本後、GIF 前各一個
                      // 26 疊起來，範本跟 GIF 的間隔比別區大一倍）
                      const SizedBox(height: 26),
                      // GIF 做好會存一份在 App 裡（相簿那份跟幾千張
                      // 照片混在一起，要拿它當素材根本找不到）。
                      // 空的時候區塊留著（使用者指定）：標題＋一行
                      // 灰字，跟草稿的空狀態同一套
                      Padding(
                        padding: _side,
                        child: _sectionTitle(
                          '我的 GIF',
                          trailing: _gifs.isEmpty ? '還沒有' : '全部',
                          onTap: _gifs.isEmpty ? null : _openGifs,
                        ),
                      ),
                      // 主頁這排不放「＋」（使用者指定）：匯入自己的
                      // GIF 走 GIF 夾右下角的浮動 +（或編輯器挑 GIF
                      // 的「從相簿選」）。空的時候一行灰字
                      if (_gifs.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 16, bottom: 4),
                          child: Center(
                            child: Text(
                              '還沒有 GIF',
                              style: TextStyle(
                                fontSize: 13,
                                color: Color(0xFFA8A8B4),
                              ),
                            ),
                          ),
                        )
                      else ...[
                        const SizedBox(height: 14),
                        // 固定三格、不出血（使用者指定：以前橫向清單
                        // 一直延伸出畫面）。其餘按「全部」進 GIF 夾
                        Padding(
                          padding: _side,
                          child: LayoutBuilder(
                            builder: (context, cons) {
                              final w = (cons.maxWidth - 20) / 3;
                              return Row(
                                children: [
                                  for (final (i, g)
                                      in _gifs.take(3).toList().indexed) ...[
                                    if (i > 0) const SizedBox(width: 10),
                                    GestureDetector(
                                      onTap: _openGifs,
                                      child: Container(
                                        width: w,
                                        height: w,
                                        decoration: BoxDecoration(
                                          color: kLTile,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          boxShadow: _tileShadow,
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: GifImage(g),
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                      // 跟下面那一區隔開，不然「草稿」會黏在
                      // GIF 那排的下緣上
                      const SizedBox(height: 26),
                      Padding(
                        padding: _side,
                        child: _sectionTitle(
                          '草稿',
                          // 空的時候不放「沒有」：下面那行字已經說了，
                          // 標題右邊再寫一次只是重複
                          trailing: draftCount == 0 ? null : '全部',
                          onTap: draftCount == 0 ? null : _openDrafts,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (draftCount == 0)
                        // 空的時候不畫框：一個又扁又寬的空盒子跟旁邊
                        // 的長條卡不是同一種東西，看起來像沒做完。
                        // 也不解釋草稿怎麼來——真的存了一份之後這行
                        // 就永遠不會再出現，講了也是白講
                        const Padding(
                          padding: EdgeInsets.only(top: 10, bottom: 4),
                          child: Center(
                            child: Text(
                              '還沒有草稿',
                              style: TextStyle(
                                fontSize: 13,
                                color: Color(0xFFA8A8B4),
                              ),
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: _side,
                          // 全部列出來（兩欄）：本來只放最近一份、其餘要
                          // 進草稿夾看，但清單就在這一頁，藏起來只是多一步
                          child: _draftGrid(p),
                        ),
                      // 行動鈕跟頁尾連結跟著內容捲（不釘底）：
                      // 釘底會一直吃掉一截可視高度，草稿多的時候很擠
                      const SizedBox(height: 30),
                      Padding(
                        padding: _side,
                        child: GestureDetector(
                          onTap: _openLove,
                          child: Container(
                            height: 54,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: kLAccent,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '太好用啦',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GestureDetector(
                            onTap: () => showFeedbackDialog(context),
                            child: const Text(
                              '意見回饋',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: kLTextDim,
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              '·',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFFB0B0BA),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const LightPage(child: AboutScreen()),
                              ),
                            ),
                            child: const Text(
                              '關於這個 App',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: kLTextDim,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 草稿夾：列出所有未完成的影片專案（可以有很多份），
/// 點一下繼續、長按改名或刪除
class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  List<DraftMeta> _drafts = const [];

  /// 照片編輯的草稿（離開時選「保留草稿」才會有）
  Map<String, dynamic>? _photoDraft;

  /// 批次浮水印的草稿（見 kBatchDraftKey）
  Map<String, dynamic>? _batchDraft;

  /// GIF 製作／拼圖的草稿（見 kGifDraftKey / kCollageDraftKey）
  Map<String, dynamic>? _gifDraft;
  Map<String, dynamic>? _collageDraft;
  bool _loading = true;

  /// 保留幾份：固定 30，沒有設定可以調（使用者指定）。
  /// 只是手動清理的基準，不會自動刪，見 _cleanupOld
  static const _cap = DraftStore.maxDrafts;

  /// 選取模式：勾好幾份、右上角垃圾桶一次刪
  bool _selecting = false;
  final Set<String> _picked = {};

  /// 手動清理：只有使用者按下去才會刪。自動清理全部拿掉了——
  /// 它要把每份草稿的完整 JSON（含縮圖與圖片）讀進來比對引用，
  /// 草稿多時是幾十 MB 的掃描，掛在開機/存檔路徑上會讓 App 被系統
  /// 殺掉（實機回報：開機即當、匯入卡住後閃退）
  Future<void> _cleanupOld() async {
    final over = _drafts.length - _cap;
    if (over <= 0) {
      showHint(context, '草稿沒有超過 $_cap 份，不用清');
      return;
    }
    final ok = await showConfirm(
      context,
      title: '清掉最舊的 $over 份？',
      message:
          '現在有 ${_drafts.length} 份影片草稿，保留最新的 $_cap 份，'
          '其餘連同它們自己的工作檔一起刪掉，無法復原',
      action: '清掉 $over 份',
    );
    if (!ok || !mounted) return;
    final removed = await DraftStore.prune();
    if (!mounted) return;
    showHint(context, '清掉了 ${removed.length} 份草稿');
    _reload();
  }

  Future<void> _deletePicked() async {
    if (_picked.isEmpty) return;
    final ok = await showConfirm(
      context,
      title: '刪除 ${_picked.length} 份草稿？',
      message: '未完成的專案會被移除，無法復原',
      action: '刪除',
    );
    if (!ok || !mounted) return;
    for (final id in _picked) {
      await DraftStore.remove(id);
    }
    setState(() {
      _picked.clear();
      _selecting = false;
    });
    _reload();
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final found = await DraftStore.list();
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic>? photo;
    final ps = prefs.getString(kPhotoDraftKey);
    if (ps != null) {
      try {
        final j = jsonDecode(ps) as Map<String, dynamic>;
        if ((j['photo'] as String?)?.isNotEmpty ?? false) photo = j;
      } catch (_) {}
    }
    Map<String, dynamic>? batch;
    final bs = prefs.getString(kBatchDraftKey);
    if (bs != null) {
      try {
        final j = jsonDecode(bs) as Map<String, dynamic>;
        if ((j['files'] as List?)?.isNotEmpty ?? false) batch = j;
      } catch (_) {}
    }
    Map<String, dynamic>? gif;
    final gs = prefs.getString(kGifDraftKey);
    if (gs != null) {
      try {
        final j = jsonDecode(gs) as Map<String, dynamic>;
        if ((j['path'] as String?)?.isNotEmpty ?? false) gif = j;
      } catch (_) {}
    }
    Map<String, dynamic>? collage;
    final cs = prefs.getString(kCollageDraftKey);
    if (cs != null) {
      try {
        final j = jsonDecode(cs) as Map<String, dynamic>;
        if ((j['photos'] as List?)?.isNotEmpty ?? false) collage = j;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _drafts = found;
        _photoDraft = photo;
        _batchDraft = batch;
        _gifDraft = gif;
        _collageDraft = collage;
        _loading = false;
      });
      unawaited(_loadCovers(found));
    }
  }

  /// 續作 GIF：影片還在就帶回 GIF 製作頁
  Future<void> _resumeGif() async {
    final d = _gifDraft;
    if (d == null) return;
    final path = d['path'] as String? ?? '';
    if (!await fileExists(path)) {
      if (mounted) showHint(context, '這支影片已經不在了，草稿無法續作', error: true);
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => GifScreen(
          path: path,
          name: d['name'] as String? ?? 'video',
          restore: d,
        ),
      ),
    );
    _reload();
  }

  Future<void> _deleteGif() async {
    final ok = await showConfirm(
      context,
      title: '刪除 GIF 草稿？',
      message: '剪選範圍與設定會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kGifDraftKey);
      _reload();
    }
  }

  /// 續作拼圖：照片還在的帶回去（拼圖頁自己會略過不見的）
  Future<void> _resumeCollage() async {
    final d = _collageDraft;
    if (d == null) return;
    await Navigator.push(
      context,
      editRoute(builder: (_) => CollageScreen(restore: d)),
    );
    _reload();
  }

  Future<void> _deleteCollage() async {
    final ok = await showConfirm(
      context,
      title: '刪除拼圖草稿？',
      message: '排法與設定會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kCollageDraftKey);
      _reload();
    }
  }

  /// 續作批次浮水印：檔案還在的帶回去，不見的略過並講清楚
  Future<void> _resumeBatch() async {
    final d = _batchDraft;
    if (d == null) return;
    final paths = (d['files'] as List? ?? []).cast<String>();
    final alive = <XFile>[];
    var gone = 0;
    for (final path in paths) {
      if (await fileExists(path)) {
        alive.add(XFile(path));
      } else {
        gone++;
      }
    }
    if (alive.isEmpty) {
      if (mounted) {
        showHint(context, '這批檔案都已經不在了，草稿無法續作', error: true);
      }
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => BatchWatermarkScreen(
          files: alive,
          restore: d,
          initialHint: gone > 0 ? '有 $gone 個檔案已不在，已略過' : null,
        ),
      ),
    );
    _reload();
  }

  Future<void> _deleteBatch() async {
    final ok = await showConfirm(
      context,
      title: '刪除批次草稿？',
      message: '這批的浮水印設定會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBatchDraftKey);
      _reload();
    }
  }

  Future<void> _resumePhoto() async {
    final d = _photoDraft;
    if (d == null) return;
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => PhotoEditorScreen(
          photo: XFile(d['photo'] as String),
          draft: d['state'] as String?,
        ),
      ),
    );
    _reload();
  }

  Future<void> _deletePhoto() async {
    final ok = await showConfirm(
      context,
      title: '刪除草稿？',
      message: '這張沒輸出的照片會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kPhotoDraftKey);
      _reload();
    }
  }

  /// 草稿卡（影片與照片共用同一種長相）。
  /// 封面固定 52 方框：文字起點才會對齊，兩張卡看起來才整齊
  Widget _draftCard({
    required Widget cover,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required VoidCallback onDelete,

    /// 選取模式的勾選狀態；null＝不在選取模式（照常顯示刪除鈕）
    bool? picked,

    /// 縮圖的寬高比。null＝沒有縮圖（放圖示佔位，維持方框）
    double? coverAspect,
  }) {
    return Container(
      decoration: lightCard(radius: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // 縮圖照它自己的比例：高度固定 52，寬度跟著比例走。
              //
              // 本來是固定 52×52 的方框，而 alignment 會把緊的約束
              // 放鬆——圖片於是照原比例縮進方框裡，兩側露出一塊灰邊。
              // 直片橫片的寬度不一樣是正常的，那才是它本來的樣子
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 52,
                  width: 52 * (coverAspect ?? 1.0).clamp(0.4, 2.5),
                  child: coverAspect == null
                      ? ColoredBox(
                          color: kLTile,
                          child: Center(child: cover),
                        )
                      : cover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: kLTextDim),
                      ),
                    ],
                  ],
                ),
              ),
              // 選取模式：刪除鈕換成勾選圈；點卡片本身就是勾/取消
              if (picked != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(
                    picked ? Icons.check_circle : Icons.circle_outlined,
                    size: 20,
                    color: picked ? kLAccent : kLTextDim,
                  ),
                )
              else
                IconButton(
                  tooltip: '刪除草稿',
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 19,
                    color: kLTextDim,
                  ),
                  onPressed: onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 草稿封面：內容另外存（見 DraftStore.thumb），讀進來後放這個
  /// 快取；build 裡只查表，不解碼也不丟例外
  final Map<String, Uint8List> _covers = {};

  Future<void> _loadCovers(List<DraftMeta> metas) async {
    for (final m in metas) {
      if (!m.hasThumb || _covers.containsKey(m.id)) continue;
      final t = await DraftStore.thumb(m.id);
      if (t == null) continue;
      try {
        _covers[m.id] = base64Decode(t);
      } catch (_) {
        // 壞掉的那筆就沒有封面，不能讓整頁紅屏
      }
    }
    if (mounted) setState(() {});
  }

  String _savedAtLabel(Map<String, dynamic> j) {
    final raw = j['savedAt'];
    if (raw is! String) return '';
    final t = DateTime.tryParse(raw);
    if (t == null) return '';
    return '${t.month}/${t.day} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _resume(DraftMeta m) async {
    final data = await DraftStore.load(m.id);
    if (data == null || !mounted) {
      if (mounted) showHint(context, '這份草稿讀不到了', error: true);
      return;
    }
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => VideoEditorScreen(draft: data, draftId: m.id),
      ),
    );
    _reload();
  }

  Future<void> _delete(DraftMeta m) async {
    final ok = await showConfirm(
      context,
      title: '刪除這份草稿？',
      message: '未完成的專案會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      await DraftStore.remove(m.id);
      _reload();
    }
  }

  // ── 瀑布流（C 案）：封面照專案畫布原比例排，日期小 chip 浮在
  // 左上角、時長在右下角，卡片本身零文字列——最像相簿、畫面最純。
  // 片段數不顯示（要看的話點進去就知道）；刪除走長按或選取模式

  /// 這份草稿在瀑布流裡的高寬比（沒封面的用 1:1 的圖示磚佔位）
  double _tileAspect(DraftMeta m) =>
      _covers[m.id] != null ? (m.thumbAspect ?? 9 / 16) : 1.0;

  /// 兩欄瀑布流：每一份丟進目前比較短的那一欄（跟「我的 GIF」同一套）
  List<List<DraftMeta>> _draftColumns(double colW) {
    final cols = <List<DraftMeta>>[[], []];
    final h = [0.0, 0.0];
    for (final m in _drafts) {
      final i = h[0] <= h[1] ? 0 : 1;
      cols[i].add(m);
      h[i] += colW / _tileAspect(m) + 10;
    }
    return cols;
  }

  Widget _draftTile(DraftMeta m) {
    final cover = _covers[m.id];
    final picked = _picked.contains(m.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: _selecting
            ? () => setState(() {
                picked ? _picked.remove(m.id) : _picked.add(m.id);
              })
            : () => _resume(m),
        onLongPress: _selecting ? null : () => _delete(m),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: _tileAspect(m),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (cover != null)
                  Image.memory(cover, fit: BoxFit.cover, gaplessPlayback: true)
                else
                  const ColoredBox(
                    color: kLTile,
                    child: Icon(
                      Icons.movie_outlined,
                      size: 26,
                      color: kLAccent,
                    ),
                  ),
                // 不放日期/時長角標（使用者指定）：封面本身就是內容
                // 選取模式：整張壓暗＋右上角勾勾
                if (_selecting) ...[
                  ColoredBox(
                    color: Colors.black.withValues(alpha: picked ? 0.35 : 0.12),
                  ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: picked
                            ? const Color(0xFFE53935)
                            : Colors.black38,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: picked
                          ? const Icon(
                              Icons.check,
                              size: 13,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = _drafts;
    final p = _photoDraft;
    final empty =
        ds.isEmpty &&
        p == null &&
        _batchDraft == null &&
        _gifDraft == null &&
        _collageDraft == null;
    return SwipeBack(
      child: Scaffold(
        appBar: AppBar(
          actions: [
            if (_selecting) ...[
              // 刪除鈕移到底部 sticky 列（勾了才浮上來），上面只留取消
              TextButton(
                onPressed: () => setState(() {
                  _selecting = false;
                  _picked.clear();
                }),
                child: const Text('取消'),
              ),
            ] else ...[
              // 保留份數不再給調（使用者指定：那顆鈕刪掉，一律 30 份）。
              // 掃把是唯一會刪掉草稿的入口
              if (ds.isNotEmpty)
                IconButton(
                  tooltip: '清理舊草稿',
                  icon: const Icon(Icons.cleaning_services_outlined, size: 20),
                  onPressed: _cleanupOld,
                ),
              if (ds.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _selecting = true),
                  child: const Text('選取'),
                ),
            ],
          ],
        ),
        // 刪除列疊在 body 的 Stack 裡，不用 Scaffold.bottomSheet：
        // bottomSheet 會把內容包一層主題的白底圓角 Material，
        // 滑出動畫只滑走內容物、外皮留在原地——就是使用者回報的
        // 「底下白條」
        body: Stack(
          children: [
            _loading
                ? const Center(child: CircularProgressIndicator())
                : empty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        '沒有草稿。\n\n影片專案會自動存成草稿放在這裡；\n'
                        '照片、批次、GIF 與拼圖要在離開時選「保留草稿」。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kLTextDim, height: 1.6),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // 影片草稿走瀑布流（C 案）：封面原比例、日期 chip
                      // 在左上、時長在右下。照片/批次草稿維持一列一卡
                      if (ds.isNotEmpty)
                        LayoutBuilder(
                          builder: (context, cons) {
                            final colW = (cons.maxWidth - 10) / 2;
                            final cols = _draftColumns(colW);
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      for (final m in cols[0]) _draftTile(m),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    children: [
                                      for (final m in cols[1]) _draftTile(m),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      if (p != null)
                        _draftCard(
                          // 照片草稿沒有存縮圖（那張照片還在裝置上，
                          // 再存一份只是浪費空間），用圖示就好
                          cover: const Icon(
                            Icons.image_outlined,
                            size: 20,
                            color: kLAccent,
                          ),
                          title: '未完成的照片',
                          subtitle: _savedAtLabel(p),
                          onTap: _resumePhoto,
                          onDelete: _deletePhoto,
                        ),
                      if (_batchDraft != null) ...[
                        const SizedBox(height: 12),
                        _draftCard(
                          cover: const Icon(
                            Icons.collections_outlined,
                            size: 20,
                            color: kLAccent,
                          ),
                          title: '未完成的批次浮水印',
                          subtitle: _savedAtLabel(_batchDraft!),
                          onTap: _resumeBatch,
                          onDelete: _deleteBatch,
                        ),
                      ],
                      if (_gifDraft != null) ...[
                        const SizedBox(height: 12),
                        _draftCard(
                          cover: const Icon(
                            Icons.gif_box_outlined,
                            size: 20,
                            color: kLAccent,
                          ),
                          title: '未完成的 GIF',
                          subtitle: _savedAtLabel(_gifDraft!),
                          onTap: _resumeGif,
                          onDelete: _deleteGif,
                        ),
                      ],
                      if (_collageDraft != null) ...[
                        const SizedBox(height: 12),
                        _draftCard(
                          cover: const Icon(
                            Icons.grid_view,
                            size: 20,
                            color: kLAccent,
                          ),
                          title: '未完成的拼圖',
                          subtitle: _savedAtLabel(_collageDraft!),
                          onTap: _resumeCollage,
                          onDelete: _deleteCollage,
                        ),
                      ],
                      // 說明放在清單尾巴：草稿不會自己消失，要清得自己按
                      if (ds.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                          child: Text(
                            '影片專案會自動存成草稿，不會自己刪掉；'
                            '保留 $_cap 份，超過時按右上角的掃把清掉最舊的',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              color: kLTextDim,
                              height: 1.5,
                            ),
                          ),
                        ),
                      // 底部刪除列滑上來時，最後一張卡不被蓋住
                      if (_selecting) const SizedBox(height: 88),
                    ],
                  ),
            // 選取模式勾了至少一張，刪除列才從最下方浮上來
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedSlide(
                offset: _selecting && _picked.isNotEmpty
                    ? Offset.zero
                    : const Offset(0, 1.2),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: IgnorePointer(
                  ignoring: !(_selecting && _picked.isNotEmpty),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(top: BorderSide(color: Color(0xFFECECEF))),
                    ),
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFE53935),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: const StadiumBorder(),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onPressed: _deletePicked,
                          child: Text('刪除 ${_picked.length} 份草稿'),
                        ),
                      ),
                    ),
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

/// 我的 GIF：做好的 GIF 都留一份在這裡。
///
/// 相簿那份跟幾千張照片混在一起，要拿它當素材根本找不到；
/// 這裡只有 GIF，點一下放大看，長按刪除
class GifsScreen extends StatefulWidget {
  const GifsScreen({super.key});

  @override
  State<GifsScreen> createState() => _GifsScreenState();
}

class _GifsScreenState extends State<GifsScreen> {
  List<String> _gifs = const [];

  /// 每個 GIF 的寬高比（路徑 → 寬/高）。瀑布流照原始比例排，
  /// 一律切成正方形的話直式的會被裁掉頭尾
  final Map<String, double> _aspect = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final gifs = await GifStore.list();
    if (!mounted) return;
    setState(() {
      _gifs = gifs;
      _loading = false;
    });
    // 比例邊讀邊補：只解第一格拿尺寸，不用等全部讀完才畫得出東西
    for (final ref in gifs) {
      if (_aspect.containsKey(ref)) continue;
      double a;
      try {
        final bytes = await GifStore.bytes(ref);
        final codec = await ui.instantiateImageCodec(bytes!);
        final frame = await codec.getNextFrame();
        a = frame.image.width / frame.image.height;
        frame.image.dispose();
        if (a <= 0) a = 1.0;
      } catch (_) {
        a = 1.0; // 讀不到就當正方形，至少排得出來
      }
      if (!mounted) return;
      setState(() => _aspect[ref] = a);
    }
  }

  /// 兩欄瀑布流：每一個丟進目前比較短的那一欄。
  /// 高度用寬高比推算（欄寬 ÷ 比例），不用等圖片真的畫出來
  List<List<String>> _columns(double colW) {
    final cols = <List<String>>[[], []];
    final h = [0.0, 0.0];
    for (final ref in _gifs) {
      final i = h[0] <= h[1] ? 0 : 1;
      cols[i].add(ref);
      h[i] += colW / (_aspect[ref] ?? 1.0) + 10;
    }
    return cols;
  }

  /// 一格：照原始比例畫。GIF 自己會動——Image.file 讀到多格就會播
  Widget _gifTile(String ref) => GestureDetector(
    onTap: () => _preview(ref),
    onLongPress: () => _delete(ref),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: _aspect[ref] ?? 1.0,
        child: ColoredBox(color: kLTile, child: GifImage(ref)),
      ),
    ),
  );

  /// 回傳有沒有真的刪掉（確認視窗按取消就是 false）
  Future<bool> _delete(String ref) async {
    final ok = await showConfirm(
      context,
      title: '刪除這個 GIF？',
      message: '只會刪掉 App 裡這一份，相簿裡的不受影響',
      action: '刪除',
    );
    if (!ok) return false;
    await GifStore.remove(ref);
    _reload();
    return true;
  }

  /// 點一下放大看：GIF 在小格子裡看不出動了什麼。
  /// 放大之後左右滑換上一張／下一張、往下滑關掉、長按刪掉眼前這張
  void _preview(String ref) {
    final start = _gifs.indexOf(ref);
    if (start < 0) return;
    showDialog<void>(
      context: context,
      // 遮罩改成自己畫（見 _GifLightbox）：要跟著下滑的手指變淡，
      // route 的 barrierColor 是固定值做不到。開關的淡入淡出照舊
      // 走 showDialog 那條（150ms），手感不變
      barrierColor: Colors.transparent,
      // 遮罩要蓋到狀態列與底部（留白就露出後面的瀑布流）
      useSafeArea: false,
      builder: (context) =>
          _GifLightbox(gifs: _gifs, start: start, onDelete: _delete),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
        appBar: AppBar(),
        // 右下浮動黑圓 +（跟範本夾同款）：把相簿裡自己的 GIF 收進來
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            final saved = await importGifFromGallery(context);
            if (saved != null) _reload();
          },
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          child: const Icon(Icons.add, size: 28),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _gifs.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '還沒有 GIF。\n\n'
                    '首頁「加入浮水印 → 製作 GIF」做一個，'
                    '或按右下角的＋把相簿裡的 GIF 收進來。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kLTextDim, height: 1.6),
                  ),
                ),
              )
            : LayoutBuilder(
                builder: (context, box) {
                  // 兩欄瀑布流：左右各 16、中間 10
                  final colW = (box.maxWidth - 16 * 2 - 10) / 2;
                  final cols = _columns(colW);
                  return SingleChildScrollView(
                    // 底部多留：最後一張不被浮動 + 蓋住
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var c = 0; c < cols.length; c++) ...[
                          if (c > 0) const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              children: [
                                for (final f in cols[c]) ...[
                                  _gifTile(f),
                                  const SizedBox(height: 10),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// GIF 燈箱（放大看那一張）。
///
/// 左右滑＝上一張／下一張，滑到頭會回彈而不繞回去——繞回去就分不清
/// 自己在哪裡了；往下滑＝畫面跟著手指走、遮罩同步變淡，過門檻放手
/// 就關掉，沒過就彈回原位；長按＝刪掉「眼前這一張」（翻過頁之後刪的
/// 不是點進來的那張）。點一下關掉的老行為留著
class _GifLightbox extends StatefulWidget {
  final List<String> gifs;
  final int start;

  /// 回傳有沒有真的刪掉（使用者可能在確認視窗按取消）
  final Future<bool> Function(String ref) onDelete;

  const _GifLightbox({
    required this.gifs,
    required this.start,
    required this.onDelete,
  });

  @override
  State<_GifLightbox> createState() => _GifLightboxState();
}

class _GifLightboxState extends State<_GifLightbox> {
  /// 遮罩濃度。原本用佈景的 0.35，後面的瀑布流看得一清二楚，
  /// GIF 反而浮不起來（使用者回報「再壓暗一點點」）。
  /// 0.85 跟深色佈景的對話框遮罩同一個值
  static const _scrim = 0.85;

  /// 下滑超過這麼多（或甩得夠快）就關掉
  static const _closeAt = 120.0;

  /// 遮罩／內容淡到底的行程
  static const _fadeOver = 320.0;

  late final PageController _pc = PageController(initialPage: widget.start);
  late int _i = widget.start;

  /// 目前的下滑位移（只吃往下，往上滑不該讓 GIF 飛出畫面）
  double _dy = 0;
  bool _dragging = false;

  /// 已經按下關閉了。關閉動畫還在跑的時候元件仍然活著，沒有這道閘
  /// 再滑一次就會多 pop 一層，把整個「我的 GIF」也收掉
  bool _closing = false;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.pop(context);
  }

  void _dragUpdate(DragUpdateDetails d) {
    final next = (_dy + d.delta.dy).clamp(0.0, 4000.0);
    if (next == _dy) return;
    setState(() => _dy = next);
  }

  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    if (_dy > _closeAt || d.velocity.pixelsPerSecond.dy > 700) {
      _close();
      return;
    }
    setState(() => _dy = 0); // 沒過門檻：彈回原位
  }

  /// 手勢被判給別人（橫滑翻頁贏了競技場）或被系統取消：回原位
  void _dragCancel() {
    _dragging = false;
    if (_dy != 0) setState(() => _dy = 0);
  }

  @override
  Widget build(BuildContext context) {
    final pager = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _close,
      onLongPress: () async {
        final gone = await widget.onDelete(widget.gifs[_i]);
        if (gone && mounted) _close();
      },
      // 直向拖曳自己收：PageView 只吃橫向，兩邊在手勢競技場不打架
      onVerticalDragStart: (_) => _dragging = true,
      onVerticalDragUpdate: _dragUpdate,
      onVerticalDragEnd: _dragEnd,
      onVerticalDragCancel: _dragCancel,
      child: PageView.builder(
        controller: _pc,
        // 到頭了輕輕回彈（iOS 那種橡皮筋），不繞回第一張
        physics: const BouncingScrollPhysics(),
        itemCount: widget.gifs.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ClipRRect(
              // 圓角切在 GIF 本人上（不是外面包一層框），
              // 就沒有對不齊的白邊
              borderRadius: BorderRadius.circular(16),
              child: GifImage(widget.gifs[i], fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(end: _dy),
      // 拖著的時候不補間（畫面就黏在手指上），放手才用 180ms 收尾
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, dy, child) {
        final t = (dy / _fadeOver).clamp(0.0, 1.0);
        return Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: _scrim * (1 - 0.7 * t)),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, dy),
                // 透明度 1 的時候 RenderOpacity 直接跳過圖層，
                // 不拖著的時候沒有額外成本
                child: Opacity(opacity: 1 - 0.5 * t, child: child),
              ),
            ),
          ],
        );
      },
      child: pager,
    );
  }
}

/// 「M/D HH:mm」：草稿卡與個人頁共用（以前三處各寫一份）
String dateLabel(DateTime t) =>
    '${t.month}/${t.day} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';
