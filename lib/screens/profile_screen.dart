import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;

import '../models/watermark_settings.dart';
import '../services/blob_store.dart';
import '../services/app_media_paths.dart';
import '../services/draft_assets.dart';
import '../services/draft_store.dart';
import '../services/file_reader.dart';
import '../services/storage_usage.dart';
import '../services/gif_store.dart';
import '../services/photo_export.dart' show PhotoEncoded, encodePhotoImage;
import '../services/preset_store.dart';
import '../services/video_picker.dart'
    show isVideoFile, pickGalleryGifs, pickVideoFiles;
import '../nav.dart';
import '../theme.dart';
import '../widgets/gif_image.dart';
import '../widgets/swipe_back.dart';
import '../widgets/library_selection.dart';
import '../widgets/library_tile_menu.dart';
import 'about_screen.dart';
import 'donate_screen.dart';
import 'feedback_screen.dart';
import 'storage_screen.dart';
import 'batch_watermark_screen.dart';
import 'collage_screen.dart';
import 'gif_screen.dart';
import 'photo_editor_screen.dart';
import 'presets_screen.dart';
import 'watermark_studio_screen.dart';
import 'video_editor_screen.dart';

// ── 刪除：長按選單問過了才呼叫這幾支 ──
//
// 以前每一處長按都跳整頁的確認視窗；現在改成磚旁邊的小選單（見
// showLibraryTileMenu，使用者指定「直接在旁邊出現小選單，問是否要刪除」），
// 選單本身就是「要不要刪」，這裡只做事。個人中心跟查看全部頁刪的是
// 同一樣東西，動作只寫一份

/// 影片草稿（一份一份存的那種）
Future<void> _removeVideoDraft(DraftMeta m) => DraftStore.remove(m.id);

/// 單鍵草稿。照片／批次／拼圖連留下的素材複本一起收（見 DraftAssets）：
/// 只刪那一筆的話，Application Support 裡最多 300MB 的複本會留到天荒地老
Future<void> _removeSingleDraft(DraftKind kind) async {
  switch (kind) {
    case DraftKind.photo:
      await PhotoEditorScreen.clearPhotoDraft(deleteAssets: true);
    case DraftKind.batch:
      await BlobStore.delete(kBatchDraftKey);
      await DraftAssets.retain(DraftAssets.batch, const {});
    case DraftKind.gif:
      await BlobStore.delete(kGifDraftKey);
    case DraftKind.collage:
      await BlobStore.delete(kCollageDraftKey);
      await DraftAssets.retain(DraftAssets.collage, const {});
  }
}

/// 「我的 GIF」裡的一個 GIF（App 裡那一份；相簿的不動）。
/// 燈箱裡長按還是走確認視窗：那裡沒有一格可以浮起來、旁邊擺選單
Future<bool> _confirmDeleteGifFile(BuildContext context, String ref) async {
  final ok = await showConfirm(
    context,
    title: '刪除這個 GIF？',
    message: '只會刪掉 App 裡這一份，相簿裡的不受影響',
    action: '刪除',
  );
  if (!ok) return false;
  await GifStore.remove(ref);
  return true;
}

/// 個人中心：草稿、GIF、範本三個分頁（C 案，使用者定案），
/// 右上角「容量與清理」
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

/// 頁面左右的留白（分頁標題、格子都貼著這條線）
const _side = EdgeInsets.symmetric(horizontal: 22);

/// 三個分頁。順序是草稿→GIF→範本：最常回來找的東西放最前面
const _kTabs = ['草稿', 'GIF', '範本'];

/// 分頁標題：選中的大一號（使用者在 22～30 五檔裡選了 30），其他 20
const _kTabOn = 30.0;
const _kTabOff = 20.0;

/// 沒選中的分頁字色：比 kLTextDim 淡一階，選中的才是主角
const _kTabIdle = Color(0xFF8C8C95);

/// 草稿分頁先擺四格（兩排兩欄），比格子多的時候第四格換成「+N 查看
/// 全部」。GIF 與範本分頁是整片瀑布流，全部列出來（使用者指定）
const _kDraftSlots = 4;

/// 空狀態那一行灰字（kLTextDim：更淡的灰在白底上對比不到 3:1）
const _kHintStyle = TextStyle(fontSize: 13, color: kLTextDim);

/// 頁尾連結
const _kFootStyle = TextStyle(fontSize: 12.5, color: kLTextDim);

/// 頁尾兩個連結中間那一點
const _kDotStyle = TextStyle(fontSize: 12, color: Color(0xFFB0B0BA));

/// 一份草稿：影片草稿（一份一份存，見 DraftStore）或單鍵草稿
/// （照片／批次／GIF／拼圖各只有一份）。個人中心與查看全部頁共用
class _DraftEntry {
  final DraftMeta? video;
  final DraftKind? kind;

  const _DraftEntry.video(DraftMeta this.video) : kind = null;
  const _DraftEntry.single(DraftKind this.kind) : video = null;
}

/// 沒有封面的那四種草稿：灰底＋圖示＋名字（不然認不出是什麼）。
/// 照片草稿沒有存縮圖——那張照片還在裝置上，再存一份只是浪費空間
Widget _singleDraftCover(DraftKind kind) => ColoredBox(
  color: kLTile,
  child: Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(switch (kind) {
            DraftKind.photo => Icons.image_outlined,
            DraftKind.batch => Icons.collections_outlined,
            DraftKind.gif => Icons.gif_box_outlined,
            DraftKind.collage => Icons.grid_view,
          }, size: 26, color: const Color(0xFFAFAFBB)),
          const SizedBox(height: 8),
          Text(
            _singleDraftTitle(kind),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 1.4, color: kLTextDim),
          ),
        ],
      ),
    ),
  ),
);

String _singleDraftTitle(DraftKind kind) => switch (kind) {
  DraftKind.photo => '未完成的照片',
  DraftKind.batch => '未完成的批次浮水印',
  DraftKind.gif => '未完成的 GIF',
  DraftKind.collage => '未完成的拼圖',
};

/// 單鍵草稿的四種：照片／批次／GIF／拼圖各只有一份，各存一個鍵
/// （影片草稿另有自己的清單，見 DraftStore）
enum DraftKind { photo, batch, gif, collage }

/// 讀一份單鍵草稿：解得開、而且 [contentKey] 那一欄（照片路徑、檔案
/// 清單…）有東西才算有草稿。個人中心與草稿夾以前各寫一份、草稿夾還是
/// 四段複製貼上——「有沒有」的規則一走岔就是一邊列得出、一邊列不出。
/// 內容存成檔案（見 BlobStore；帶著 Logo 的 base64，不放設定檔）
Future<Map<String, dynamic>?> _readDraftJson(
  String key,
  String contentKey,
) async {
  final s = await BlobStore.read(key);
  if (s == null) return null;
  try {
    var j = jsonDecode(s) as Map<String, dynamic>;
    final kind = switch (contentKey) {
      'photo' => DraftAssets.photo,
      'files' => DraftAssets.batch,
      'photos' => DraftAssets.collage,
      _ => null,
    };
    if (kind == null) {
      j = AppMediaPaths.mapDraft(j);
    } else {
      final value = j[contentKey];
      final paths = value is List
          ? value.whereType<String>()
          : [if (value is String) value];
      final resolved = <String, String>{};
      for (final path in paths) {
        resolved[path] = await DraftAssets.resolve(kind, path) ?? path;
      }
      j = AppMediaPaths.mapDraft(
        j,
        transform: (path) => resolved[path] ?? path,
      );
    }
    final v = j[contentKey];
    final has = v is List ? v.isNotEmpty : (v is String && v.isNotEmpty);
    return has ? j : null;
  } catch (_) {
    return null;
  }
}

/// 「我的 GIF」右下角 ＋ 的三件事（見 [addGifFromDevice]）：
/// 現做一個，或從兩個看不到彼此的地方收一個現成的進來
enum _GifSource { make, gallery, files }

