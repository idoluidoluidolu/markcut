import 'dart:async';

import 'package:flutter/material.dart';

import '../models/watermark_settings.dart';
import '../services/font_store.dart';
import '../theme.dart';

/// 字型下拉（浮水印面板的文字卡、文字素材的編輯視窗共用）。
///
/// 點了才下載的字型（[kDownloadFonts]）：還沒下載的字名用內建的小字型
/// 寫出原本的樣子、右邊一個下載圖示；點下去先下載（跳下載視窗、可以按
/// 取消，見 [downloadFontsWithDialog]），下載好才真的換過去——之前的字
/// 照舊，不會先閃成後備字。下載不了就跳提示、留在原本的字型
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
    // 手機裡有檔就直接讀（很快，不跳視窗）；沒有才下載
    var ok = await store.ensure(family, download: false);
    if (!ok && mounted && _pending == family) {
      final failed = await downloadFontsWithDialog(context, {family});
      if (failed == null) {
        // 按了取消：留在原本的字型，也不跳「下載不了」
        if (mounted && _pending == family) setState(() => _pending = null);
        return;
      }
      ok = failed.isEmpty;
    }
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
///（跳下載視窗，按取消就不匯出）；下載不了就擋下來、說是哪幾款。
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
  // 手機裡有的直接讀（很快，不用跳視窗）
  final missing = await store.ensureAll(need, download: false);
  if (missing.isEmpty) return true;
  if (!context.mounted) return false;
  final failed = await downloadFontsWithDialog(context, missing);
  if (failed == null) return false; // 按了取消：不匯出
  if (failed.isEmpty) return true;
  if (context.mounted) {
    showHint(
      context,
      '「${failed.map(fontLabelOf).join('、')}」字型還沒下載，連上網路再匯出',
      error: true,
    );
  }
  return false;
}

/// 下載 [families]，下載中跳視窗：哪幾款、進度、「取消」（使用者 10-16
/// 指定：文字下載中要跳視窗提示、可以點選取消。以前只在字型按鈕上畫一個
/// 小進度圈，匯出前是一行提示，都沒辦法反悔）。下載完視窗自己收。
/// 回傳下載不了的那幾款；按了取消（或返回鍵）回 null，那幾款的下載也停掉
Future<Set<String>?> downloadFontsWithDialog(
  BuildContext context,
  Set<String> families,
) async {
  final store = FontStore.instance;
  final nav = Navigator.of(context, rootNavigator: true);
  var cancelled = false;
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final f in families) {
      store.cancel(f);
    }
  }

  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
    themes: InheritedTheme.capture(from: context, to: nav.context),
    builder: (ctx) => PopScope(
      canPop: false,
      // 返回鍵＝取消
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        cancel();
        Navigator.of(ctx).pop();
      },
      child: _FontDownloadDialog(
        families: families.toList(),
        onCancel: () {
          cancel();
          Navigator.of(ctx).pop();
        },
      ),
    ),
  );
  final work = store.ensureAll(families, force: true);
  unawaited(
    work.whenComplete(() {
      // 按了取消的話視窗已經收了；還在的話自己收（不在最上面就直接拿掉，
      // 不能 pop 到別人的頁面）
      if (!route.isActive) return;
      if (route.isCurrent) {
        nav.pop();
      } else {
        nav.removeRoute(route);
      }
    }),
  );
  await nav.push(route);
  final failed = await work;
  return cancelled ? null : failed;
}

/// 下載視窗本人：長相跟 showConfirm／showNotice 同一套（圓角、邊線、置中
/// 標題、灰字取消），中間一條進度＋「已收 / 總共 MB」
class _FontDownloadDialog extends StatelessWidget {
  const _FontDownloadDialog({required this.families, required this.onCancel});

  final List<String> families;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = pageColors(context);
    final store = FontStore.instance;
    final total = families.fold<int>(0, (n, f) => n + store.sizeOf(f));
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
        side: BorderSide(color: c.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kDialogWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '下載字型「${families.map(fontLabelOf).join('、')}」',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: c.text,
                ),
              ),
              const SizedBox(height: 18),
              ValueListenableBuilder<Map<String, double>>(
                valueListenable: store.downloading,
                builder: (context, progress, _) {
                  // 每一款照檔案大小加權；還沒輪到的算 0、已經好的算 1
                  var got = 0.0;
                  for (final f in families) {
                    final p = progress[f] ?? (store.isReady(f) ? 1.0 : 0.0);
                    got += store.sizeOf(f) * p;
                  }
                  final v = total > 0 ? got / total : 0.0;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          minHeight: 6,
                          // 剛開始連線還沒收到資料：跑動畫，不要停在 0
                          value: v > 0 ? v : null,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(got / 1e6).toStringAsFixed(1)} / '
                        '${(total / 1e6).toStringAsFixed(1)} MB',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: c.dim),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: c.dim,
                  minimumSize: const Size.fromHeight(40),
                ),
                child: const Text('取消', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
