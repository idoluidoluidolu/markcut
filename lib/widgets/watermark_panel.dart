import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/watermark_settings.dart';
import '../services/preset_store.dart';
import '../screens/crop_screen.dart';
import '../screens/draw_screen.dart';
import '../theme.dart';
import 'watermark_layer.dart';

/// 父層注入的額外區塊。置頂導覽列要列出它，所以不能只給 Widget——
/// 名稱和圖示也要一起帶進來
typedef WmExtraSection = ({String label, IconData icon, Widget child});

/// 導覽列上的一格
/// 導覽列的一格。[key] 是要捲過去的區塊；[action] 有值時是「按了就做事」
/// 而不是捲動（範本那格會直接開挑選視窗）
typedef _NavItem = ({
  String label,
  IconData icon,
  GlobalKey? key,
  VoidCallback? action,
});

/// 讓父層叫面板捲到某個設定區塊：點畫面上的浮水印文字，
/// 下面的面板就自動捲到「文字」那張卡。
///
/// 用 controller 而不是 GlobalKey——面板的 key 會跟著編輯目標換
/// （影片編輯器切換浮水印素材時），State 會整個重建，
/// 拿不到穩定的 GlobalKey。請求存在 controller 裡，
/// 新的 State 一掛上就自己來取
class WatermarkPanelController extends ChangeNotifier {
  WmPart? _pending;
  int? _pendingSection;

  /// 面板目前捲到第幾區（父層自己畫導覽列時拿來高亮）
  int activeSection = 0;

  /// 面板取走待處理的請求（取走就清掉，不會重複捲）
  WmPart? takePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  int? takePendingSection() {
    final i = _pendingSection;
    _pendingSection = null;
    return i;
  }

  /// 要求捲到 [part] 的設定區塊
  void scrollTo(WmPart part) {
    if (part == WmPart.none) return;
    _pending = part;
    notifyListeners();
  }

  /// 要求捲到第 [i] 區（父層的導覽列按下去時用）
  void jumpToSection(int i) {
    _pendingSection = i;
    notifyListeners();
  }

  /// 面板回報捲到哪一區了
  void reportSection(int i) {
    if (i == activeSection) return;
    activeSection = i;
    notifyListeners();
  }
}

/// 浮水印編輯面板：文字、Logo、範本管理
class WatermarkPanel extends StatefulWidget {
  final WatermarkSettings settings;
  final VoidCallback onChanged;

  /// 每次修改前呼叫（父層拿來拍「上一步」快照）
  final VoidCallback? onBeforeChange;

  /// 顯示動畫選項（只有影片相關的畫面才有意義；照片輸出忽略動畫）
  final bool showAnimation;

  /// 父層做完復原後 +1，通知面板把輸入框等內部狀態對回 settings
  final int syncVersion;

  /// 一進來就當作在編輯這個範本（儲存鈕預選它）
  final String? initialPresetName;

  /// 存成範本後通知父層（重設「有沒有改過」的基準，離開才不會問放棄）
  final VoidCallback? onSaved;

  /// 剛挑好一張圖片當 Logo：父層把選取設到 Logo 上，
  /// 使用者回到畫面就能直接拖曳／縮放它
  final VoidCallback? onLogoAdded;

  /// 「加 GIF」的入口。給了才會在導覽列出現那一格——GIF 一定要當
  /// 時間軸素材才會動（浮水印是烘成一張靜態 PNG 的），所以真正
  /// 怎麼加是由影片編輯器決定，面板只負責把入口擺出來
  final VoidCallback? onAddGif;

  /// 隱藏面板內的「儲存範本」鈕（父層自己在底部放）
  final bool hideSaveButton;

  /// 額外區塊：插在「圖片」卡片之後、「儲存範本」之前，
  /// 一個區塊包成一張卡。照片編輯器拿來放「馬賽克」與「更多浮水印」
  final List<WmExtraSection> extraSections;

  /// 接在「文字」那一區後面的額外卡片。
  ///
  /// 面板是分頁的（一次只建目前那一區），所以沒有自己那一格導覽的
  /// 東西根本進不去——照片編輯的「更多浮水印」就掛在這裡，
  /// 跟主浮水印同一頁，不必為它多佔一格
  final Widget? textSectionExtra;

  /// 父層用它叫面板捲到文字／圖片區塊
  final WatermarkPanelController? controller;

  /// 面板自己畫置頂導覽列。父層想自己畫（例如照片編輯要把「調色」
  /// 也排進同一列）就傳 false
  final bool showNav;

  /// 清單底部多留的空間：父層在上面浮了東西（例如輸出鍵）時，
  /// 最後一張卡才捲得到浮鍵上方
  final double bottomInset;

  /// 位置九宮格的最大寬。影片編輯的面板矮，太大會佔掉大半；
  /// 照片編輯的面板高，太小旁邊又空一大片——由父層自己給
  final double posGridCap;

  const WatermarkPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onBeforeChange,
    this.showAnimation = false,
    this.syncVersion = 0,
    this.initialPresetName,
    this.onSaved,
    this.onLogoAdded,
    this.onAddGif,
    this.hideSaveButton = false,
    this.extraSections = const [],
    this.textSectionExtra,
    this.controller,
    this.showNav = true,
    this.bottomInset = 0,
    this.posGridCap = 210,
  });

  @override
  State<WatermarkPanel> createState() => WatermarkPanelState();
}

class WatermarkPanelState extends State<WatermarkPanel> {
  /// 父層（例如照片編輯器把儲存鈕放在底部）可以呼叫這個開儲存流程
  Future<void> savePreset() => _savePreset();

  late final TextEditingController _textCtrl;

  /// 文字輸入框的焦點（收起鍵盤鈕看它決定要不要出現）
  final FocusNode _textFocus = FocusNode();

  WatermarkSettings get s => widget.settings;

  List<WatermarkPreset> _presets = [];
  String? _presetSel; // 選單目前顯示的範本名