/// 收一個 GIF 進「我的 GIF」（跟編輯器挑 GIF 的驗證同一套）。
///
/// [fromFiles] 決定開哪一個選取器——這兩個是不同的地方，不是同一個
/// 選取器的兩種寫法：
/// - false（預設）＝相簿，而且只列 GIF（見 pickGalleryGifs）。iOS 是
///   PHPicker 篩 imageAnimated、Android 是系統相片選取器篩 image/gif；
///   舊機沒有那個選取器才退回 file_picker 的「所有照片」
/// - true＝檔案。iOS 是 UIDocumentPickerViewController（檔案 App、
///   iCloud 雲碟、下載項目…），Android 是 ACTION_OPEN_DOCUMENT
///
/// 檔案那條路順便把清單過濾成只剩 GIF：'gif' 在原生端會轉成過濾
/// 條件（iOS 是 com.compuserve.gif 這個 UTI，Android 是 image/gif
/// 這個 mime）。但那是「盡量」——轉不出來時兩邊都是退回不過濾，
/// 而相簿那條路本來就什麼都選得到，所以副檔名一律自己再驗一次：
/// 選到一般照片時要講清楚，不能默默當成 GIF 收進來只有一格
///
/// 成功回存好的參照；取消或失敗回 null（失敗會自己提示）
Future<String?> importGif(
  BuildContext context, {
  bool fromFiles = false,
}) async {
  String? path;
  if (!fromFiles) {
    // 相簿：先問系統相片選取器（篩得出「會動的圖」）。回 null 才是
    // 「這台沒有」，空清單是使用者按了取消——那就不要再開第二個給他
    final picked = await pickGalleryGifs();
    if (picked != null) {
      if (picked.isEmpty) return null;
      path = picked.first;
    }
  }
  if (path == null) {
    final r = await FilePicker.platform.pickFiles(
      type: fromFiles ? FileType.custom : FileType.image,
      // 只有 FileType.custom 收得了副檔名清單，別的型別給了會丟
      // ArgumentError
      allowedExtensions: fromFiles ? const ['gif'] : null,
    );
    path = (r == null || r.files.isEmpty) ? null : r.files.first.path;
  }
  if (path == null) return null;
  // 副檔名對還要看檔頭：改過名的 PNG、下載到一半的殘檔以前照收，
  // 收進來只有一格、或根本畫不出來
  if (!path.toLowerCase().endsWith('.gif') ||
      !await GifStore.looksLikeGif(path)) {
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
  if (saved != null && !fromFiles && context.mounted) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('已匯入 GIF', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 12),
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.35,
                  width: double.infinity,
                  child: GifImage(saved, fit: BoxFit.contain),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return saved;
}

/// 弄一個 GIF 進「我的 GIF」：先問要現做還是收現成的，再各自往下走。
///
/// 「製作 GIF」跟首頁的「加入浮水印 → 製作 GIF」是同一條路（見
/// home_screen 的 _PickKind.gif）：挑影片、進 GIF 製作頁。一次只做一支，
/// 多選了就拿第一支，這裡不值得再多問一輪。做好的 GIF 是由匯出那一端
/// 自己收進 GifStore 的（見 video_engine_io），製作頁不會把參照交回來，
/// 所以從那裡回來一律當成「清單可能變了」。
///
/// 匯入那兩條要先問，是因為相簿跟檔案是兩個看不到彼此的地方：iOS 的
/// 相簿選取器（PHPicker）沒有檔案 App 那一區，檔案選取器
/// （UIDocumentPickerViewController）也列不出相簿，沒有一種設定同時
/// 涵蓋兩邊。存在 iCloud 雲碟或下載項目裡的 GIF 以前就是這樣拿不到的
///
/// Web 沒有相簿這個地方——瀏覽器只有一個檔案視窗，FileType 到了那邊
/// 只是換 `<input accept>`（見 file_picker 的 _internal/file_picker_web），
/// 兩條匯入路會是同一件事。所以 web 只列「製作 GIF」跟「從檔案匯入 GIF」，
/// 留下的是 accept 講得出 `.gif` 的那一條
///
/// 回傳「清單要不要重讀」
Future<bool> addGifFromDevice(BuildContext context) async {
  final source = await showModalBottomSheet<_GifSource>(
    context: context,
    showDragHandle: true,
    // 面板自己管高度：預設的 9/16 上限在橫向（375 高）只剩 211，三列
    // （48 抓把＋3×56＋6＝222）裝不下，最後一列被切在畫面外按不到。
    // 內容多高面板就多高，裝不下的那一截捲（跟首頁的面板同一套）
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.gif_box_outlined,
                size: 20,
                color: kLIcon,
              ),
              title: const Text('製作 GIF', style: TextStyle(fontSize: 13.5)),
              onTap: () => Navigator.pop(context, _GifSource.make),
            ),
            if (!kIsWeb)
              ListTile(
                leading: const Icon(
                  Icons.photo_library_outlined,
                  size: 20,
                  color: kLIcon,
                ),
                title: const Text(
                  '從相簿匯入 GIF',
                  style: TextStyle(fontSize: 13.5),
                ),
                onTap: () => Navigator.pop(context, _GifSource.gallery),
              ),
            ListTile(
              leading: const Icon(
                Icons.folder_open_outlined,
                size: 20,
                color: kLIcon,
              ),
              title: const Text('從檔案匯入 GIF', style: TextStyle(fontSize: 13.5)),
              onTap: () => Navigator.pop(context, _GifSource.files),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return false;
  if (source == _GifSource.make) {
    // 相簿只列影片（跟首頁同一支選取器）；選單上寫「製作 GIF」，
    // 就不該讓照片跟著出現
    final list = await pickVideoFiles();
    final v = list.where(isVideoFile).toList();
    if (v.isEmpty || !context.mounted) return false;
    await Navigator.push(
      context,
      editRoute(
        builder: (_) => GifScreen(path: v.first.path, name: v.first.name),
      ),
    );
    // 製作頁不回報做了什麼（見上面），回來就重讀
    return true;
  }
  return await importGif(context, fromFiles: source == _GifSource.files) !=
      null;
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<WatermarkPreset> _presets = const [];

  /// 影片草稿清單（可以有很多份，見 DraftStore）。這一頁直接把草稿畫
  /// 出來，不只顯示「有幾個」——使用者要找的是「那一個專案」
  List<DraftMeta> _videoDrafts = const [];

  /// 做好的 GIF（見 GifStore；Web 是內建範例）
  List<String> _gifs = const [];

  /// 單鍵草稿：照片／批次浮水印／GIF 製作／拼圖（沒有就是 null，
  /// 見 kPhotoDraftKey／kBatchDraftKey／kGifDraftKey／kCollageDraftKey）
  Map<String, dynamic>? _photoDraft;
  Map<String, dynamic>? _batchDraft;
  Map<String, dynamic>? _gifDraft;
  Map<String, dynamic>? _collageDraft;

  /// 現在看的是哪一個分頁：0 草稿、1 GIF、2 範本
  int _tab = 0;

  // ── 批次刪除（GIF 與範本分頁）：右上角「批次刪除」，這一頁就是那個
  // 資料夾（使用者指定：點了 GIF 分頁，右上角就變成批次刪除）

  bool _selecting = false;
  bool _deleting = false;

  /// 勾了哪些：GIF 分頁放路徑、範本分頁放名字
  final Set<String> _picked = {};

  /// 每個 GIF／範本存起來多大（批次刪除時標在格子上、加總寫在紅鈕上；
  /// 範本的 Logo 圖也存在裡面，大的就是那幾張）
  Map<String, int> _gifSizes = const {};
  Map<String, int> _presetSizes = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final presets = await PresetStore.load();
    final videoDrafts = await DraftStore.list();
    final gifs = await GifStore.list();
    final photo = await _readDraftJson(kPhotoDraftKey, 'photo');
    final batch = await _readDraftJson(kBatchDraftKey, 'files');
    final gif = await _readDraftJson(kGifDraftKey, 'path');
    final collage = await _readDraftJson(kCollageDraftKey, 'photos');

    if (!mounted) return;
    setState(() {
      _presets = presets;
      _videoDrafts = videoDrafts;
      _gifs = gifs;
      _gifSizes = {for (final g in gifs) g: GifStore.sizeOf(g)};
      _presetSizes = {
        for (final p in presets) p.name: utf8.encode(p.encode()).length,
      };
      _picked.retainAll(_tab == 1 ? gifs : presets.map((p) => p.name));
      _photoDraft = photo;
      _batchDraft = batch;
      _gifDraft = gif;
      _collageDraft = collage;
    });
    // 草稿分頁最多畫四格（見 _draftsTab）：封面也只讀那四張。
    // 一張封面是上百 KB 的圖，以前三十份全讀進來只為了畫兩張
    unawaited(_loadCovers(videoDrafts.take(_kDraftSlots).toList()));
    unawaited(_loadGifAspects(gifs));
  }

  /// GIF 分頁瀑布流每一格的寬高比（路徑 → 寬/高），只讀檔頭（見
  /// gifAspect）。不讓整頁的第一次畫面等它：還沒量到的先當正方形，全部
  /// 量完才 setState 重排一次（跟「我的 GIF」同一套）
  final Map<String, double> _gifAspect = {};

  Future<void> _loadGifAspects(Iterable<String> refs) async {
    var changed = false;
    for (final ref in refs) {
      if (_gifAspect.containsKey(ref)) continue;
      // 讀不到就當正方形，下次不用再讀
      _gifAspect[ref] = await gifAspect(ref) ?? 1.0;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  /// 封面 cover 進 [w] 寬的 3:4 格時要解碼多寬（實體像素）。封面原檔
  /// 長邊 720，格子只畫一百七十多點寬——照格子的尺寸解碼：
  /// 直片貼寬（＝格寬）、橫片貼高（寬＝格高×比例）
  int _coverDecodeWidth(double w, double aspect) {
    final h = w * 4 / 3;
    return (math.max(w, h * aspect) * MediaQuery.devicePixelRatioOf(context))
        .round();
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

  /// 全部的草稿：影片草稿在前（新到舊），單鍵草稿接在後面。
  /// 「有沒有草稿」就看這一份列不列得出東西：以前只數影片＋照片草稿，
  /// 只有批次／GIF／拼圖草稿的人會看到「還沒有草稿」，那份就找不到了
  List<_DraftEntry> _draftEntries() => [
    for (final m in _videoDrafts) _DraftEntry.video(m),
    if (_photoDraft != null) const _DraftEntry.single(DraftKind.photo),
    if (_batchDraft != null) const _DraftEntry.single(DraftKind.batch),
    if (_gifDraft != null) const _DraftEntry.single(DraftKind.gif),
    if (_collageDraft != null) const _DraftEntry.single(DraftKind.collage),
  ];

  /// 這個分頁現在能不能批次刪除（有東西才給）
  bool get _canBatch => switch (_tab) {
    1 => _gifs.isNotEmpty && !kIsWeb,
    2 => _presets.isNotEmpty,
    _ => false,
  };

  /// 這個分頁全部的鍵（GIF 路徑／範本名字）
  List<String> get _batchKeys =>
      _tab == 1 ? _gifs : [for (final p in _presets) p.name];

  Map<String, int> get _batchSizes => _tab == 1 ? _gifSizes : _presetSizes;

  bool get _allPicked =>
      _batchKeys.isNotEmpty && _picked.length == _batchKeys.length;

  void _cancelBatch() {
    if (_deleting) return;
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  void _togglePick(String key) {
    if (_deleting) return;
    setState(() {
      if (!_picked.remove(key)) _picked.add(key);
    });
  }

  void _toggleAll() {
    if (_deleting) return;
    setState(() {
      if (_allPicked) {
        _picked.clear();
      } else {
        _picked.addAll(_batchKeys);
      }
    });
  }

  Future<void> _deletePicked() async {
    if (_deleting || _picked.isEmpty) return;
    final keys = Set<String>.of(_picked);
    final gif = _tab == 1;
    final ok = await showConfirm(
      context,
      title: gif ? '刪除 ${keys.length} 個 GIF？' : '刪除 ${keys.length} 個範本？',
      message: gif ? '只會刪掉 App 裡選取的 GIF，相簿裡的不受影響' : '只刪除選取的範本，刪除後無法復原',
      action: '刪除',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    var failed = false;
    try {
      failed = gif
          ? (await GifStore.removeMany(keys)).isNotEmpty
          : !await PresetStore.removeMany(keys);
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selecting = false;
      _picked.clear();
    });
    if (failed) {
      showHint(
        context,
        gif ? '有 GIF 未能刪除，請再試一次' : '範本刪除失敗，請再試一次',
        error: true,
      );
    }
    _reload();
  }

  // ── 開頁 ────────────────────────────────────────────────

  /// 直接開某一份草稿：格子點下去就是要繼續剪，不是進資料夾
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

  /// 進草稿的「查看全部」；給 [resume] 就順便接續那一種草稿。
  ///
  /// 續作的判斷（檔案還在不在、帶哪些參數、不見的怎麼講）全在草稿夾
  /// 那幾支 _resumeX 裡，主頁不另外抄一份：格子只是替使用者按下草稿夾
  /// 裡的那一張。所以是先進草稿夾、再由它推編輯頁——回來時人在草稿夾
  Future<void> _openDrafts({DraftKind? resume}) async {
    await Navigator.push(
      context,
      // LightPage 一定要包：這是亮色頁，漏包就掉進暗色主題
      MaterialPageRoute(
        builder: (_) => LightPage(child: DraftsScreen(resume: resume)),
      ),
    );
    _reload();
  }

  /// 點一格草稿：影片草稿直接開編輯器；其餘四種交給草稿夾接續
  void _openEntry(_DraftEntry e) {
    final v = e.video;
    if (v != null) {
      _openDraft(v);
    } else {
      _openDrafts(resume: e.kind);
    }
  }

  /// 點範本磚＝直接編輯那一組（以前是跳到範本夾，還要再找一次）
  Future<void> _editPreset(WatermarkPreset p) async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => WatermarkStudioScreen(edit: p)),
    );
    _reload();
  }

  /// 範本分頁最後一格＋：直接開工作室做一組新的（使用者指定）
  Future<void> _newPreset() async {
    await Navigator.push(
      context,
      editRoute(builder: (_) => const WatermarkStudioScreen()),
    );
    _reload();
  }

  /// 容量與清理。從那裡點分類進去的是同一個「查看全部」頁，只是一進去
  /// 就是批次刪除（使用者看過之後定案：兩邊共用一頁，不另做管理頁）
  Future<void> _openStorage() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LightPage(
          child: StorageScreen(
            openDrafts: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => const LightPage(child: DraftsScreen(batch: true)),
              ),
            ),
            openGifs: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => const LightPage(child: GifsScreen(batch: true)),
              ),
            ),
            openPresets: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const LightPage(child: PresetsScreen(batch: true)),
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted) _reload();
  }

  // ── 長按：磚旁邊跳小選單（背景壓暗、那一格浮起來，見 showLibraryTileMenu）
  // 使用者指定「在總覽這邊也要可以長按刪除」，問法跟查看全部頁同一套

  static const _deleteAction = LibraryMenuAction<bool>(
    true,
    '刪除',
    icon: Icons.delete_outline,
    destructive: true,
  );

  Future<void> _draftMenu(BuildContext tile, _DraftEntry e, double w) async {
    final go = await showLibraryTileMenu<bool>(
      tile,
      preview: _draftCover(e, w),
      title: '刪除這份草稿？',
      actions: const [_deleteAction],
    );
    if (go != true) return;
    final v = e.video;
    if (v != null) {
      await _removeVideoDraft(v);
    } else {
      await _removeSingleDraft(e.kind!);
    }
    if (mounted) _reload();
  }

  Future<void> _gifMenu(BuildContext tile, String ref, double colW) async {
    final go = await showLibraryTileMenu<bool>(
      tile,
      preview: _gifCover(ref, colW),
      title: '刪除這個 GIF？',
      actions: const [_deleteAction],
    );
    if (go != true) return;
    await GifStore.remove(ref);
    if (mounted) _reload();
  }

  /// 範本分頁的長按跟範本夾同一個選單（改名／刪除，見 showPresetActions）
  Future<void> _presetMenu(BuildContext card, WatermarkPreset p) async {
    if (await showPresetActions(card, p) && mounted) _reload();
  }

  // ── 格子 ────────────────────────────────────────────────
  // 都是超橢圓圓角（見 tileShape）、不打陰影。草稿兩欄 3:4 的格子；
  // GIF 與範本是兩欄瀑布流、照各自的比例（使用者指定跟原本的「我的
  // GIF」、範本夾一樣）

  Widget _clip(Widget child) =>
      ClipRSuperellipse(borderRadius: tileClip(), child: child);

  /// 一份草稿的封面（格子本身與長按浮起來的那一格共用）。
  /// [w] 是格子畫出來的寬：封面照這個尺寸解碼（見 _coverDecodeWidth）。
  /// 不放日期／時長角標（使用者指定）：封面本身就是內容；沒有封面的
  /// 四種單鍵草稿留圖示＋名字，不然認不出是什麼
  Widget _draftCover(_DraftEntry e, double w) {
    final v = e.video;
    if (v != null) {
      final cover = _covers[v.id];
      return ColoredBox(
        color: kLTile,
        child: cover == null
            ? const Center(
                child: Icon(
                  Icons.movie_outlined,
                  size: 26,
                  color: Color(0xFFAFAFBB),
                ),
              )
            : Image.memory(
                cover,
                // 鋪滿：這是縮圖不是預覽，留邊只會讓一排格子看起來破碎
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                cacheWidth: _coverDecodeWidth(w, v.thumbAspect ?? 9 / 16),
              ),
      );
    }
    return _singleDraftCover(e.kind!);
  }

  Widget _draftTile(_DraftEntry e, double w) => Builder(
    builder: (tile) => GestureDetector(
      onTap: () => _openEntry(e),
      onLongPress: () => _draftMenu(tile, e, w),
      // 一格自己一層：圓角裁切＋封面全部快取在自己的圖層裡
      child: RepaintBoundary(
        child: AspectRatio(aspectRatio: 3 / 4, child: _clip(_draftCover(e, w))),
      ),
    ),
  );

  /// GIF 的畫面（格子本身與長按浮起來的那一格共用）。[colW] 是它畫出來
  /// 的寬：磚就是 GIF 的比例，欄寬 × dpr 就是實體寬——照這個解碼（匯入
  /// 的 GIF 可能 1080 寬，不縮的話每一格都全解析度解）
  Widget _gifCover(String ref, double colW) => ColoredBox(
    color: kLTile,
    child: GifImage(
      ref,
      cacheWidth: (colW * MediaQuery.devicePixelRatioOf(context)).round(),
    ),
  );

  /// GIF 分頁的一格：照原始比例。點一下放大看，長按旁邊跳小選單問要不要刪；
  /// 批次刪除時點（或長按）＝勾選，左下角標多大
  Widget _gifTile(String ref, double colW) => Builder(
    builder: (tile) => GestureDetector(
      key: ValueKey('profile-gif-$ref'),
      onTap: () => _selecting ? _togglePick(ref) : _previewGif(ref),
      onLongPress: () =>
          _selecting ? _togglePick(ref) : _gifMenu(tile, ref, colW),
      child: _clip(
        AspectRatio(
          aspectRatio: _gifAspect[ref] ?? 1.0,
          // 結構固定是 Stack：進出批次刪除不換父層，動圖不會重新解碼
          child: Stack(
            fit: StackFit.expand,
            children: [
              _gifCover(ref, colW),
              if (_selecting)
                LibrarySelectionMark(
                  selected: _picked.contains(ref),
                  size: formatBytes(_gifSizes[ref] ?? 0),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  /// 點一下放大看（跟「我的 GIF」同一個燈箱）：左右滑換一張、往下滑
  /// 關掉、長按刪掉眼前這一張
  void _previewGif(String ref) {
    final start = _gifs.indexOf(ref);
    if (start < 0) return;
    showDialog<void>(
      context: context,
      // 遮罩燈箱自己畫（要跟著下滑的手指變淡），而且要蓋到狀態列與底部
      barrierColor: Colors.transparent,
      useSafeArea: false,
      builder: (_) =>
          _GifLightbox(gifs: _gifs, start: start, onDelete: _deleteGif),
    );
  }

  /// 燈箱裡長按刪眼前這一張：那裡沒有一格可以浮起來，照舊走確認視窗。
  /// 回傳有沒有真的刪掉
  Future<bool> _deleteGif(String ref) async {
    final ok = await _confirmDeleteGifFile(context, ref);
    if (ok && mounted) _reload();
    return ok;
  }

  /// 範本分頁的一張：跟範本夾同一張卡（使用者指定「像原本點進去那樣」），
  /// 照自己的設計比例。點一下直接編輯那一組
  Widget _presetTile(WatermarkPreset p) => AspectRatio(
    aspectRatio: p.settings.designAspect,
    child: PresetCard(
      preset: p,
      onTap: () => _selecting ? _togglePick(p.name) : _editPreset(p),
      onLongPress: (card) =>
          _selecting ? _togglePick(p.name) : _presetMenu(card, p),
      selected: _selecting ? _picked.contains(p.name) : null,
      size: _selecting ? formatBytes(_presetSizes[p.name] ?? 0) : null,
    ),
  );

  /// 東西比格子多的時候，最後一格照樣畫出來、壓暗，上面寫
  /// 「+N 查看全部」（使用者從五種看更多裡選的丙）。N＝沒排上的那幾個
  Widget _moreTile({
    required Key key,
    required int count,
    required double aspect,
    required Widget cover,
    required VoidCallback onTap,
  }) => GestureDetector(
    key: key,
    onTap: onTap,
    child: AspectRatio(
      aspectRatio: aspect,
      child: _clip(
        Stack(
          fit: StackFit.expand,
          children: [
            cover,
            const ColoredBox(color: Color(0x80000000)),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '+$count',
                    style: const TextStyle(
                      fontSize: 32,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    '查看全部',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 一格一格排成 [columns] 欄，欄距列距都是 [gap]。
  /// 不滿一排的時候右邊空著，不置中——置中是改版面
  Widget _grid(List<Widget> tiles, {required int columns, required double gap}) {
    final rows = <Widget>[];
    for (var start = 0; start < tiles.length; start += columns) {
      if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) SizedBox(width: gap),
              Expanded(
                child: start + c < tiles.length
                    ? tiles[start + c]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  // ── 三個分頁 ────────────────────────────────────────────

  /// 草稿分頁：格子＋底下那塊空白放「太好用啦」（使用者指定放回來、
  /// 擺在草稿底下）
  Widget _draftsTab(double inner) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [_drafts(inner), const SizedBox(height: 28), _loveButton()],
  );

  /// 「太好用啦」：開斗內頁
  Widget _loveButton() => GestureDetector(
    key: const ValueKey('profile-love'),
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LightPage(child: DonateScreen())),
    ),
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
  );

  Widget _drafts(double inner) {
    final entries = _draftEntries();
    if (entries.isEmpty) {
      // 空的時候不畫框，也不解釋草稿怎麼來——真的存了一份之後
      // 這行就永遠不會再出現，講了也是白講
      return const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 4),
        child: Center(child: Text('還沒有草稿', style: _kHintStyle)),
      );
    }
    final w = (inner - 10) / 2;
    final more = entries.length > _kDraftSlots;
    return _grid(
      [
        for (final (i, e) in entries.take(_kDraftSlots).indexed)
          if (more && i == _kDraftSlots - 1)
            _moreTile(
              key: const ValueKey('profile-drafts-more'),
              count: entries.length - _kDraftSlots,
              aspect: 3 / 4,
              cover: _draftCover(e, w),
              onTap: _openDrafts,
            )
          else
            _draftTile(e, w),
      ],
      columns: 2,
      gap: 10,
    );
  }

  /// GIF 分頁：原本「我的 GIF」那一套兩欄瀑布流，全部列出來（使用者
  /// 指定）。新增在右下角的＋（見 build）
  Widget _gifsTab(double inner) {
    if (_gifs.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 10, bottom: 4),
          child: Center(child: Text('還沒有 GIF', style: _kHintStyle)),
        ),
      );
    }
    final colW = (inner - 10) / 2;
    return _masonry(
      items: _gifs,
      colW: colW,
      aspect: (ref) => _gifAspect[ref] ?? 1.0,
      tile: (ref) => _gifTile(ref, colW),
    );
  }

  /// 範本分頁：跟範本夾一模一樣——兩欄瀑布流，每張照自己的設計比例
  ///（使用者指定「像原本點進去那樣」）。一組都沒有的時候給一張入口卡
  Widget _presetsTab(double inner) {
    if (_presets.isEmpty) {
      return SliverToBoxAdapter(
        child: Row(
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: PresetAddCard(onTap: _newPreset),
              ),
            ),
            const SizedBox(width: 10),
            const Spacer(),
          ],
        ),
      );
    }
    return _masonry(
      items: _presets,
      colW: (inner - 10) / 2,
      aspect: (p) => p.settings.designAspect,
      tile: _presetTile,
    );
  }

  // ── 上方與頁尾 ──────────────────────────────────────────

  /// 返回鍵＋右上角：草稿分頁是「容量與清理」（原本的圖示＋字，使用者
  /// 指定保留），GIF 與範本分頁是「批次刪除」。批次刪除中左邊換成
  /// 「取消」、右邊換成「全選」。高度固定 48：換來換去內容不跳
  Widget _topBar() => SizedBox(
    height: 48,
    child: Row(
      children: [
        if (_selecting)
          TextButton(
            onPressed: _deleting ? null : _cancelBatch,
            child: const Text('取消'),
          )
        else
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new, size: 22, color: kLText),
          ),
        const Spacer(),
        if (_selecting)
          TextButton(
            onPressed: _deleting ? null : _toggleAll,
            child: Text(_allPicked ? '取消全選' : '全選'),
          )
        else if (_tab == 0)
          TextButton.icon(
            key: const ValueKey('profile-storage'),
            onPressed: _openStorage,
            icon: const Icon(Icons.storage_outlined, size: 18),
            label: const Text('容量與清理'),
          )
        else if (_canBatch)
          TextButton(
            key: const ValueKey('profile-batch'),
            onPressed: () => setState(() => _selecting = true),
            child: const Text('批次刪除'),
          ),
      ],
    ),
  );

  /// 三個分頁的標題：選中的大一號、深色，其他小一號、淡色；
  /// 切換時字級跟顏色一起補間。三個字底部對齊（baseline），
  /// 大小不同也排在同一條線上
  Widget _tabBar() => Padding(
    padding: const EdgeInsets.fromLTRB(22, 6, 22, 0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        for (final (i, label) in _kTabs.indexed) ...[
          if (i > 0) const SizedBox(width: 22),
          Semantics(
            button: true,
            selected: _tab == i,
            child: GestureDetector(
              key: ValueKey('profile-tab-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_tab == i || _deleting) return;
                setState(() {
                  _tab = i;
                  // 批次刪除只管眼前這一個分頁
                  _selecting = false;
                  _picked.clear();
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  style: TextStyle(
                    fontFamily: 'NotoSansTC',
                    fontSize: _tab == i ? _kTabOn : _kTabOff,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    color: _tab == i ? kLText : _kTabIdle,
                  ),
                  child: Text(label),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );

  /// 右下角的黑圓＋（跟原本「我的 GIF」、範本夾同一款）
  Widget _fab(Key key, VoidCallback onPressed) => FloatingActionButton(
    key: key,
    onPressed: onPressed,
    backgroundColor: Colors.black,
    foregroundColor: Colors.white,
    shape: const CircleBorder(),
    child: const Icon(Icons.add, size: 28),
  );

  /// 頁尾兩個文字連結（「太好用啦」那顆在草稿分頁裡，見 _draftsTab）
  Widget _footer() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      GestureDetector(
        onTap: () => showFeedbackDialog(context),
        child: const Text('意見回饋', style: _kFootStyle),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Text('·', style: _kDotStyle),
      ),
      GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LightPage(child: AboutScreen())),
        ),
        child: const Text('關於這個 App', style: _kFootStyle),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final picked = _picked.length;
    return PopScope(
      // 批次刪除中按返回／右滑＝先退出批次刪除，不是離開這一頁
      canPop: !_selecting && !_deleting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelBatch();
      },
      // 非編輯頁面全頁都能右滑返回（編輯畫面橫向手勢太多，刻意不放）
      child: SwipeBack(
        child: Scaffold(
          backgroundColor: kLBg,
          // GIF 與範本分頁右下角一顆＋（使用者指定要原本那顆）：GIF 是
          // 製作／從相簿匯入／從檔案匯入（見 addGifFromDevice），範本是開
          // 工作室做一組新的。批次刪除時收起來，底下換成紅鈕
          floatingActionButton: _selecting
              ? null
              : switch (_tab) {
                  1 => _fab(const ValueKey('profile-gif-add'), () async {
                    if (await addGifFromDevice(context)) _reload();
                  }),
                  2 => _fab(const ValueKey('profile-preset-add'), _newPreset),
                  _ => null,
                },
          // 不掛 appBar：返回鍵是內容的第一列，上下都沒有釘死的白帶
          //（使用者指定「上方箭頭不要 sticky」「上面不要白條」）
          body: Stack(
            fit: StackFit.expand,
            children: [
              SafeArea(
                top: false,
                bottom: false,
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final inner = cons.maxWidth - _side.horizontal;
                    return CustomScrollView(
                      // 一頁裝得下就不會捲（Clamping 沒有回彈，使用者指定
                      // 「不要能上下捲動」）；小螢幕、字級調很大、東西多裝
                      // 不下才捲得動——寧可捲，也不能把東西截掉
                      physics: const ClampingScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(14, pad.top + 4, 8, 0),
                          sliver: SliverToBoxAdapter(child: _topBar()),
                        ),
                        SliverToBoxAdapter(child: _tabBar()),
                        SliverPadding(
                          // 有＋的分頁底下多留一段：捲到底時最後一格不被
                          // ＋（批次刪除時是紅鈕）蓋住
                          padding: EdgeInsets.fromLTRB(
                            22,
                            18,
                            22,
                            _tab == 0 ? 0 : 40,
                          ),
                          sliver: switch (_tab) {
                            0 => SliverToBoxAdapter(child: _draftsTab(inner)),
                            1 => _gifsTab(inner),
                            _ => _presetsTab(inner),
                          },
                        ),
                        // 剩下的高度全給頁尾前面：頁尾貼著底部，中間不留
                        // 一塊看起來像沒載完的空白
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: EdgeInsets.only(
                                top: 22,
                                bottom: pad.bottom + 10,
                              ),
                              child: _footer(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              // 選了至少一個，刪除鈕才從底下浮上來（跟查看全部同一顆）
              LibraryDeleteDock(
                visible: _selecting && picked > 0,
                busy: _deleting,
                label: libraryDeleteLabel(
                  picked,
                  '個',
                  [
                    for (final k in _picked) _batchSizes[k] ?? 0,
                  ].fold<int>(0, (a, b) => a + b),
                ),
                onPressed: _deletePicked,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 草稿的「查看全部」：直接是瀑布流，上面只有返回鍵跟「批次刪除」
///（使用者指定其他東西都不要有）。點一格接著剪；長按旁邊跳小選單問
/// 要不要刪；批次刪除＝每一格標出刪掉能省多少，選好按底下的紅鈕
class DraftsScreen extends StatefulWidget {
  /// 進來就接續這一種草稿（個人中心的單鍵草稿格點下去走這條，見
  /// _ProfileScreenState._openDrafts）。null＝只是打開
  final DraftKind? resume;

  /// 一進來就是批次刪除（從「容量與清理」點草稿進來的）
  final bool batch;

  const DraftsScreen({super.key, this.resume, this.batch = false});

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

  /// 批次刪除：勾好幾份、底下的紅鈕一次刪
  late bool _selecting = widget.batch;
  bool _deleting = false;
  final Set<String> _picked = {};

  /// 佔用空間（見 StorageUsage）：null＝還在算。批次刪除時每一格標的
  /// 「刪掉能省多少」從這裡來（共用的轉檔暫存不算，見 freeableFor）
  StorageReport? _usage;
  int _usageGen = 0;

  /// 舊封面換成 JPEG 那一輪的代號：一打開編輯頁就作廢，別在背景跟它搶
  int _coverGen = 0;

  Future<void> _scanUsage() async {
    final gen = ++_usageGen;
    try {
      final r = await StorageUsage.scan();
      if (!mounted || gen != _usageGen) return;
      setState(() => _usage = r);
    } catch (_) {}
  }

  /// 打開編輯頁：背景換封面那一輪先停（別跟編輯器搶解碼與 GPU），
  /// 回來再讀一次清單、再算一次容量。封面不放掉：放掉的話返回的轉場
  /// 裡每一格都先變回圖示再跳回封面；換成 JPEG 之後留著也只佔一點點
  Future<void> _openOver(Route<void> route) async {
    _coverGen++;
    await Navigator.push(context, route);
    if (mounted) _reload();
  }

  void _cancelSelection() {
    if (_deleting) return;
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  void _togglePick(String id) {
    if (_deleting) return;
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
    });
  }

  /// 全選只算影片草稿：單鍵草稿各只有一份，長按就能刪，不進批次
  bool get _allPicked =>
      _drafts.isNotEmpty && _picked.length == _drafts.length;

  void _toggleAll() {
    if (_deleting) return;
    setState(() {
      if (_allPicked) {
        _picked.clear();
      } else {
        _picked.addAll(_drafts.map((m) => m.id));
      }
    });
  }

  Future<void> _deletePicked() async {
    if (_picked.isEmpty || _deleting) return;
    final ok = await showConfirm(
      context,
      title: '刪除 ${_picked.length} 份草稿？',
      message: '未完成的專案會被移除，無法復原',
      action: '刪除',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      // 一次刪完、連帶清理只算一次（見 DraftStore.removeMany）
      await DraftStore.removeMany({..._picked});
    } finally {
      if (mounted) {
        setState(() {
          _deleting = false;
          _picked.clear();
          _selecting = false;
        });
      }
    }
    if (mounted) _reload();
  }

  @override
  void initState() {
    super.initState();
    _reload().then((_) => _autoResume());
  }

  Future<void> _reload() async {
    final found = await DraftStore.list();
    // 「有沒有」的規則跟個人中心同一份（見 _readDraftJson）
    final photo = await _readDraftJson(kPhotoDraftKey, 'photo');
    final batch = await _readDraftJson(kBatchDraftKey, 'files');
    final gif = await _readDraftJson(kGifDraftKey, 'path');
    final collage = await _readDraftJson(kCollageDraftKey, 'photos');
    if (!mounted) return;
    setState(() {
      _drafts = found;
      _photoDraft = photo;
      _batchDraft = batch;
      _gifDraft = gif;
      _collageDraft = collage;
      _picked.retainAll(found.map((m) => m.id));
      _loading = false;
    });
    unawaited(_loadCovers(found));
    unawaited(_scanUsage());
  }

  /// 被要求接續的那一份（見 [DraftsScreen.resume]）：清單讀好之後替
  /// 使用者按下那一張。只做一次（進場時）——從編輯頁回來就留在資料夾裡
  Future<void> _autoResume() async {
    if (!mounted) return;
    switch (widget.resume) {
      case null:
        return;
      case DraftKind.photo:
        await _resumePhoto();
      case DraftKind.batch:
        await _resumeBatch();
      case DraftKind.gif:
        await _resumeGif();
      case DraftKind.collage:
        await _resumeCollage();
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
    await _openOver(
      editRoute(
        builder: (_) => GifScreen(
          path: path,
          name: d['name'] as String? ?? 'video',
          restore: d,
        ),
      ),
    );
  }

  /// 續作拼圖：由拼圖頁檢查全部照片；讀不到時保留原草稿。
  Future<void> _resumeCollage() async {
    final d = _collageDraft;
    if (d == null) return;
    await _openOver(editRoute(builder: (_) => CollageScreen(restore: d)));
  }

  /// 續作批次浮水印：檔案還在的帶回去（草稿記的路徑不見了但留過複本
  /// 就用複本，見 DraftAssets）。任何素材讀不到都保留原草稿；單張
  /// 覆寫用 batchRestoreFor 對應到修復後的路徑。
  Future<void> _resumeBatch() async {
    final d = _batchDraft;
    if (d == null) return;
    final paths = (d['files'] as List? ?? []).cast<String>();
    final alive = <String?>[];
    var gone = 0;
    for (final path in paths) {
      final now = await DraftAssets.resolve(DraftAssets.batch, path);
      if (now == null) gone++;
      alive.add(now);
    }
    final files = [for (final p in alive) ?p].map(XFile.new).toList();
    if (files.isEmpty || gone > 0) {
      if (mounted) {
        showHint(context, '有素材暫時無法讀取，原草稿已保留，請確認素材後再開啟', error: true);
      }
      return;
    }
    if (!mounted) return;
    await _openOver(
      editRoute(
        builder: (_) => BatchWatermarkScreen(
          files: files,
          restore: batchRestoreFor(d, alive),
        ),
      ),
    );
  }

  Future<void> _resumePhoto() async {
    final d = _photoDraft;
    if (d == null) return;
    await _openOver(
      editRoute(
        builder: (_) => PhotoEditorScreen(
          photo: XFile(d['photo'] as String),
          draft: d['state'] as String?,
        ),
      ),
    );
  }

  /// 草稿封面：內容另外存（見 DraftStore.thumb），讀進來後放這個
  /// 快取；build 裡只查表，不解碼也不丟例外
  final Map<String, Uint8List> _covers = {};

  Future<void> _loadCovers(List<DraftMeta> metas) async {
    var loaded = 0;
    for (final m in metas) {
      if (!m.hasThumb || _covers.containsKey(m.id)) continue;
      final t = await DraftStore.thumb(m.id);
      if (t == null) continue;
      try {
        _covers[m.id] = base64Decode(t);
      } catch (_) {
        // 壞掉的那筆就沒有封面，不能讓整頁紅屏
      }
      // 第一屏那幾張先上：磚的比例不看封面到了沒（見 _tileAspect），
      // 先畫出來不會讓版面跳。以前上百張全讀完才一起出現
      if (++loaded == 6 && mounted) setState(() {});
    }
    if (!mounted) return;
    setState(() {});
    unawaited(_shrinkOldCovers(_coverGen));
  }

  static bool _isPng(Uint8List b) =>
      b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47;

  /// 舊版的封面是 720p PNG（一張 1.2MB，實機上百份）：趁草稿夾開著，一張
  /// 一張換成同一張的 JPEG（一百多 KB），之後讀得快、記憶體也佔得少。
  /// 只換「檔案裡還是同一張」的（見 DraftStore.replaceThumbIfSame）；
  /// 打開編輯頁就停
  Future<void> _shrinkOldCovers(int gen) async {
    if (kIsWeb) return;
    var changed = 0;
    for (final id in _covers.keys.toList()) {
      if (!mounted || gen != _coverGen) break;
      final b = _covers[id];
      if (b == null || !_isPng(b)) continue;
      try {
        final codec = await ui.instantiateImageCodec(b);
        final frame = await codec.getNextFrame();
        codec.dispose();
        final PhotoEncoded enc;
        try {
          enc = await encodePhotoImage(frame.image, jpeg: true, quality: 85);
        } finally {
          frame.image.dispose();
        }
        if (enc.ext != 'jpg') return; // 這台轉不了 JPEG：不用再試
        if (!mounted || gen != _coverGen) break;
        final done = await DraftStore.replaceThumbIfSame(
          id,
          base64Encode(b),
          base64Encode(enc.bytes),
        );
        if (done) {
          _covers[id] = enc.bytes;
          changed++;
        }
      } catch (_) {}
      // 一張一張來，中間讓出去：捲動中的畫面不能被它卡住
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (changed > 0 && mounted) setState(() {});
  }

  Future<void> _resume(DraftMeta m) async {
    final data = await DraftStore.load(m.id);
    if (data == null || !mounted) {
      if (mounted) showHint(context, '這份草稿讀不到了', error: true);
      return;
    }
    await _openOver(
      editRoute(
        builder: (_) => VideoEditorScreen(draft: data, draftId: m.id),
      ),
    );
  }

  /// 點一格：影片草稿接著剪；單鍵草稿各自接續
  Future<void> _open(_DraftEntry e) async {
    final v = e.video;
    if (v != null) return _resume(v);
    switch (e.kind!) {
      case DraftKind.photo:
        return _resumePhoto();
      case DraftKind.batch:
        return _resumeBatch();
      case DraftKind.gif:
        return _resumeGif();
      case DraftKind.collage:
        return _resumeCollage();
    }
  }

  /// 長按一格：背景壓暗、那一格浮起來，旁邊跳小選單問要不要刪
  ///（使用者指定，不再跳整頁的確認視窗）
  Future<void> _menu(BuildContext tile, _DraftEntry e, double colW) async {
    final go = await showLibraryTileMenu<bool>(
      tile,
      preview: _cover(e, colW),
      title: '刪除這份草稿？',
      actions: const [
        LibraryMenuAction(
          true,
          '刪除',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (go != true) return;
    final v = e.video;
    if (v != null) {
      await _removeVideoDraft(v);
    } else {
      await _removeSingleDraft(e.kind!);
    }
    if (mounted) _reload();
  }

  /// 全部的草稿：影片草稿在前（新到舊），單鍵草稿接在後面——
  /// 跟個人中心同一個順序
  List<_DraftEntry> get _entries => [
    for (final m in _drafts) _DraftEntry.video(m),
    if (_photoDraft != null) const _DraftEntry.single(DraftKind.photo),
    if (_batchDraft != null) const _DraftEntry.single(DraftKind.batch),
    if (_gifDraft != null) const _DraftEntry.single(DraftKind.gif),
    if (_collageDraft != null) const _DraftEntry.single(DraftKind.collage),
  ];

  // ── 瀑布流：封面照專案畫布原比例排（直的、方的、橫的混在一起），
  // 格子本身零文字——最像相簿、畫面最純（日期、時長都不放）

  /// 這一格的寬高比。影片草稿看「有沒有封面」而不是「封面讀到了沒」：
  /// 封面一張張讀進來時磚的大小不變，版面不跳。單鍵草稿一律方形
  double _tileAspect(_DraftEntry e) {
    final v = e.video;
    if (v == null) return 1.0;
    return v.hasThumb ? (v.thumbAspect ?? 9 / 16) : 1.0;
  }

  /// 一格的內容（格子本身與長按浮起來的那一格共用）。[colW] 是它畫出來
  /// 的寬：磚就是封面的比例，欄寬 × dpr 就是實體寬——照這個解碼，不是
  /// 封面原尺寸（長邊 720 的圖解開一張 1.2MB，實機曾有 113 份）
  Widget _cover(_DraftEntry e, double colW) {
    final v = e.video;
    if (v == null) return _singleDraftCover(e.kind!);
    final cover = _covers[v.id];
    if (cover == null) {
      return const ColoredBox(
        color: kLTile,
        child: Icon(Icons.movie_outlined, size: 26, color: kLAccent),
      );
    }
    return Image.memory(
      cover,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      cacheWidth: (colW * MediaQuery.devicePixelRatioOf(context)).round(),
    );
  }

  /// 一格。批次刪除時整張可勾、左下角標刪掉能省多少；單鍵草稿不進批次
  ///（各只有一份，長按就能刪），淡掉表示選不到
  Widget _tile(_DraftEntry e, double colW) {
    final v = e.video;
    return Builder(
      builder: (tile) => GestureDetector(
        onTap: _selecting
            ? (v == null ? null : () => _togglePick(v.id))
            : () => _open(e),
        onLongPress: _selecting
            ? (v == null ? null : () => _togglePick(v.id))
            : () => _menu(tile, e, colW),
        // 形狀跟個人中心的磚同一家（超橢圓，見 tileShape）。
        // 不自己包 RepaintBoundary：SliverList 已經給每一格一層
        child: ClipRSuperellipse(
          borderRadius: tileClip(),
          child: AspectRatio(
            aspectRatio: _tileAspect(e),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _cover(e, colW),
                if (_selecting)
                  if (v != null)
                    LibrarySelectionMark(
                      selected: _picked.contains(v.id),
                      size: _usage == null
                          ? null
                          : formatBytes(_usage!.freeableFor({v.id})),
                    )
                  else
                    const ColoredBox(color: Color(0x99FFFFFF)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _entries;
    final picked = _picked.length;
    return PopScope(
      // 批次刪除中按返回／右滑＝先退出批次刪除，不是離開這一頁
      canPop: !_selecting && !_deleting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelSelection();
      },
      child: SwipeBack(
        child: Scaffold(
          // 上面只有返回鍵跟「批次刪除」（使用者指定其他東西都不要有）；
          // 批次刪除時左邊換成「取消」、右邊換成「全選」
          appBar: AppBar(
            automaticallyImplyLeading: !_selecting,
            leadingWidth: _selecting ? 76 : null,
            leading: _selecting
                ? TextButton(
                    onPressed: _deleting ? null : _cancelSelection,
                    child: const Text('取消'),
                  )
                : null,
            actions: [
              if (_selecting)
                TextButton(
                  onPressed: _deleting || _drafts.isEmpty ? null : _toggleAll,
                  child: Text(_allPicked ? '取消全選' : '全選'),
                )
              else if (_drafts.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _selecting = true),
                  child: const Text('批次刪除'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          // 撐滿整個 body：Scaffold 給 body 的是鬆的約束，不撐滿的話 Stack
          // 只有內容那麼高，紅鈕就浮在畫面中間（範本少的時候）
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (all.isEmpty)
                const Center(
                  child: Text(
                    '還沒有草稿',
                    style: TextStyle(fontSize: 13, color: kLTextDim),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, box) {
                    // 兩欄瀑布流：左右各 16、中間 10
                    final colW = (box.maxWidth - 16 * 2 - 10) / 2;
                    return CustomScrollView(
                      slivers: [
                        SliverPadding(
                          // 底下多留：批次刪除的紅鈕浮在內容上，最後一格
                          // 才不會被它蓋住
                          padding: EdgeInsets.fromLTRB(
                            16,
                            16,
                            16,
                            _selecting ? 96 : 16,
                          ),
                          sliver: _masonry(
                            items: all,
                            colW: colW,
                            aspect: _tileAspect,
                            tile: (e) => _tile(e, colW),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              // 選了至少一份，刪除鈕才從底下浮上來（直接浮在內容上，
              // 後面不墊白底——使用者指定「底部不要有白邊」）
              LibraryDeleteDock(
                visible: _selecting && picked > 0,
                busy: _deleting,
                label: libraryDeleteLabel(
                  picked,
                  '份',
                  _usage?.freeableFor(_picked),
                ),
                onPressed: _deletePicked,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 我的 GIF（GIF 的「查看全部」）：做好的 GIF 都留一份在這裡。
///
/// 相簿那份跟幾千張照片混在一起，要拿它當素材根本找不到；
/// 這裡只有 GIF。點一下放大看；長按旁邊跳小選單問要不要刪；
/// 批次刪除＝每一格標出多大，選好按底下的紅鈕
class GifsScreen extends StatefulWidget {
  /// 一進來就是批次刪除（從「容量與清理」點 GIF 進來的）
  final bool batch;

  const GifsScreen({super.key, this.batch = false});

  @override
  State<GifsScreen> createState() => _GifsScreenState();
}

class _GifsScreenState extends State<GifsScreen> {
  List<String> _gifs = const [];
  late bool _selecting = widget.batch;
  bool _deleting = false;
  final Set<String> _picked = {};

  /// 每個 GIF 多大（批次刪除時標在格子上、加總寫在紅鈕上）
  Map<String, int> _sizes = const {};

  void _cancelSelection() {
    if (_deleting) return;
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  void _togglePick(String ref) {
    if (_deleting) return;
    setState(() {
      if (!_picked.remove(ref)) _picked.add(ref);
    });
  }

  bool get _allPicked => _gifs.isNotEmpty && _picked.length == _gifs.length;

  void _toggleAll() {
    if (_deleting) return;
    setState(() {
      if (_allPicked) {
        _picked.clear();
      } else {
        _picked.addAll(_gifs);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _picked.isEmpty) return;
    final refs = Set<String>.of(_picked);
    setState(() => _deleting = true);
    try {
      final ok = await showConfirm(
        context,
        title: '刪除 ${refs.length} 個 GIF？',
        message: '只會刪掉 App 裡選取的 GIF，相簿裡的不受影響',
        action: '刪除',
      );
      if (!ok || !mounted) return;
      final failed = await GifStore.removeMany(refs);
      await _reload();
      if (!mounted) return;
      setState(() {
        _picked
          ..clear()
          ..addAll(failed.intersection(_gifs.toSet()));
        _selecting = _picked.isNotEmpty;
      });
      if (failed.isNotEmpty) {
        showHint(context, '有 ${failed.length} 個 GIF 未能刪除，請再試一次', error: true);
      }
    } catch (_) {
      if (mounted) showHint(context, 'GIF 刪除失敗，請再試一次', error: true);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

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
      _sizes = {for (final ref in gifs) ref: GifStore.sizeOf(ref)};
      _picked.retainAll(gifs);
      _loading = false;
    });
    // 比例只讀檔頭（見 gifAspect），不解任何一格像素；以前是把每個 GIF
    // 的第一格整張解開只為了拿寬高，codec 還沒 dispose。
    // 全部量完才 setState 一次：以前每量到一個就重排一次瀑布流，
    // 四十個 GIF 就是四十次整頁重排
    var changed = false;
    for (final ref in gifs) {
      if (_aspect.containsKey(ref)) continue;
      // 讀不到就當正方形，至少排得出來
      _aspect[ref] = await gifAspect(ref) ?? 1.0;
      changed = true;
      if (!mounted) return;
    }
    if (changed) setState(() {});
  }

  /// 一格的畫面（格子本身與長按浮起來的那一格共用）。GIF 自己會動——
  /// Image.file 讀到多格就會播。[colW] 是它畫出來的寬：磚就是 GIF 的
  /// 比例，欄寬 × dpr 就是實體寬，照這個解碼（匯入的 GIF 可能 1080 寬，
  /// 不縮的話每格都全解析度解）
  Widget _gifCover(String ref, double colW) => ColoredBox(
    color: kLTile,
    child: GifImage(
      ref,
      cacheWidth: (colW * MediaQuery.devicePixelRatioOf(context)).round(),
    ),
  );

  /// 一格：照原始比例畫。形狀跟個人中心的磚同一家（超橢圓，見 tileShape）
  Widget _gifTile(String ref, double colW) => Builder(
    builder: (tile) => GestureDetector(
      key: ValueKey('gif-$ref'),
      onTap: () => _selecting ? _togglePick(ref) : _preview(ref),
      onLongPress: () =>
          _selecting ? _togglePick(ref) : _menu(tile, ref, colW),
      child: ClipRSuperellipse(
        borderRadius: tileClip(),
        child: AspectRatio(
          aspectRatio: _aspect[ref] ?? 1.0,
          child: Semantics(
            selected: _selecting ? _picked.contains(ref) : null,
            label: 'GIF',
            child: Stack(
              fit: StackFit.expand,
              children: [
                _gifCover(ref, colW),
                if (_selecting)
                  LibrarySelectionMark(
                    selected: _picked.contains(ref),
                    size: formatBytes(_sizes[ref] ?? 0),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// 長按一格：背景壓暗、那一格浮起來，旁邊跳小選單問要不要刪
  ///（使用者指定，不再跳整頁的確認視窗）
  Future<void> _menu(BuildContext tile, String ref, double colW) async {
    final go = await showLibraryTileMenu<bool>(
      tile,
      preview: _gifCover(ref, colW),
      title: '刪除這個 GIF？',
      actions: const [
        LibraryMenuAction(
          true,
          '刪除',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (go != true) return;
    await GifStore.remove(ref);
    if (mounted) _reload();
  }

  /// 燈箱裡長按刪眼前這一張：那裡沒有一格可以浮起來，照舊走確認視窗。
  /// 回傳有沒有真的刪掉（確認視窗按取消就是 false）
  Future<bool> _delete(String ref) async {
    final ok = await _confirmDeleteGifFile(context, ref);
    if (ok && mounted) _reload();
    return ok;
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
    final picked = _picked.length;
    final freed = [for (final ref in _picked) _sizes[ref] ?? 0].fold(0, (a, b) => a + b);
    return PopScope(
      // 批次刪除中按返回／右滑＝先退出批次刪除，不是離開這一頁
      canPop: !_selecting && !_deleting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelSelection();
      },
      child: SwipeBack(
        child: Scaffold(
          // 上面只有返回鍵跟「批次刪除」；批次刪除時左邊換成「取消」、
          // 右邊換成「全選」（跟草稿的查看全部同一套）
          appBar: AppBar(
            automaticallyImplyLeading: !_selecting,
            leadingWidth: _selecting ? 76 : null,
            leading: _selecting
                ? TextButton(
                    onPressed: _deleting ? null : _cancelSelection,
                    child: const Text('取消'),
                  )
                : null,
            actions: [
              if (_selecting)
                TextButton(
                  onPressed: _deleting || _gifs.isEmpty ? null : _toggleAll,
                  child: Text(_allPicked ? '取消全選' : '全選'),
                )
              else if (!_loading && _gifs.isNotEmpty && !kIsWeb)
                TextButton(
                  onPressed: () => setState(() => _selecting = true),
                  child: const Text('批次刪除'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          // 右下浮動黑圓 +（跟範本夾同款）：現做一個 GIF，或把自己的
          // 收進來（相簿或檔案 App 都可以，見 addGifFromDevice）。
          // 批次刪除時收起來，底下換成紅鈕
          floatingActionButton: _selecting
              ? null
              : FloatingActionButton(
                  onPressed: () async {
                    if (await addGifFromDevice(context)) _reload();
                  },
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.add, size: 28),
                ),
          // 撐滿整個 body：Scaffold 給 body 的是鬆的約束，不撐滿的話 Stack
          // 只有內容那麼高，紅鈕就浮在畫面中間（範本少的時候）
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_gifs.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      '還沒有 GIF。\n\n'
                      // 給「一個都沒有」的人看的，所以講這一頁就辦得到的事：
                      // ＋ 現在自己能做 GIF，不必再繞回首頁
                      '按右下角的＋做一個，'
                      '或把相簿、檔案裡現成的 GIF 收進來。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kLTextDim, height: 1.6),
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, box) {
                    // 兩欄瀑布流：左右各 16、中間 10
                    final colW = (box.maxWidth - 16 * 2 - 10) / 2;
                    return CustomScrollView(
                      slivers: [
                        SliverPadding(
                          // 底部多留：最後一張不被浮動 +／紅鈕蓋住
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                          sliver: _masonry(
                            items: _gifs,
                            colW: colW,
                            // 比例還沒量到就先當正方形，量到了會 setState 重排
                            aspect: (ref) => _aspect[ref] ?? 1.0,
                            tile: (ref) => _gifTile(ref, colW),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              // 選了至少一個，刪除鈕才從底下浮上來（直接浮在內容上，
              // 後面不墊白底）
              LibraryDeleteDock(
                visible: _selecting && picked > 0,
                busy: _deleting,
                label: libraryDeleteLabel(picked, '個', freed),
                onPressed: _deleteSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 兩欄瀑布流（草稿夾、我的 GIF、個人中心的 GIF 與範本分頁共用）：
/// 每一個丟進目前比較短的那一欄，格子照各自的寬高比 [aspect]。
///
/// 每一欄一條 SliverVariedExtentList，只做「看得到的那幾格」。以前是
/// 捲動視窗包兩個 Column：四十個 GIF 全部一次做出來——四十個動圖解碼器
/// 同時在跑、捲出畫面外照跑不誤；草稿夾三十張封面同時活著、一起解碼
///（實機曾有 113 份）；而且整片只有一個 repaint boundary，任何一格換一格
/// 畫面就整組重錄（實測一次 0.60ms，四十個各跑各的＝一秒好幾百次）。
/// SliverList 會自己回收看不到的格子（動圖跟著停），並給每一格一層
/// RepaintBoundary。
///
/// 每一格的高度本來就算得出來（欄寬 ÷ 寬高比）：給了 VariedExtent，沒做
/// 出來的格子也定得出位置；總長也直接給（見 _ExactExtentDelegate）。
/// 排欄、算總長、排版三邊用同一個式子，不然版面會自己對不齊。
/// 欄距、格距都是 10：左欄右邊 5、右欄左邊 5，格距在下面——兩欄各分到
/// 一半寬度，扣掉 5 剛好是 [colW]
Widget _masonry<T>({
  required List<T> items,
  required double colW,
  required double Function(T item) aspect,
  required Widget Function(T item) tile,
}) {
  double extent(T e) => colW / aspect(e) + 10;
  final cols = <List<T>>[[], []];
  final h = [0.0, 0.0];
  for (final e in items) {
    final c = h[0] <= h[1] ? 0 : 1;
    cols[c].add(e);
    h[c] += extent(e);
  }
  return SliverCrossAxisGroup(
    slivers: [
      for (var c = 0; c < 2; c++)
        SliverVariedExtentList(
          itemExtentBuilder: (i, _) => extent(cols[c][i]),
          delegate: _ExactExtentDelegate(
            (_, i) => i < 0 || i >= cols[c].length
                ? null
                : Padding(
                    padding: EdgeInsets.only(
                      left: c == 0 ? 0 : 5,
                      right: c == 0 ? 5 : 0,
                      bottom: 10,
                    ),
                    child: tile(cols[c][i]),
                  ),
            childCount: cols[c].length,
            total: h[c],
          ),
        ),
    ],
  );
}

/// 「這一條總共多長」直接給答案，不要框架去外插。
///
/// SliverList 家族預設是拿「已經做出來那幾格的平均高度」乘上剩下的
/// 格數當總長。瀑布流的格子高矮差很多（直片是橫片的三倍高），猜出來
/// 的數字跟真的差一截，而且會隨著捲動一直改——甩到底的那一下會頓。
/// 每一格的高度我們本來就算得出來（欄寬 ÷ 比例），加總就是答案
class _ExactExtentDelegate extends SliverChildBuilderDelegate {
  /// 全部格子的高度總和
  final double total;

  _ExactExtentDelegate(
    super.builder, {
    required super.childCount,
    required this.total,
  });

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => total;
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
            child: ClipRSuperellipse(
              // 圓角切在 GIF 本人上（不是外面包一層框），
              // 就沒有對不齊的白邊。它是一個對話框，圓角跟對話框同級；
              // 形狀跟磚同一家（超橢圓，見 tileShape）
              borderRadius: tileClip(kDialogRadius),
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
