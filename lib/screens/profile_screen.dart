import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/watermark_settings.dart';
import '../services/draft_store.dart';
import '../services/preset_store.dart';
import '../theme.dart';
import '../widgets/swipe_back.dart';
import '../widgets/watermark_layer.dart';
import 'about_screen.dart';
import 'donate_screen.dart';
import 'feedback_screen.dart';
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

class _ProfileScreenState extends State<ProfileScreen> {
  List<WatermarkPreset> _presets = const [];

  /// 影片草稿與照片草稿（沒有就是 null）。這一頁直接把草稿畫出來，
  /// 不再只顯示「有幾個」——使用者要找的是「那一個專案」，不是數量
  Map<String, dynamic>? _videoDraft;
  Map<String, dynamic>? _photoDraft;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final presets = await PresetStore.load();
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
      _videoDraft = readDraft(kDraftKey, 'clips');
      _photoDraft = readDraft(kPhotoDraftKey, 'photo');
    });
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

  /// 存檔時間講人話：剛剛／N 分鐘前／今天 HH:mm／M/D
  String _whenOf(Map<String, dynamic> j) {
    final raw = j['savedAt'];
    if (raw is! String) return '';
    final t = DateTime.tryParse(raw);
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '剛剛';
    if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
    if (d.inHours < 24) return '${d.inHours} 小時前';
    if (d.inDays == 1) return '昨天';
    return '${t.month}/${t.day}';
  }

  // ── 區塊標題：一行大粗字，右邊放次要資訊 ────────────────────
  Widget _sectionTitle(String title, {String? trailing, VoidCallback? onTap}) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                height: 1.1,
              ),
            ),
          ),
          if (trailing != null)
            GestureDetector(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 3, left: 12),
                child: Text(
                  trailing,
                  style: const TextStyle(fontSize: 12.5, color: kLTextDim),
                ),
              ),
            ),
        ],
      );

  /// 範本磚：深色方塊，裡面就是這組浮水印長什麼樣。
  /// 用真的 WatermarkLayer 照實渲染（多文字、多圖、平鋪全都畫）——
  /// 以前只挑第一張圖或第一行字當代表，跟實際內容對不上
  Widget _presetTile(WatermarkPreset preset) {
    return GestureDetector(
      // 點磚＝直接編輯那一組（以前是跳到範本夾，還要再找一次）；
      // 長按＝刪除。右上角「全部」才是進範本夾
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => WatermarkStudioScreen(edit: preset)),
      ).then((_) => _reload()),
      onLongPress: () => _confirmDeletePreset(preset),
      child: Column(
        children: [
          Container(
            width: 92,
            height: 92,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B20),
              borderRadius: BorderRadius.circular(20),
            ),
            child: IgnorePointer(
              child: WatermarkLayer(
                settings: preset.settings,
                onChanged: () {},
              ),
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: 92,
            child: Text(
              preset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6E6E7A),
              ),
            ),
          ),
        ],
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

  /// 範本區最後一格：新增
  Widget _presetAddTile() => GestureDetector(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LightPage(child: PresetsScreen()),
      ),
    ).then((_) => _reload()),
    child: Column(
      children: [
        Container(
          width: 92,
          height: 92,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: kLCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kLBorder, width: 1.4),
          ),
          child: const Text(
            '＋',
            style: TextStyle(
              fontSize: 26,
              color: Color(0xFFB0B0BA),
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
        const SizedBox(height: 7),
        const SizedBox(
          width: 92,
          child: Text(
            '新增',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6E6E7A),
            ),
          ),
        ),
      ],
    ),
  );

  /// 草稿卡：長條的。上面一塊方形縮圖區（直式影片置中留邊，橫式也放得下），
  /// 下面名稱與時間——加起來整張是直的，直片橫片排在一起高度才一致
  /// 草稿：縮圖本身就是卡（滿版、圓角），文字放在卡片外面。
  ///
  /// 本來是「白卡包著一塊灰底、灰底裡再放縮圖」——兩層框、三種底色，
  /// 而畫面上真正有資訊的只有縮圖。拿掉外框之後縮圖可以直接鋪滿，
  /// 也就是相簿、專案列表那種長相
  Widget _draftTile({
    required Widget cover,
    required String title,
    required String when,
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
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: cover,
          ),
        ),
        const SizedBox(height: 9),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(when, style: const TextStyle(fontSize: 11.5, color: kLTextDim)),
      ],
    ),
  );

  Future<void> _openDrafts() async {
    await Navigator.push(
      context,
      // LightPage 一定要包：這是亮色頁，漏包就掉進暗色主題
      //（背景變黑、白卡片浮在上面，超跳）
      MaterialPageRoute(builder: (_) => const LightPage(child: DraftsScreen())),
    );
    _reload();
  }

  void _openLove() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LightPage(child: DonateScreen())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = _videoDraft;
    final p = _photoDraft;
    final draftCount = (v == null ? 0 : 1) + (p == null ? 0 : 1);
    // 非編輯頁面全頁都能右滑返回（編輯畫面橫向手勢太多，刻意不放）
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kLBg,
        appBar: AppBar(backgroundColor: kLBg),
        body: SafeArea(
          top: false,
          // 左右留白改由各段自己給：範本那排要滿版出血（捲出畫面外），
          // 外層一留白它就被切在邊上，看起來像少畫了一格
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 上面可以捲，下面的行動鈕釘在底：草稿再多也不會把它推走
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: _side,
                          child: _sectionTitle(
                            '範本',
                            trailing: _presets.isEmpty
                                ? '還沒有'
                                : '${_presets.length} 個',
                          ),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 122,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            // 內距放在清單裡：第一格跟標題對齊，
                            // 最後一格可以捲到畫面外
                            padding: _side,
                            itemCount: _presets.length + 1,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, i) => i < _presets.length
                                ? _presetTile(_presets[i])
                                : _presetAddTile(),
                          ),
                        ),
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
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (v != null)
                                  Expanded(
                                    child: _draftTile(
                                      cover: _thumbOf(v) != null
                                          ? Image.memory(
                                              _thumbOf(v)!,
                                              // 鋪滿：這是縮圖不是預覽，
                                              // 留邊只會讓一排卡看起來破碎
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
                                      title: '未完成的影片',
                                      when: _whenOf(v),
                                      onTap: _openDrafts,
                                    ),
                                  ),
                                if (v != null && p != null)
                                  const SizedBox(width: 12),
                                if (p != null)
                                  Expanded(
                                    child: _draftTile(
                                      // 照片草稿沒有存縮圖（那張照片還在裝置
                                      // 上，再存一份只是浪費空間）
                                      cover: const Icon(
                                        Icons.image_outlined,
                                        size: 26,
                                        color: Color(0xFFAFAFBB),
                                      ),
                                      title: '未完成的照片',
                                      when: _whenOf(p),
                                      onTap: _openDrafts,
                                    ),
                                  ),
                                // 只有一張時右邊補空，卡片才不會被撐成整排寬
                                if (v == null || p == null) ...[
                                  const SizedBox(width: 12),
                                  const Expanded(child: SizedBox()),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 首頁那顆主行動鈕的長相
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
                        style: TextStyle(fontSize: 12.5, color: kLTextDim),
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
                          builder: (_) => const LightPage(child: AboutScreen()),
                        ),
                      ),
                      child: const Text(
                        '關於這個 App',
                        style: TextStyle(fontSize: 12.5, color: kLTextDim),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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
  bool _loading = true;

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
    if (mounted) {
      setState(() {
        _drafts = found;
        _photoDraft = photo;
        _loading = false;
      });
    }
  }

  Future<void> _resumePhoto() async {
    final d = _photoDraft;
    if (d == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
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
    VoidCallback? onRename,
  }) {
    return Container(
      decoration: lightCard(radius: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        // 長按改名：跟範本夾同一個手勢
        onLongPress: onRename,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kLTile,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: cover,
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
              if (onRename != null)
                IconButton(
                  tooltip: '改名',
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: kLTextDim,
                  ),
                  onPressed: onRename,
                ),
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

  /// 草稿清單那筆的縮圖（壞掉的 base64 不能在 build 裡丟例外）
  Uint8List? _thumbBytes(DraftMeta m) {
    final t = m.thumb;
    if (t == null) return null;
    try {
      return base64Decode(t);
    } catch (_) {
      return null;
    }
  }

  /// 副標：存檔時間＋幾段素材
  String _metaLabel(DraftMeta m) {
    final t = m.savedAt;
    final when =
        '${t.month}/${t.day} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return m.clipCount > 0 ? '$when · ${m.clipCount} 段' : when;
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
      MaterialPageRoute(
        builder: (_) =>
            VideoEditorScreen(draft: data, draftId: m.id, draftName: m.name),
      ),
    );
    _reload();
  }

  Future<void> _rename(DraftMeta m) async {
    final ctrl = TextEditingController(text: m.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('專案改名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(counterText: ''),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name == m.name) return;
    await DraftStore.rename(m.id, name);
    _reload();
  }

  Future<void> _delete(DraftMeta m) async {
    final ok = await showConfirm(
      context,
      title: '刪除「${m.name}」？',
      message: '未完成的專案會被移除，無法復原',
      action: '刪除',
    );
    if (ok) {
      await DraftStore.remove(m.id);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = _drafts;
    final p = _photoDraft;
    final empty = ds.isEmpty && p == null;
    return SwipeBack(
      child: Scaffold(
        appBar: AppBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : empty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '沒有草稿。\n\n編輯到一半離開時選「保留草稿」，'
                    '就會存在這裡。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kLTextDim, height: 1.6),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final m in ds) ...[
                    _draftCard(
                      // 縮圖裁進固定的方框。以前框寬會跟著影片比例跑
                      //（直片 30、橫片 92），兩張卡的文字起點就對不齊
                      cover: _thumbBytes(m) != null
                          ? Image.memory(
                              _thumbBytes(m)!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            )
                          : const Icon(
                              Icons.movie_outlined,
                              size: 20,
                              color: kLAccent,
                            ),
                      title: m.name,
                      subtitle: _metaLabel(m),
                      onTap: () => _resume(m),
                      onDelete: () => _delete(m),
                      onRename: () => _rename(m),
                    ),
                    const SizedBox(height: 12),
                  ],
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
                ],
              ),
      ),
    );
  }
}