  // 開滿版平鋪之前的大小。平鋪是「整面鋪滿的防盜浮水印」，尺寸一大
  // 就變成幾塊巨字蓋住整支影片——所以一開就自動縮到最小。關掉時把
  // 原本的大小還回去，不然使用者只是想看一下就得自己重調
  double? _sizeBeforeTileText;
  double? _sizeBeforeTileLogo;

  /// 大小滑桿的下限（跟 _sliderRow 給的值一致）
  static const double _minTextSize = 0.015;
  static const double _minLogoSize = 0.05;

  void _setTiled({required bool isLogo, required bool on}) {
    // 文字跟圖片是不同型別，共用一個變數會退化成 Object，只好分開寫
    _update(() {
      if (isLogo) {
        if (on) {
          _sizeBeforeTileLogo = s.logo.sizeFrac;
          s.logo.sizeFrac = _minLogoSize;
        } else if (_sizeBeforeTileLogo != null) {
          s.logo.sizeFrac = _sizeBeforeTileLogo!;
        }
        s.logo.tiled = on;
      } else {
        if (on) {
          _sizeBeforeTileText = s.text.sizeFrac;
          s.text.sizeFrac = _minTextSize;
        } else if (_sizeBeforeTileText != null) {
          s.text.sizeFrac = _sizeBeforeTileText!;
        }
        s.text.tiled = on;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: s.text.text);
    _presetSel = widget.initialPresetName;
    _loadPresets();
    widget.controller?.addListener(_onScrollRequest);
    // 請求可能在這個 State 出生之前就發出了（點浮水印的同時
    // 才切到浮水印分頁／才換編輯目標），一掛上就先看有沒有待辦
    _onScrollRequest();
    // 分頁模式：面板被收掉重掛（放大預覽進出、切去調色再回來）要
    // 接手上一個 State 停留的分頁，不能把人踢回「位置」。上一輪的
    // 分頁記在 controller（它活在父層，State 重建也還在）；沒有前科
    // 才用預設的「位置」。索引失效（那一格被收掉）由 build 的守門
    // 退回位置
    final keep = widget.controller?.activeSection ?? 0;
    if (keep > 0) _navAt = keep;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller?.reportSection(_navAt);
    });
  }

  Future<void> _loadPresets() async {
    final p = await PresetStore.load();
    if (mounted) setState(() => _presets = p);
  }

