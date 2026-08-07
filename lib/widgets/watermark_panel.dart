import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';

import '../models/watermark_settings.dart';
import '../services/preset_store.dart';
import '../theme.dart';
import 'watermark_layer.dart';

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

  const WatermarkPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onBeforeChange,
    this.showAnimation = false,
    this.syncVersion = 0,
    this.initialPresetName,
  });

  @override
  State<WatermarkPanel> createState() => _WatermarkPanelState();
}

class _WatermarkPanelState extends State<WatermarkPanel> {
  late final TextEditingController _textCtrl;

  WatermarkSettings get s => widget.settings;

  List<WatermarkPreset> _presets = [];
  String? _presetSel; // 選單目前顯示的範本名

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: s.text.text);
    _presetSel = widget.initialPresetName;
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    final p = await PresetStore.load();
    if (mounted) setState(() => _presets = p);
  }

  void _applyPresetNow(WatermarkPreset p) {
    _update(() {
      s.text = p.settings.text.copy();
      s.logo = p.settings.logo.copy();
      s.animation = p.settings.animation;
      s.animSpeed = p.settings.animSpeed;
      s.animRange = p.settings.animRange;
      _textCtrl.text = s.text.text;
      _presetSel = p.name;
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _update(VoidCallback fn) {
    widget.onBeforeChange?.call();
    setState(fn);
    widget.onChanged();
  }

  @override
  void didUpdateWidget(WatermarkPanel old) {
    super.didUpdateWidget(old);
    if (widget.syncVersion != old.syncVersion) {
      // 父層剛做了復原：把輸入框文字對回 settings
      _textCtrl.text = s.text.text;
      _presetSel = null;
      setState(() {});
    }
  }

  Future<void> _pickLogo() async {
    final picked =
        await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final raw = await picked.readAsBytes();
    // 縮到 1024px 內再存進設定，範本自帶圖檔不佔太多空間
    final shrunk = await _shrinkToPng(raw, 1024);
    _update(() {
      s.logo.bytesValue = shrunk;
      s.logo.enabled = true;
    });
  }

  static Future<Uint8List> _shrinkToPng(Uint8List raw, int maxW) async {
    var codec = await ui.instantiateImageCodec(raw);
    var frame = await codec.getNextFrame();
    if (frame.image.width > maxW) {
      frame.image.dispose();
      codec = await ui.instantiateImageCodec(raw, targetWidth: maxW);
      frame = await codec.getNextFrame();
    }
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 通用顏色挑選：文字、描邊、底色共用
  Future<void> _pickColorFor(
      Color initial, void Function(int argb) apply) async {
    var color = initial;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('顏色'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: color,
            enableAlpha: false,
            labelTypes: const [],
            onColorChanged: (c) => color = c,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('確定')),
        ],
      ),
    );
    if (ok == true) {
      _update(() => apply(color.toARGB32()));
    }
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
            Text(label,
                style: const TextStyle(fontSize: 12, color: kTextDim)),
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
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, nameCtrl.text.trim()),
              child: const Text('儲存')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final existed = _presets.any((p) => p.name == name);
    await PresetStore.add(WatermarkPreset(name: name, settings: s.copy()));
    _presetSel = name;
    if (mounted) {
      showHint(context, existed ? '已更新範本「$name」' : '已儲存範本「$name」');
    }
  }

  /// 動畫卡的位置：選了動畫後自動捲過去，讓微調滑桿露臉
  final _animCardKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ListView(
      // 往下滑清單就收鍵盤（打完字回不去的解法）
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // ===== 選擇範本：亮階底＋琥珀圖示＋下拉箭頭，按了彈窗挑 =====
        OutlinedButton(
          onPressed: _openPresetPicker,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            backgroundColor: kPanelHi,
            side: const BorderSide(color: kClipBorder),
            foregroundColor: kText,
            textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: 'NotoSansTC'),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bookmarks_outlined,
                  size: 16, color: kAmber),
              const SizedBox(width: 8),
              Text(_presetSel == null ? '選擇範本' : '範本：$_presetSel'),
              const SizedBox(width: 5),
              const Icon(Icons.keyboard_arrow_down,
                  size: 17, color: kTextDim),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // ===== 卡片 1：位置 =====
        _card(_bigPosGrid()),

        // ===== 動畫（影片專用）=====
        if (widget.showAnimation)
          KeyedSubtree(
          key: _animCardKey,
          child: _card(Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('動畫',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: kText)),
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
                            final ctx = _animCardKey.currentContext;
                            if (ctx != null) {
                              Scrollable.ensureVisible(
                                ctx,
                                duration:
                                    const Duration(milliseconds: 350),
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
                            color: s.animation == a
                                ? kAmber
                                : kClipBorder,
                            width: s.animation == a ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(a.label,
                            style: TextStyle(
                                fontSize: 11.5,
                                height: 1.2,
                                fontWeight: s.animation == a
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: s.animation == a
                                    ? kAmber
                                    : kText)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(s.animation.note,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10.5, color: kTextDim)),
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
                    s.animation == WmAnimation.blink ? '一次亮多久' : '幅度',
                    s.animRange,
                    s.animation == WmAnimation.blink
                        ? '亮 ${s.blinkOn.toStringAsFixed(1)} 秒'
                        : '${(s.animRange * 2).toStringAsFixed(0)}%',
                    (v) => _update(() => s.animRange = v),
                  ),
              ],
            ],
          )),
          ),

        // ===== 卡片 2：文字 =====
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        _sectionRow('文字', s.text.enabled,
            (v) => _update(() => s.text.enabled = v)),
        if (s.text.enabled) ...[
          const SizedBox(height: 6),
          // ===== 大輸入框：用目前字型與顏色顯示，打字即預覽 =====
          Container(
            constraints: const BoxConstraints(minHeight: 110),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF0F0F11),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kClipBorder, width: 1.5),
            ),
            child: TextField(
              controller: _textCtrl,
              textAlign: TextAlign.center,
              maxLines: null,
              style: TextStyle(
                fontFamily: s.text.fontFamily,
                fontSize: 26,
                color: s.text.color
                    .withValues(alpha: s.text.opacity.clamp(0.55, 1.0)),
              ),
              decoration: const InputDecoration(
                hintText: '浮水印文字',
                hintStyle: TextStyle(
                    color: kTextDim,
                    fontSize: 16,
                    fontFamily: 'NotoSansTC'),
                filled: false,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 20),
              ),
              onChanged: (v) => _update(() => s.text.text = v),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: kBorder),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: s.text.fontFamily,
                      icon: const Icon(Icons.expand_more,
                          size: 16, color: kTextDim),
                      style: const TextStyle(fontSize: 13, color: kText),
                      // 選單跟 App 同風格：面板色、圓角、限高
                      dropdownColor: kPanelHi,
                      borderRadius: BorderRadius.circular(12),
                      menuMaxHeight: 320,
                      itemHeight: 48,
                      items: [
                        for (final f in kFontOptions)
                          DropdownMenuItem(
                            value: f.family,
                            child: Text(f.label,
                                style: TextStyle(
                                    fontFamily: f.family, fontSize: 13)),
                          ),
                      ],
                      onChanged: (v) => _update(
                          () => s.text.fontFamily = v ?? 'NotoSansTC'),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: _pickColor,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: s.text.color,
                    shape: BoxShape.circle,
                    border: Border.all(color: kBorder, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          _sliderRow('大小', s.text.sizeFrac, 0.015, 0.25,
              (v) => _update(() => s.text.sizeFrac = v)),
          _sliderRow('透明', s.text.opacity, 0.05, 1,
              (v) => _update(() => s.text.opacity = v)),
          _sliderRow('間距', s.text.spacing, 0, 0.6,
              (v) => _update(() => s.text.spacing = v)),
          _rotationRow(s.text.rotation,
              (v) => _update(() => s.text.rotation = v)),
          Row(
            children: [
              const Text('滿版平鋪',
                  style: TextStyle(fontSize: 12, color: kTextDim)),
              const Spacer(),
              _miniSwitch(
                  s.text.tiled, (v) => _update(() => s.text.tiled = v)),
            ],
          ),
          Row(
            children: [
              const Text('陰影',
                  style: TextStyle(fontSize: 12, color: kTextDim)),
              const Spacer(),
              _miniSwitch(
                  s.text.shadow, (v) => _update(() => s.text.shadow = v)),
            ],
          ),
          Row(
            children: [
              const Text('描邊',
                  style: TextStyle(fontSize: 12, color: kTextDim)),
              const Spacer(),
              _miniSwitch(
                  s.text.outline, (v) => _update(() => s.text.outline = v)),
            ],
          ),
          if (s.text.outline) ...[
            _colorDotRow('顏色', s.text.outlineColor,
                (v) => s.text.outlineColorValue = v),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _sliderRow('粗度', s.text.outlineWidth, 0.02, 0.2,
                  (v) => _update(() => s.text.outlineWidth = v)),
            ),
          ],
          Row(
            children: [
              const Text('底色',
                  style: TextStyle(fontSize: 12, color: kTextDim)),
              const Spacer(),
              _miniSwitch(s.text.bg, (v) => _update(() => s.text.bg = v)),
            ],
          ),
          if (s.text.bg) ...[
            _colorDotRow(
                '顏色', s.text.bgColor, (v) => s.text.bgColorValue = v),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _sliderRow('透明', s.text.bgOpacity, 0.1, 1,
                  (v) => _update(() => s.text.bgOpacity = v)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _sliderRow('大小', s.text.bgPad, 0.3, 2.5,
                  (v) => _update(() => s.text.bgPad = v)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _sliderRow('圓角', s.text.bgCorner, 0, 1,
                  (v) => _update(() => s.text.bgCorner = v)),
            ),
          ],
        ],
          ],
        )),

        // ===== 卡片 3：圖片（有圖才展開；用＋加入，不用開關）=====
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        // 還沒有圖片時整行都能點（不用精準戳 + 號）
        InkWell(
          onTap: (!s.logo.enabled || s.logo.bytes == null)
              ? _pickLogo
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              const Text('圖片',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: kText)),
              const Spacer(),
              if (!s.logo.enabled || s.logo.bytes == null)
                IconButton(
                  tooltip: '加入圖片',
                  visualDensity: VisualDensity.compact,
                  onPressed: _pickLogo,
                  icon: const Icon(Icons.add, size: 20, color: kIcon),
                ),
            ],
          ),
        ),
        if (s.logo.enabled && s.logo.bytes != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(s.logo.bytes!,
                    width: 44, height: 44, fit: BoxFit.cover),
              ),
              const SizedBox(width: 10),
              _miniBtn(Icons.swap_horiz, '換一張', _pickLogo),
              const Spacer(),
              IconButton(
                tooltip: '移除圖片',
                visualDensity: VisualDensity.compact,
                onPressed: () => _update(() {
                  s.logo.enabled = false;
                  s.logo.b64 = null;
                }),
                icon: const Icon(Icons.delete_outline,
                    size: 19, color: kTextDim),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _sliderRow('大小', s.logo.sizeFrac, 0.05, 0.6,
              (v) => _update(() => s.logo.sizeFrac = v)),
          _sliderRow('透明', s.logo.opacity, 0.05, 1,
              (v) => _update(() => s.logo.opacity = v)),
          _rotationRow(s.logo.rotation,
              (v) => _update(() => s.logo.rotation = v)),
          _sliderRow('圓角', s.logo.corner, 0, 1,
              (v) => _update(() => s.logo.corner = v)),
          Row(
            children: [
              const Text('滿版平鋪',
                  style: TextStyle(fontSize: 12, color: kTextDim)),
              const Spacer(),
              _miniSwitch(
                  s.logo.tiled, (v) => _update(() => s.logo.tiled = v)),
            ],
          ),
        ],
          ],
        )),

        // ===== 儲存範本（更新選中的範本，或另存新範本）=====
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed: () async {
            await _savePreset();
            await _loadPresets();
          },
          icon: const Icon(Icons.bookmark_add_outlined, size: 18),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
                _presetSel == null ? '儲存範本' : '儲存範本「$_presetSel」',
                style: const TextStyle(fontSize: 14)),
          ),
        ),
      ],
    );
  }

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
            const Text('選擇範本',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 16 / 10,
                ),
                // 最後一格＝新增範本
                itemCount: _presets.length + 1,
                itemBuilder: (context, i) => i < _presets.length
                    ? _pickerCard(_presets[i])
                    : _addPresetCard(),
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
            Text('新增範本',
                style: TextStyle(fontSize: 11, color: kTextDim)),
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
          border: Border.all(
            color: selected ? kAmber : kBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Colors.black,
              child: IgnorePointer(
                child: WatermarkLayer(
                  settings: p.settings,
                  onChanged: () {},
                ),
              ),
            ),
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2.5),
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
                      fontSize: 10, color: kIcon, height: 1.3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }


  /// W2 卡片群組：每個設定群組一張卡片
  Widget _card(Widget child) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: child,
    );
  }

  /// 位置九宮格：點一格直接把浮水印放到那個角落／邊／中心。
  /// 控制文字位置；只開 Logo 時控制 Logo。
  Widget _bigPosGrid() {
    const xs = [0.14, 0.5, 0.86];
    const ys = [0.12, 0.5, 0.9];
    final target = s.text.enabled || !s.logo.enabled ? 'text' : 'logo';
    final x = target == 'text' ? s.text.x : s.logo.x;
    final y = target == 'text' ? s.text.y : s.logo.y;
    void pick(double gx, double gy) => _update(() {
          if (target == 'text') {
            s.text.tiled = false; // 指定位置＝退出滿版平鋪
            s.text.x = gx;
            s.text.y = gy;
          } else {
            s.logo.tiled = false; // 指定位置＝退出滿版平鋪
            s.logo.x = gx;
            s.logo.y = gy;
          }
        });

    return Column(
      children: [
        const Text('浮水印位置',
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 3,
                color: kTextDim,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Center(
      child: Container(
        width: 180,
        height: 102,
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
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        child: Container(
                          width:
                              ((x - gx).abs() < 0.17 && (y - gy).abs() < 0.18)
                                  ? 14.0
                                  : 10.0,
                          height:
                              ((x - gx).abs() < 0.17 && (y - gy).abs() < 0.18)
                                  ? 14.0
                                  : 10.0,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: ((x - gx).abs() < 0.17 &&
                                    (y - gy).abs() < 0.18)
                                ? kAmber
                                : kPanelHi,
                            border: Border.all(color: kBorder, width: 0.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
        ),
        const SizedBox(height: 6),
        const Text('點一格，直接對齊到畫面該處',
            style: TextStyle(fontSize: 10, color: kTextDim)),
      ],
    );
  }

  /// 區塊標題列：小標 + 迷你開關
  Widget _sectionRow(String title, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: kText)),
        const Spacer(),
        _miniSwitch(value, onChanged),
      ],
    );
  }

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
        textStyle:
            const TextStyle(fontSize: 12, fontFamily: 'NotoSansTC'),
      ),
      icon: Icon(icon, size: 14, color: kTextDim),
      label: Text(label),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          SizedBox(
              width: 34,
              child: Text(label,
                  style:
                      const TextStyle(fontSize: 12, color: kTextDim))),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 動畫微調列：滑桿＋右側實際數值
  Widget _animSlider(String label, double value, String readout,
      ValueChanged<double> onChanged) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style:
                    const TextStyle(fontSize: 11.5, color: kTextDim)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value.clamp(0.2, 3.0),
                min: 0.2,
                max: 3.0,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(readout,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 9.5, color: kTextDim, height: 1.2)),
          ),
        ],
      ),
    );
  }

  /// 旋轉專用列：靠近 0 度自動吸附回正、點角度數字一鍵歸零
  Widget _rotationRow(double value, ValueChanged<double> onChanged) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          const SizedBox(
              width: 34,
              child: Text('旋轉',
                  style: TextStyle(fontSize: 12, color: kTextDim))),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value.clamp(-180, 180),
                min: -180,
                max: 180,
                onChanged: (v) =>
                    onChanged(v.abs() < 4 ? 0 : v), // 吸附回正
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => onChanged(0),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 4, vertical: 4),
              child: Text('${value.round()}°',
                  style: TextStyle(
                      fontSize: 11,
                      color: value.round() == 0 ? kTextDim : kText,
                      fontFeatures: const [
                        FontFeature.tabularFigures()
                      ])),
            ),
          ),
        ],
      ),
    );
  }
}
