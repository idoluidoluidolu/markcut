import 'dart:async';

import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';
import '../services/font_store.dart';
import '../theme.dart';

/// 字型下拉（浮水印面板的文字卡、文字素材的編輯視窗共用）。
///
/// 點了才下載的字型（[kDownloadFonts]）：還沒下載的字名用內建的小字型
/// 寫出原本的樣子、右邊一個下載圖示；點下去先下載（按鈕上顯示那款字型
/// ＋進度圈），下載好才真的換過去——之前的字照舊，不會先閃成後備字。
/// 下載不了就跳提示、留在原本的字型
class FontDropdown extends StatefulWidget {
  const FontDropdown({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<FontDropdown> createState() => _FontDropdownState();
}

class _FontDropdownState extends State<FontDropdown> {
  /// 點了、正在下載的那款（下載好才交給 onChanged）
  String? _pending;

  @override
  void didUpdateWidget(FontDropdown old) {
    super.didUpdateWidget(old);
    // 字型被別的地方換掉了（套範本、上一步）：下載中的那款作廢，
    // 下載完不要蓋掉新的選擇
    if (old.value != widget.value) _pending = null;
  }

  Future<void> _pick(String? family) async {
    if (family == null) return;
    final store = FontStore.instance;
    if (store.isReady(family)) {
      setState(() => _pending = null);
      if (family != widget.value) widget.onChanged(family);
      return;
    }
    setState(() => _pending = family);
    final ok = await store.ensure(family, force: true);
    if (!mounted || _pending != family) return; // 中途改點別的
    setState(() => _pending = null);
    if (ok) {
      widget.onChanged(family);
    } else {
      showHint(context, '「${fontLabelOf(family)}」下載不了，請檢查網路', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = FontStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store.loaded, store.downloading]),
      builder: (context, _) {
        final shown = _pending ?? widget.value;
        return DropdownButtonHideUnderline(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButton<String>(
              key: const ValueKey('font-dropdown'),
              isExpanded: true,
              value: shown,
              icon: const Icon(Icons.expand_more, size: 16, color: kTextDim),
              style: const TextStyle(fontSize: 13, color: kText),
              // 選單跟 App 同風格：面板色、圓角、限高
              dropdownColor: kPanelHi,
              borderRadius: BorderRadius.circular(12),
              menuMaxHeight: 320,
              menuWidth: 280,
              itemHeight: 48,
              // 按鈕上：還在下載的只畫進度圈（下載圖示是選單裡用的）
              selectedItemBuilder: (context) => [
                for (final f in kFontOptions)
                  _FontLabel(family: f.family, label: f.label, button: true),
              ],
              items: [
                for (final f in kFontOptions)
                  DropdownMenuItem(
                    value: f.family,
                    child: _FontLabel(family: f.family, label: f.label),
                  ),
              ],
              onChanged: (v) => unawaited(_pick(v)),
            ),
          ),
        );
      },
    );
  }
}

class _FontLabel extends StatelessWidget {
  const _FontLabel({
    required this.family,
    required this.label,
    this.button = false,
  });

  final String family;
  final String label;
  final bool button;

  @override
  Widget build(BuildContext context) {
    final store = FontStore.instance;
    final ready = store.isReady(family);
    final progress = store.progressOf(family);
    Widget? trailing;
    if (progress != null) {
      trailing = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          // 剛開始連線還沒收到資料：轉圈，不要停在 0
          value: progress > 0 ? progress : null,
          color: kText,
          backgroundColor: kBorder,
        ),
      );
    } else if (!ready && !button) {
      trailing = const Icon(
        Icons.download_rounded,
        size: 16,
        color: kTextDim,
        semanticLabel: '要下載',
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              // 還沒下載的用內建小字型寫字名（只有這幾個字）
              fontFamily: ready
                  ? family
                  : kDownloadFonts[family]?.previewFamily ?? family,
              fontFamilyFallback: kMarkFontFallback,
              fontSize: 13,
              // 有些字型（粉圓）的行高比字級大，不夾住行高就會頂出格子
              height: 1.15,
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
    );
  }
}

/// 匯出前確認用到的下載字型都在：手機裡有的讀進來；沒有的現在下載
///（跳「下載字型」提示）；下載不了就擋下來、說是哪幾款。
/// 回 false＝別匯出：成品會變成後備字，使用者不會察覺
Future<bool> ensureExportFonts(
  BuildContext context,
  Iterable<String> families,
) async {
  final store = FontStore.instance;
  final need = {
    for (final f in families)
      if (!store.isReady(f)) f,
  };
  if (need.isEmpty) return true;
  // 手機裡有的直接讀（很快，不用跳提示）
  var missing = await store.ensureAll(need, download: false);
  if (missing.isEmpty) return true;
  if (!context.mounted) return false;
  final mb =
      missing.fold<int>(0, (a, f) => a + (kDownloadFonts[f]?.bytes ?? 0)) /
      1e6;
  // 十幾 MB 要好幾秒：提示一直掛著，下載完自己收
  showHint(
    context,
    '下載字型「${missing.map(fontLabelOf).join('、')}」（${mb.toStringAsFixed(0)} MB）…',
    duration: const Duration(minutes: 2),
  );
  missing = await store.ensureAll(missing, force: true);
  if (missing.isEmpty) {
    hideHint();
    return true;
  }
  if (context.mounted) {
    showHint(
      context,
      '「${missing.map(fontLabelOf).join('、')}」字型還沒下載，連上網路再匯出',
      error: true,
    );
  }
  return false;
}