  void _applyPresetNow(WatermarkPreset p) {
    _update(() {
      s.copyMarksFrom(p.settings.copy());
      // 馬賽克不進範本也不被範本動到：套範本只換浮水印，
      // 照片上已經畫好的碼留在原地
      _textCtrl.text = s.text.text;
      _presetSel = p.name;
    });
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onScrollRequest);
    _textCtrl.dispose();
    _textFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 父層要求捲到某個區塊
  void _onScrollRequest() {
    final part = widget.controller?.takePending();
    if (part != null) _ensureSection(part, 0);
    final sec = widget.controller?.takePendingSection();
    if (sec != null && sec >= 0 && sec < _nav.length) {
      // 面板可能是這一刻才掛上來的（從調色切回來），等一幀再捲
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && sec < _nav.length) _jumpToSection(sec);
      });
    }
  }

  /// 切到 [part] 對應的分頁（點畫面上的文字／圖片時面板跟著跳）
  void _ensureSection(WmPart part, int tries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _nav.isEmpty) return;
      final key = part == WmPart.logo ? _logoCardKey : _textCardKey;
      final idx = _nav.indexWhere((n) => n.key == key);
      if (idx > 0) _jumpToSection(idx);
    });
  }

  /// 滑桿拖曳中：復原快照只在按下去那一刻拍一次。
  ///
  /// 之前每一格變動都拍——那是整份設定的深拷貝，一秒六十次，
  /// 加上每次都重建整個預覽，畫面追不上手指；放開時滑桿跳回真值，
  /// 看起來就是「飄動」。順帶讓復原變成一拖一步，而不是一格一步
  bool _sliderDragging = false;

  void _update(VoidCallback fn) {
    if (!_sliderDragging) widget.onBeforeChange?.call();
    setState(fn);
    widget.onChanged();
  }

  void _sliderStart() {
    widget.onBeforeChange?.call();
    _sliderDragging = true;
  }

  void _sliderEnd() => _sliderDragging = false;

  @override
  void didUpdateWidget(WatermarkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?.removeListener(_onScrollRequest);
      widget.controller?.addListener(_onScrollRequest);
    }
    if (widget.syncVersion != oldWidget.syncVersion) {
      // 父層剛做了復原：把輸入框文字對回 settings
      _textCtrl.text = s.text.text;
      _presetSel = null;
      setState(() {});
    }
  }

  /// 這一組浮水印有沒有任何一張圖片
  bool get _hasLogos => s.logos.any((l) => l.b64 != null);

  /// 加一張圖片。清單裡還有空位（剛開的那張、或圖片被移除留下的）
  /// 就先填它，不然新增一張再挑；挑到一半取消就把空的那張收回去，
  /// 縮圖列才不會留一格永遠空白的
  Future<void> _addLogo() => _addInto(_pickLogo);

  /// 手繪：畫一張進來。跟 _addLogo 同一套「填空位／取消收回」的流程，
  /// 只是圖的來源從相簿換成畫板
  Future<void> _addDrawing() => _addInto(_pickDrawing);

  Future<void> _addInto(Future<void> Function() fill) async {
    final empty = s.logos.indexWhere((l) => l.b64 == null);
    if (empty >= 0) {
      setState(() => s.activeLogo = empty);
      await fill();
      return;
    }
    _update(s.addLogo);
    await fill();
    if (!mounted) return;
    if (s.logo.b64 == null) _update(() => s.removeLogo(s.activeLogo));
  }

  Future<void> _pickDrawing() async {
    final res = await drawWatermark(context);
    if (res == null || !mounted) return;
    _update(() {
      s.logo.bytesValue = res.png;
      // 手繪的「原圖」就是它自己：之後按裁切從完整的畫作開始裁
      s.logo.origBytes = res.png;
      s.logo.enabled = true;
      s.logo.drawn = true; // 之後「編輯」看這個旗標
      s.logo.drawData = res.data; // 筆畫資料：編輯時還原成活的
      // 選了手繪＝主角是那張畫，預設的「@浮水印」文字先關掉——
      // 幾乎沒有人要兩個一起出現，要的話再自己打開
      s.text.enabled = false;
    });
    widget.onLogoAdded?.call();
    // 畫完回來直接站在「圖片」分頁：剛畫好的那張已是操作中，
    // 大小、透明度、平鋪馬上調得到，不用自己找去哪了
    _ensureSection(WmPart.logo, 0);
  }

  /// 手繪的圖再編輯：有筆畫資料就還原成活的筆畫（上一步、
  /// 調粗細全部可用）；舊資料只有 PNG 就鋪底圖繼續畫
  Future<void> _editDrawing() async {
    final cur = s.logo.bytes;
    if (cur == null) return;
    final res = await drawWatermark(
      context,
      initialData: s.logo.drawData,
      initial: cur,
    );
    if (res == null || !mounted) return;
    _update(() {
      s.logo.bytesValue = res.png;
      s.logo.origBytes = res.png;
      s.logo.drawData = res.data;
    });
  }

  Future<void> _pickLogo() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final raw = await picked.readAsBytes();
      // 先給裁切：浮水印的圖常常是從截圖或大圖裡挖一塊出來用，
      // 挑完直接進裁切畫面比「加進去再想辦法縮」直覺得多。
      // 按取消就整個不加（跟以前挑完取消一樣）
      if (!mounted) return;
      final cut = await cropImage(context, raw);
      if (cut == null) return;
      // 縮到 1024px 內再存進設定，範本自帶圖檔不佔太多空間
      final shrunk = await _shrinkToPng(cut, 1024);
      // 原圖也留一份（同樣縮過）：之後要還原、重新裁都靠它
      final orig = await _shrinkToPng(raw, 1024);
      // 選圖期間畫面可能已經被收掉（挑很久、系統回收）
      if (!mounted || shrunk == null) {
        if (mounted) showHint(context, '這張圖讀不進來，換一張試試', error: true);
        return;
      }
      _update(() {
        s.logo.bytesValue = shrunk;
        s.logo.origBytes = orig;
        s.logo.enabled = true;
      });
      // 剛加進來的圖片直接設成選取：使用者接著一定是要移動／縮放它，
      // 不用再回畫面上找它點一下
      widget.onLogoAdded?.call();
    } catch (_) {
      if (mounted) showHint(context, '這張圖讀不進來，換一張試試', error: true);
    }
  }

  /// 重新裁切現在這張圖。有原圖就從原圖裁——不然裁小了之後只能在
  /// 那一小塊裡面繼續裁，越裁越小回不去
  Future<void> _cropLogo() async {
    final src = s.logo.origBytes ?? s.logo.bytes;
    if (src == null) return;
    final cut = await cropImage(context, src);
    if (cut == null || !mounted) return;
    final shrunk = await _shrinkToPng(cut, 1024);
    if (!mounted || shrunk == null) return;
    _update(() {
      // 第一次裁的人可能是從舊草稿讀回來的（沒有原圖），
      // 這時把「裁之前的樣子」記起來當原圖
      s.logo.origBytes ??= src;
      s.logo.bytesValue = shrunk;
    });
  }

  static Future<Uint8List?> _shrinkToPng(Uint8List raw, int maxSide) async {
    var codec = await ui.instantiateImageCodec(raw);
    var frame = await codec.getNextFrame();
    // 長邊超標就縮（只看寬的話 500×8000 的長圖會整張存進範本，
    // web 的 localStorage 5MB 配額直接爆）
    final w = frame.image.width;
    final h = frame.image.height;
    if (math.max(w, h) > maxSide) {
      frame.image.dispose();
      codec = await ui.instantiateImageCodec(
        raw,
        targetWidth: w >= h ? maxSide : null,
        targetHeight: h > w ? maxSide : null,
      );
      frame = await codec.getNextFrame();
    }
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    return data?.buffer.asUint8List(); // 特殊格式編不出 PNG 就回 null
  }

  /// 通用顏色挑選：文字、描邊、底色共用
  Future<void> _pickColorFor(
    Color initial,
    void Function(int argb) apply,
  ) async {
    final v = await pickColor(context, initial);
    if (v != null) _update(() => apply(v));
  }

  Future<void> _pickColor() =>
      _pickColorFor(s.text.color, (v) => s.text.colorValue = v);

  /// 縮排的顏色小圓點列（描邊/底色的微調用）
  Widget _colorDotRow(String label, Color color, void Function(int) apply) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: kTextDim)),
            const Spacer(),
            InkWell(
              onTap: () => _pickColorFor(color, apply),
              borderRadius: BorderRadius.circular(11),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: kBorder, width: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _savePreset() async {
    // 有選中的範本就預填它的名字：直接儲存＝更新該範本，改名＝另存新的
    final nameCtrl = TextEditingController(text: _presetSel ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('儲存為常用範本'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '範本名稱，例如「我的頻道」'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameCtrl.text.trim()),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty) return;
    final existed = _presets.any((p) => p.name == name);
    try {
      // 範本不收馬賽克：每張照片內容不同，同位置的碼帶著走沒有意義
      await PresetStore.add(
        WatermarkPreset(name: name, settings: s.copy()..mosaics.clear()),
      );
    } catch (_) {
      // web 的 localStorage 有 5MB 配額，Logo 太大會存不進去——
      // 要讓使用者知道沒存成，不能無聲 crash
      if (mounted) {
        showHint(context, '存不下去（範本空間滿了），把 Logo 換小一點試試', error: true);
      }
      return;
    }
    _presetSel = name;
    await _loadPresets();
    widget.onSaved?.call(); // 父層拿去重設「有沒有改過」的基準
    if (mounted) {
      showHint(context, existed ? '已更新範本「$name」' : '已儲存範本「$name」');
    }
  }

  /// 動畫卡的位置：選了動畫後自動捲過去，讓微調滑桿露臉
  final _animCardKey = GlobalKey();

  /// 文字／圖片卡的位置：點畫面上的浮水印時捲過去
  final _textCardKey = GlobalKey();
  final _logoCardKey = GlobalKey();
  final _posCardKey = GlobalKey();
  final List<GlobalKey> _extraKeys = [];
  final _scroll = ScrollController();

  /// 導覽列目前高亮第幾格
  /// 分頁模式：一格導覽＝一區功能，點哪格就只顯示那一區。
  /// 預設停在「位置」（第 0 格「範本」是動作不是區塊）
  int _navAt = 1;

  /// 這一輪畫出來的導覽項目
  List<_NavItem> _nav = const [];

  void _setNav(int idx) {
    if (idx != _navAt && mounted) setState(() => _navAt = idx);
    // 一定要回報：父層自己畫導覽列時（照片編輯）高亮是看這個值，
    // 只更新面板內部的 _navAt 外面不會亮
    widget.controller?.reportSection(idx);
  }

  void _jumpToSection(int i) {
    final action = _nav[i].action;
    if (action != null) {
      action();
      return;
    }
    _setNav(i);
    // 換分頁回到頂端：每一區都不長，殘留的捲動位置只會讓人以為內容缺一半
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 置頂導覽列：圖示＋文字，跟 App 其他工具列同一種長相
  Widget _sectionNav() => Container(
    color: kPanel,
    padding: const EdgeInsets.fromLTRB(8, 3, 8, 5),
    child: Row(
      children: [
        for (var i = 0; i < _nav.length; i++)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _jumpToSection(i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 5),
                // 選中不畫框（試過線框，太搶）：圖示＋文字直接轉琥珀
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _nav[i].icon,
                      size: 17,
                      color: i == _navAt ? kSelect : kTextDim,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _nav[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: i == _navAt ? kSelect : kTextDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    // 每一輪重算導覽項目：不同畫面的區塊本來就不一樣
    //（影片多動畫、照片多馬賽克與更多浮水印）
    while (_extraKeys.length < widget.extraSections.length) {
      _extraKeys.add(GlobalKey());
    }
    _nav = [
      // 範本擺第一格：套範本是「先挑一個再開始調」的動作，位置在最前面
      // 才對得上順序。按了直接開挑選視窗，不是捲到某一區
      (
        label: '範本',
        icon: Icons.bookmarks_outlined,
        key: null,
        action: _openPresetPicker,
      ),
      (label: '位置', icon: Icons.grid_view, key: _posCardKey, action: null),
      if (widget.showAnimation)
        (
          label: '動畫',
          icon: Icons.auto_awesome,
          key: _animCardKey,
          action: null,
        ),
      (label: '文字', icon: Icons.title, key: _textCardKey, action: null),
      (
        label: '圖片',
        icon: Icons.image_outlined,
        key: _logoCardKey,
        action: null,
      ),
      if (widget.showNav && widget.onAddGif != null)
        (
          label: 'GIF',
          icon: Icons.gif_box_outlined,
          key: null,
          action: widget.onAddGif!,
        ),
      if (widget.showNav)
        (
          label: '手繪',
          icon: Icons.draw_outlined,
          key: null,
          action: _addDrawing,
        ),
      for (var i = 0; i < widget.extraSections.length; i++)
        (
          label: widget.extraSections[i].label,
          icon: widget.extraSections[i].icon,
          key: _extraKeys[i],
          action: null,
        ),
    ];
    // 導覽項目可能隨畫面狀態增減（照片編輯的額外區塊），
    // 停留的分頁被收掉就退回「位置」
    if (_navAt >= _nav.length || _nav[_navAt].key == null) _navAt = 1;
    if (!widget.showNav) return _list();
    return Column(
      children: [
        _sectionNav(),
        Expanded(child: _list()),
      ],
    );
  }

  /// 這一區在目前的分頁該不該出現
  bool _on(GlobalKey key) => _nav[_navAt].key == key;

  Widget _list() {
    return LayoutBuilder(
      builder: (context, cons) => SingleChildScrollView(
        controller: _scroll,
        // 往下滑清單就收鍵盤（打完字回不去的解法）
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + widget.bottomInset),
        child: ConstrainedBox(
          // 內容不滿一頁：撐到剛好一頁高，儲存鈕被 spaceBetween 推到
          // 右下角固定；內容超過一頁：恢復排在最後、跟著捲（不釘死）
          constraints: BoxConstraints(
            minHeight: math.max(0, cons.maxHeight - 32 - widget.bottomInset),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 只有「位置」分頁置中：它內容短，貼頂時下面一大片空。
              // 開頭放一個空元素，spaceBetween 就會把它擺到導覽列與
              // 儲存鈕的正中間；其他分頁照舊從上排、大小不變
              if (_on(_posCardKey)) const SizedBox.shrink(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 「選擇範本」按鈕拿掉了：導覽列第一格「範本」就是它，
                  // 面板裡再放一顆只是把每一區往下擠

                  // ===== 卡片 1：位置 =====
                  if (_on(_posCardKey))
                    KeyedSubtree(key: _posCardKey, child: _card(_bigPosGrid())),

                  // ===== 動畫（影片專用）=====
                  if (widget.showAnimation && _on(_animCardKey))
                    KeyedSubtree(
                      key: _animCardKey,
                      child: _card(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '動畫',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: kText,
                              ),
                            ),
                            const SizedBox(height: 8),
                            GridView.count(
                              crossAxisCount: 4,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
                              childAspectRatio: 2.2,
                              children: [
                                for (final a in WmAnimation.values)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () {
                                      _update(() => s.animation = a);
                                      // 微調滑桿在下面才展開：自動捲過去，
                                      // 暗示使用者有這些選項能調
                                      if (a != WmAnimation.none) {
                                        WidgetsBinding.instance
                                            .addPostFrameCallback((_) {
                                              final ctx =
                                                  _animCardKey.currentContext;
                                              if (ctx != null) {
                                                Scrollable.ensureVisible(
                                                  ctx,
                                                  duration: const Duration(
                                                    milliseconds: 350,
                                                  ),
                                                  curve: Curves.easeOutCubic,
                                                  alignment: 0.05,
                                                );
                                              }
                                            });
                                      }
                                    },
                                    child: Container(
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: s.animation == a
                                            ? kPanelHi
                                            : Colors.transparent,
                                        border: Border.all(
                                          color: kClipBorder,
                                          width: 1,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      // 選取的粗框畫在前景，字不位移
                                      foregroundDecoration: s.animation == a
                                          ? BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: kSelect,
                                                width: 1.5,
                                              ),
                                            )
                                          : null,
                                      child: Text(
                                        a.label,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          height: 1.2,
                                          fontWeight: s.animation == a
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                          color: s.animation == a
                                              ? kSelect
                                              : kText,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.animation.note,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: kTextDim,
                              ),
                            ),
                            // 微調：速度／幅度（標籤跟著模式改，右邊顯示實際數值）
                            if (s.animation != WmAnimation.none) ...[
                              const SizedBox(height: 4),
                              _animSlider(
                                s.animation == WmAnimation.blink ? '頻率' : '速度',
                                s.animSpeed,
                                s.animation == WmAnimation.blink
                                    ? '${s.blinkCycle.toStringAsFixed(1)} 秒一次'
                                    : s.animation == WmAnimation.marquee
                                    ? '${s.marqueeCycle.toStringAsFixed(1)} 秒一輪'
                                    : '${s.animSpeed.toStringAsFixed(1)}x',
                                (v) => _update(() => s.animSpeed = v),
                              ),
                              if (s.animation != WmAnimation.marquee)
                                _animSlider(
                                  s.animation == WmAnimation.blink
                                      ? '一次亮多久'
                                      : '幅度',
                                  s.animRange,
                                  s.animation == WmAnimation.blink
                                      ? '亮 ${s.blinkOn.toStringAsFixed(1)} 秒'
                                      : '${(s.animRange * 2).toStringAsFixed(0)}%',
                                  (v) => _update(() => s.animRange = v),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // ===== 卡片 2：文字 =====
                  if (_on(_textCardKey))
                    KeyedSubtree(
                      key: _textCardKey,
                      child: _card(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 標頭：標題＋「再加一個」＋（多個時）刪除＋這一個的開關。
                            // 文字跟圖片同一套：可以放很多個，設定調的是「亮框那一個」
                            Row(
                              children: [
                                const Text(
                                  '文字',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: kText,
                                  ),
                                ),
                                const Spacer(),
                                if (s.texts.length > 1)
                                  IconButton(
                                    tooltip: '移除這一個',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      _update(() => s.removeText(s.activeText));
                                      _textCtrl.text = s.text.text;
                                    },
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 19,
                                      color: kTextDim,
                                    ),
                                  ),
                                IconButton(
                                  tooltip: '再加一個文字',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    _update(() => s.addText());
                                    _textCtrl.text = s.text.text;
                                  },
                                  icon: const Icon(
                                    Icons.add,
                                    size: 20,
                                    color: kIcon,
                                  ),
                                ),
                                Switch(
                                  value: s.text.enabled,
                                  onChanged: (v) =>
                                      _update(() => s.text.enabled = v),
                                ),
                              ],
                            ),
                            if (s.texts.length > 1) ...[
                              const SizedBox(height: 4),
                              // 選取列：底下整組設定調的都是亮框的那一個
                              SizedBox(
                                height: 34,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: s.texts.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 6),
                                  itemBuilder: (context, i) {
                                    final t = s.texts[i];
                                    final on = i == s.activeText;
                                    final label = t.text.trim().isEmpty
                                        ? '（空）'
                                        : t.text.trim();
                                    return InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      // 切換要調哪一個，不算改動內容——不拍上一步快照
                                      onTap: () {
                                        setState(() {
                                          s.activeText = i;
                                          _textCtrl.text = s.text.text;
                                        });
                                        widget.onChanged();
                                      },
                                      child: Container(
                                        constraints: const BoxConstraints(
                                          maxWidth: 120,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(color: kBorder),
                                        ),
                                        foregroundDecoration: on
                                            ? BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                border: Border.all(
                                                  color: kSelect,
                                                  width: 1.5,
                                                ),
                                              )
                                            : null,
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            // 關掉的那個淡一點，看得出它現在不會出現在畫面上
                                            color: t.enabled ? kText : kTextDim,
                                            fontWeight: on
                                                ? FontWeight.w700
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                            if (s.text.enabled) ...[
                              const SizedBox(height: 6),
                              // ===== 大輸入框：用目前字型與顏色顯示，打字即預覽 =====
                              // 疊一顆「收起鍵盤」鈕在右上角：多行輸入的換行鍵不能當完成鍵，
                              // 打完字原本沒有地方可以把鍵盤收掉（使用者實測回報）
                              Stack(
                                children: [
                                  Container(
                                    constraints: const BoxConstraints(
                                      minHeight: 110,
                                    ),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F0F11),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: kClipBorder,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: TextField(
                                      controller: _textCtrl,
                                      focusNode: _textFocus,
                                      textAlign: TextAlign.center,
                                      maxLines: null,
                                      // 打字永遠白字（B 案）：這一格只管
                                      // 打字，顏色與透明看上面的預覽跟
                                      // 旁邊的色塊——照所選顏色渲染的話
                                      // 深色字會沉進黑底裡看不見。
                                      // 字型照選的渲染，字型是要在這裡挑的
                                      style: TextStyle(
                                        fontFamily: s.text.fontFamily,
                                        fontSize: 26,
                                        color: kText,
                                      ),
                                      decoration: const InputDecoration(
                                        hintText: '浮水印文字',
                                        hintStyle: TextStyle(
                                          color: kTextDim,
                                          fontSize: 16,
                                          fontFamily: 'NotoSansTC',
                                        ),
                                        filled: false,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 20,
                                        ),
                                      ),
                                      onChanged: (v) =>
                                          _update(() => s.text.text = v),
                                    ),
                                  ),
                                  Positioned(
                                    right: 2,
                                    top: 2,
                                    child: AnimatedBuilder(
                                      animation: _textFocus,
                                      builder: (context, _) =>
                                          _textFocus.hasFocus
                                          ? IconButton(
                                              tooltip: '收起鍵盤',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () =>
                                                  _textFocus.unfocus(),
                                              icon: const Icon(
                                                Icons.keyboard_hide_outlined,
                                                size: 20,
                                                color: kIcon,
                                              ),
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonHideUnderline(
                                      child: Container(
                                        height: 38,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: kBorder),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: DropdownButton<String>(
                                          isExpanded: true,
                                          value: s.text.fontFamily,
                                          icon: const Icon(
                                            Icons.expand_more,
                                            size: 16,
                                            color: kTextDim,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: kText,
                                          ),
                                          // 選單跟 App 同風格：面板色、圓角、限高
                                          dropdownColor: kPanelHi,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          menuMaxHeight: 320,
                                          itemHeight: 48,
                                          items: [
                                            for (final f in kFontOptions)
                                              DropdownMenuItem(
                                                value: f.family,
                                                // 有些字型（粉圓）的行高比字級大，不夾住
                                                // 行高就會頂出格子（實測回報）
                                                child: Text(
                                                  f.label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontFamily: f.family,
                                                    fontSize: 13,
                                                    height: 1.15,
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged: (v) => _update(
                                            () => s.text.fontFamily =
                                                v ?? 'NotoSansTC',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // 跟字體下拉同款的框＋「顏色」字樣：
                                  // 裸圓點看起來像裝飾，不像可以點
                                  InkWell(
                                    onTap: _pickColor,
                                    borderRadius: BorderRadius.circular(6),
                                    child: Container(
                                      height: 38,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(color: kBorder),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 22,
                                            height: 22,
                                            decoration: BoxDecoration(
                                              color: s.text.color,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: kBorder,
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          const Text(
                                            '顏色',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: kTextDim,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              _sliderRow(
                                '大小',
                                s.text.sizeFrac,
                                0.015,
                                2.0,
                                (v) => _update(() => s.text.sizeFrac = v),
                                // 常用的是 2%~20%，線性的話全擠在軌道
                                // 最前面一小段，動一下就跳好幾倍
                                curve: 2.2,
                              ),
                              _sliderRow(
                                '透明',
                                s.text.opacity,
                                0.05,
                                1,
                                (v) => _update(() => s.text.opacity = v),
                              ),
                              _sliderRow(
                                '間距',
                                s.text.spacing,
                                0,
                                0.6,
                                (v) => _update(() => s.text.spacing = v),
                              ),
                              _rotationRow(
                                s.text.rotation,
                                (v) => _update(() => s.text.rotation = v),
                              ),
                              Row(
                                children: [
                                  const Text(
                                    '滿版平鋪',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: kTextDim,
                                    ),
                                  ),
                                  const Spacer(),
                                  _miniSwitch(
                                    s.text.tiled,
                                    (v) => _setTiled(isLogo: false, on: v),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  const Text(
                                    '陰影',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: kTextDim,
                                    ),
                                  ),
                                  const Spacer(),
                                  _miniSwitch(
                                    s.text.shadow,
                                    (v) => _update(() => s.text.shadow = v),
                                  ),
                                ],
                              ),
                              if (s.text.shadow) ...[
                                Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: _sliderRow(
                                    '濃度',
                                    s.text.shadowOpacity,
                                    0.05,
                                    1.0,
                                    (v) =>
                                        _update(() => s.text.shadowOpacity = v),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: _sliderRow(
                                    '模糊',
                                    s.text.shadowBlur,
                                    0.0,
                                    0.2,
                                    (v) => _update(() => s.text.shadowBlur = v),
                                  ),
                                ),
                              ],
                              Row(
                                children: [
                                  const Text(
                                    '描邊',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: kTextDim,
                                    ),
                                  ),
                                  const Spacer(),
                                  _miniSwitch(
                                    s.text.outline,
                                    (v) => _update(() => s.text.outline = v),
                                  ),
                                ],
                              ),
                              if (s.text.outline) ...[
                                _colorDotRow(
                                  '顏色',
                                  s.text.outlineColor,
                                  (v) => s.text.outlineColorValue = v,
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: _sliderRow(
                                    '粗度',
                                    s.text.outlineWidth,
                                    0.02,
                                    0.2,
                                    (v) =>
                                        _update(() => s.text.outlineWidth = v),
                                  ),
                                ),
                              ],
                              Row(
                                children: [
                                  const Text(
                                    '底色',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: kTextDim,
                                    ),
                                  ),
                                  const Spacer(),
                                  _miniSwitch(
                                    s.text.bg,
                                    (v) => _update(() => s.text.bg = v),
                                  ),
                                ],
                              ),
                              if (s.text.bg) ...[
                                _colorDotRow(
                                  '顏色',
                                  s.text.bgColor,
                                  (v) => s.text.bgColorValue = v,
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: _sliderRow(
                                    '透明',
                                    s.text.bgOpacity,
                                    0.1,
                                    1,
                                    (v) => _update(() => s.text.bgOpacity = v),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: _sliderRow(
                                    '大小',
                                    s.text.bgPad,
                                    0.3,
                                    2.5,
                                    (v) => _update(() => s.text.bgPad = v),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16),
                                  child: _sliderRow(
                                    '圓角',
                                    s.text.bgCorner,
                                    0,
                                    1,
                                    (v) => _update(() => s.text.bgCorner = v),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),

                  // 「更多浮水印」之類的附加卡：跟文字同一頁
                  if (_on(_textCardKey) && widget.textSectionExtra != null)
                    _card(widget.textSectionExtra!),

                  // ===== 卡片 3：圖片（可以放很多張；＋加入，點縮圖換要調哪一張）=====
                  if (_on(_logoCardKey))
                    KeyedSubtree(
                      key: _logoCardKey,
                      child: _card(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 還沒有圖片時整行都能點（不用精準戳 + 號）
                            InkWell(
                              onTap: _hasLogos ? null : _addLogo,
                              borderRadius: BorderRadius.circular(8),
                              child: Row(
                                children: [
                                  const Text(
                                    '圖片',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: kText,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    tooltip: _hasLogos ? '再加一張' : '加入圖片',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _addLogo,
                                    icon: const Icon(
                                      Icons.add,
                                      size: 20,
                                      color: kIcon,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_hasLogos) ...[
                              const SizedBox(height: 6),
                              // 縮圖列：底下的滑桿調的是「亮框的那一張」。
                              // 只有一張時也照樣顯示——加第二張之後版面才不會整個跳掉
                              SizedBox(
                                height: 46,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: s.logos.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 6),
                                  itemBuilder: (context, i) {
                                    final bytes = s.logos[i].bytes;
                                    final on = i == s.activeLogo;
                                    return InkWell(
                                      borderRadius: BorderRadius.circular(6),
                                      // 切換要調哪一張，不算改動內容——不拍上一步快照
                                      onTap: () {
                                        setState(() => s.activeLogo = i);
                                        widget.onChanged();
                                      },
                                      child: Container(
                                        width: 46,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: kBorder,
                                            width: 1,
                                          ),
                                        ),
                                        // 選取框畫在前景，縮圖不位移
                                        foregroundDecoration: on
                                            ? BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: kSelect,
                                                  width: 2,
                                                ),
                                              )
                                            : null,
                                        clipBehavior: Clip.antiAlias,
                                        child: bytes == null
                                            ? const Icon(
                                                Icons.image_outlined,
                                                size: 18,
                                                color: kTextDim,
                                              )
                                            : Opacity(
                                                // 關掉的那張淡一點，看得出它現在不會出現在畫面上
                                                opacity: s.logos[i].enabled
                                                    ? 1
                                                    : 0.35,
                                                child: Image.memory(
                                                  bytes,
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  _miniBtn(Icons.swap_horiz, '換一張', _pickLogo),
                                  const SizedBox(width: 8),
                                  // 手繪的那張可以載回畫板繼續改
                                  if (s.logo.drawn) ...[
                                    _miniBtn(
                                      Icons.draw_outlined,
                                      '編輯',
                                      _editDrawing,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  _miniBtn(Icons.crop, '裁切', _cropLogo),
                                  const Spacer(),
                                  IconButton(
                                    tooltip: s.logos.length > 1
                                        ? '移除這一張'
                                        : '移除圖片',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _update(
                                      () => s.removeLogo(s.activeLogo),
                                    ),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 19,
                                      color: kTextDim,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              _sliderRow(
                                '大小',
                                s.logo.sizeFrac,
                                0.05,
                                2.0,
                                (v) => _update(() => s.logo.sizeFrac = v),
                                curve: 2.0,
                              ),
                              _sliderRow(
                                '透明',
                                s.logo.opacity,
                                0.05,
                                1,
                                (v) => _update(() => s.logo.opacity = v),
                              ),
                              _rotationRow(
                                s.logo.rotation,
                                (v) => _update(() => s.logo.rotation = v),
                              ),
                              _sliderRow(
                                '圓角',
                                s.logo.corner,
                                0,
                                1,
                                (v) => _update(() => s.logo.corner = v),
                              ),
                              Row(
                                children: [
                                  const Text(
                                    '滿版平鋪',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: kTextDim,
                                    ),
                                  ),
                                  const Spacer(),
                                  _miniSwitch(
                                    s.logo.tiled,
                                    (v) => _setTiled(isLogo: true, on: v),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // ===== 父層注入的額外區塊（照片編輯器的馬賽克/更多浮水印）=====
                  for (var i = 0; i < widget.extraSections.length; i++)
                    if (_on(_extraKeys[i]))
                      KeyedSubtree(
                        key: _extraKeys[i],
                        child: _card(widget.extraSections[i].child),
                      ),
                ],
              ),
              if (!widget.hideSaveButton)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _saveBar(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 儲存範本（更新選中的範本，或另存新範本）。
  /// 排在內容最後（短分頁被推到底、長分頁跟著捲）：整排的白色膠囊，
  /// 跟「匯入照片」「輸出」那些主要動作鈕同一種長相。
  /// 照片編輯器把這顆移到底部跟「輸出」並排，所以可隱藏
  Widget _saveBar() => FilledButton.icon(
    onPressed: _savePreset,
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
    label: Text(
      _presetSel == null ? '儲存範本' : '儲存範本「$_presetSel」',
      style: const TextStyle(fontSize: 14),
    ),
  );

  /// 範本挑選彈窗：黑底預覽卡（跟範本管理頁同款），點卡直接套用
  void _openPresetPicker() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '選擇範本',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            // 兩欄瀑布流：卡片照各自的設計比例（跟範本管理頁同款）
            Flexible(
              child: Builder(
                builder: (context) {
                  final left = <Widget>[];
                  final right = <Widget>[];
                  var hl = 0.0, hr = 0.0;
                  void put(Widget w, double h) {
                    if (hl <= hr) {
                      left.add(w);
                      hl += h;
                    } else {
                      right.add(w);
                      hr += h;
                    }
                  }

                  for (final p in _presets) {
                    final a = p.settings.designAspect;
                    put(
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: AspectRatio(
                          aspectRatio: a,
                          child: _pickerCard(p),
                        ),
                      ),
                      1 / a,
                    );
                  }
                  put(
                    AspectRatio(aspectRatio: 16 / 10, child: _addPresetCard()),
                    10 / 16,
                  );
                  return SingleChildScrollView(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Column(children: left)),
                        const SizedBox(width: 8),
                        Expanded(child: Column(children: right)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「＋ 新增範本」卡：關掉挑選視窗，直接在目前畫面上設計，
  /// 調好按下方「儲存範本」就存成新的（不另開視窗）
  Widget _addPresetCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.pop(context);
        setState(() => _presetSel = null); // 存檔時視為新範本
        showHint(context, '調好浮水印後，按下方「儲存範本」');
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kClipBorder),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 22, color: kTextDim),
            SizedBox(height: 4),
            Text('新增範本', style: TextStyle(fontSize: 11, color: kTextDim)),
          ],
        ),
      ),
    );
  }

  Widget _pickerCard(WatermarkPreset p) {
    final selected = _presetSel == p.name;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.pop(context);
        _applyPresetNow(p);
      },
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorder, width: 1),
        ),
        // 選取框畫在前景，內容不位移
        foregroundDecoration: selected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kSelect, width: 1.5),
              )
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Colors.black,
              child: IgnorePointer(
                child: WatermarkLayer(settings: p.settings, onChanged: () {}),
              ),
            ),
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: kPanelHi.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: kClipBorder),
                ),
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: kIcon,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// W2 卡片群組：每個設定群組一張卡片
  /// 一個設定區塊。不畫框：面板改成分頁之後一次只出現一區，
  /// 那層框原本是用來把疊在一起的好幾區分開的，現在沒有東西要分——
  /// 留著只是在一塊小區域裡多一圈線
  Widget _card(Widget child) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 12),
      child: child,
    );
  }

  /// 位置九宮格：點一格直接把浮水印放到那個角落／邊／中心。
  /// 控制文字位置；只開 Logo 時控制 Logo。
  Widget _bigPosGrid() {
    const xs = [0.14, 0.5, 0.86];
    const ys = [0.12, 0.5, 0.9];
    // 文字要「真的有字」才算：開著但空字串時，九宮格應該動 Logo
    final hasText = s.text.enabled && s.text.text.trim().isNotEmpty;
    final target = hasText || !s.logo.enabled ? 'text' : 'logo';
    final x = target == 'text' ? s.text.x : s.logo.x;
    final y = target == 'text' ? s.text.y : s.logo.y;
    void pick(double gx, double gy) {
      // 指定位置＝退出滿版平鋪。走 _setTiled 才會把開平鋪前的大小
      // 還回去——不然這裡退出後留著平鋪用的最小尺寸，小到看不見
      if (target == 'text') {
        if (s.text.tiled) _setTiled(isLogo: false, on: false);
      } else {
        if (s.logo.tiled) _setTiled(isLogo: true, on: false);
      }
      _update(() {
        if (target == 'text') {
          s.text.x = gx;
          s.text.y = gy;
        } else {
          s.logo.x = gx;
          s.logo.y = gy;
        }
      });
    }

    return Column(
      children: [
        const Text(
          '浮水印位置',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 3,
            color: kTextDim,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        // 上限 210：180 太小、240 在影片編輯的矮面板裡還是太搶
        LayoutBuilder(
          builder: (context, cons) {
            final w = cons.maxWidth.isFinite
                ? math.min(cons.maxWidth, widget.posGridCap)
                : widget.posGridCap;
            return Center(
              child: Container(
                width: w,
                height: w * 102 / 180,
                decoration: BoxDecoration(
                  color: kBg,
                  border: Border.all(color: kBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final gy in ys)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final gx in xs)
                            InkWell(
                              onTap: () => pick(gx, gy),
                              customBorder: const CircleBorder(),
                              child: Container(
                                width: w / 6,
                                height: w / 6,
                                alignment: Alignment.center,
                                child: Container(
                                  width:
                                      ((x - gx).abs() < 0.17 &&
                                          (y - gy).abs() < 0.18)
                                      ? w / 13
                                      : w / 18,
                                  height:
                                      ((x - gx).abs() < 0.17 &&
                                          (y - gy).abs() < 0.18)
                                      ? w / 13
                                      : w / 18,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color:
                                        ((x - gx).abs() < 0.17 &&
                                            (y - gy).abs() < 0.18)
                                        ? kSelect
                                        : kPanelHi,
                                    border: Border.all(
                                      color: kBorder,
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        const Text(
          '點一格，直接對齊到畫面該處',
          style: TextStyle(fontSize: 10, color: kTextDim),
        ),
      ],
    );
  }

  /// 區塊標題列：小標 + 迷你開關

  Widget _miniSwitch(bool value, ValueChanged<bool> onChanged) {
    return Transform.scale(
      scale: 0.72,
      alignment: Alignment.centerRight,
      child: Switch(value: value, onChanged: onChanged),
    );
  }

  Widget _miniBtn(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 30),
        side: const BorderSide(color: kBorder),
        foregroundColor: kText,
        textStyle: const TextStyle(fontSize: 12, fontFamily: 'NotoSansTC'),
      ),
      icon: Icon(icon, size: 14, color: kTextDim),
      label: Text(label),
    );
  }

  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    double curve = 1,
  }) => sliderRow(
    label: label,
    value: value,
    min: min,
    max: max,
    curve: curve,
    onChanged: onChanged,
    onChangeStart: (_) => _sliderStart(),
    onChangeEnd: (_) => _sliderEnd(),
    readout: '${(value * 100).round()}',
    unit: '%',
  );

  /// 動畫微調列：滑桿＋右側實際數值
  Widget _animSlider(
    String label,
    double value,
    String readout,
    ValueChanged<double> onChanged,
  ) => sliderRow(
    label: label,
    value: value,
    min: 0.2,
    max: 3.0,
    onChanged: onChanged,
    onChangeStart: (_) => _sliderStart(),
    onChangeEnd: (_) => _sliderEnd(),
    readout: readout,
  );

  /// 旋轉專用列：卡在關鍵角度、點角度數字一鍵歸零
  Widget _rotationRow(double value, ValueChanged<double> onChanged) =>
      sliderRow(
        label: '旋轉',
        value: value,
        min: -180,
        max: 180,
        onChanged: (v) => onChanged(snapAngle(v, current: value)),
        onChangeStart: (_) => _sliderStart(),
        onChangeEnd: (_) => _sliderEnd(),
        readout: '${value.round()}',
        unit: '\u00B0',
        valueColor: value.round() == 0 ? kTextDim : kText,
        onReset: () => onChanged(0),
      );
}
