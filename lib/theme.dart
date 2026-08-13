import 'dart:async';

import 'package:flutter/material.dart';

/// 效能檢測模式（關於頁開關）：顯示 Flutter 的 UI/Raster 執行緒圖表，
/// 卡頓時截圖就能判斷瓶頸在哪一層
final ValueNotifier<bool> kPerfOverlay = ValueNotifier(false);

// ===== 「黑白 Mono Dark」設計系統 =====
// 碳黑面板、無彩色：強調一律用純白（選取／把手／主行動）
const kBg = Color(0xFF141416); // 底
const kPanel = Color(0xFF1D1D21); // 卡片/面板
const kPanelHi = Color(0xFF26262C); // 面板亮階（icon 磚、選中底）
const kBorder = Color(0xFF2A2A30); // 邊線
const kClipBorder = Color(0xFF34343C); // 時間軸片段邊線
const kAmber = Color(0xFFFFFFFF); // 強調色＝純白（沿用變數名，全 App 通用）
const kSelect = Color(0xFFFFC24B); // 時間軸選取/拖放專用琥珀（白框疊白縮圖看不清）
const kText = Color(0xFFE8E8EA);
const kTextDim = Color(0xFF8B8B95);
const kIcon = Color(0xFFB9B9C2);
const kRecord = Color(0xFFFF3B30); // 錄音中：紅鈕與即時波形

ThemeData buildStudioTheme() {
  const scheme = ColorScheme.dark(
    primary: kAmber,
    onPrimary: kBg,
    secondary: kAmber,
    onSecondary: kBg,
    surface: kBg,
    onSurface: kText,
    surfaceContainerHighest: kPanelHi,
    outline: kBorder,
    error: Color(0xFFFF6B6B),
  );

  final radius6 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
  final radius8 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'NotoSansTC',
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansTC',
        fontSize: 17,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.0,
        color: kText,
      ),
      iconTheme: IconThemeData(color: kIcon, size: 22),
      actionsIconTheme: IconThemeData(color: kIcon, size: 22),
    ),
    iconTheme: const IconThemeData(color: kIcon),
    cardTheme: CardThemeData(
      color: kPanel,
      elevation: 0,
      shape: radius8.copyWith(side: const BorderSide(color: kBorder)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAmber,
        foregroundColor: kBg,
        shape: radius6,
        textStyle: const TextStyle(
            fontWeight: FontWeight.w700, fontSize: 14, fontFamily: 'NotoSansTC'),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kAmber, shape: radius6),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kText,
        side: const BorderSide(color: kBorder),
        shape: radius6,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: kPanel,
      selectedColor: kPanelHi,
      side: const BorderSide(color: kBorder),
      shape: radius6,
      labelStyle: const TextStyle(
          fontSize: 12, color: kText, fontFamily: 'NotoSansTC'),
      secondaryLabelStyle: const TextStyle(
          fontSize: 12, color: kAmber, fontFamily: 'NotoSansTC'),
      checkmarkColor: kAmber,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: kAmber,
      unselectedLabelColor: kTextDim,
      indicatorColor: kAmber,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: kBorder,
      labelStyle: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'NotoSansTC'),
      unselectedLabelStyle: TextStyle(fontSize: 12, fontFamily: 'NotoSansTC'),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: kAmber,
      inactiveTrackColor: kPanelHi,
      thumbColor: kAmber,
      overlayColor: Color(0x33FFC24B),
      rangeThumbShape: RoundRangeSliderThumbShape(enabledThumbRadius: 8),
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? kBg : kTextDim),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? kAmber : kPanelHi),
      trackOutlineColor: const WidgetStatePropertyAll(kBorder),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? kAmber : kTextDim),
    ),
    dividerTheme: const DividerThemeData(color: kBorder, thickness: 1),
    dialogTheme: DialogThemeData(
      // 底色比面板亮一階＋真實陰影，跟壓暗的背景拉開層次
      backgroundColor: const Color(0xFF232329),
      barrierColor: Colors.black.withValues(alpha: 0.85),
      elevation: 24,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF3A3A42))),
      titleTextStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: kText,
          fontFamily: 'NotoSansTC'),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: kPanelHi,
      contentTextStyle:
          const TextStyle(color: kText, fontFamily: 'NotoSansTC'),
      shape: radius6,
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: kBg,
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: kBorder)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: kAmber, width: 1.5)),
      labelStyle: const TextStyle(color: kTextDim, fontSize: 13),
      // 提示文字用灰字，才不會被誤認成已輸入的內容
      hintStyle: const TextStyle(color: kTextDim, fontSize: 13),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: kIcon,
      textColor: kText,
    ),
    // 抽屜：亮一階底＋深遮罩＋描邊＋把手（把手由各呼叫端開）
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: kPanelHi,
      modalBackgroundColor: kPanelHi,
      modalBarrierColor: Colors.black.withValues(alpha: 0.6),
      elevation: 12,
      dragHandleColor: const Color(0xFF6A6A74),
      dragHandleSize: const Size(34, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        side: BorderSide(color: Color(0xFF4A4A52)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: kAmber,
      linearTrackColor: kPanelHi,
    ),
  );
}

// ===== 提示訊息（使用者選定的「預覽下緣＋琥珀邊條」樣式）=====

OverlayEntry? _hintEntry;
Timer? _hintTimer;

/// 精緻提示（取代預設 SnackBar）：貼在預覽畫面下緣的小卡，
/// 左側一條琥珀直線（error 時轉紅）。有 anchor 就錨定該區塊下緣，
/// 沒有就落在畫面下方置中。
void showHint(BuildContext context, String message,
    {bool error = false, GlobalKey? anchor, Duration? duration}) {
  if (!context.mounted) return;
  _hintTimer?.cancel();
  // 上一則可能已經跟著它的 Overlay 一起消失了，remove 會丟例外；
  // 這裡炸掉會讓 _hintEntry 永遠留著，之後每一則提示都跟著炸
  try {
    _hintEntry?.remove();
  } catch (_) {}
  _hintEntry = null;

  double? top;
  final anchorCtx = anchor?.currentContext;
  if (anchorCtx != null) {
    final box = anchorCtx.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      // 預覽下緣往上留 10px
      top = box.localToGlobal(Offset.zero).dy + box.size.height - 44;
    }
  }

  final entry = OverlayEntry(
    builder: (context) => _HintToast(message: message, error: error, top: top),
  );
  // 先插入成功才記到全域：插入失敗時留下一個從沒上樹的 entry，
  // 下一次 remove 它就會炸，之後全 App 的提示都跟著壞
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  overlay.insert(entry);
  _hintEntry = entry;
  _hintTimer = Timer(duration ?? const Duration(milliseconds: 2400), () {
    // 清自己捕捉到的那一個，不要清當下的全域值
    try {
      entry.remove();
    } catch (_) {}
    if (identical(_hintEntry, entry)) _hintEntry = null;
  });
}

class _HintToast extends StatelessWidget {
  final String message;
  final bool error;
  final double? top;

  const _HintToast({required this.message, required this.error, this.top});

  @override
  Widget build(BuildContext context) {
    final pill = IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        builder: (context, v, child) => Opacity(
          opacity: v,
          child: Transform.translate(
              offset: Offset(0, (1 - v) * 6), child: child),
        ),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            // 純黑不透明＋整圈亮邊＋濃陰影：跟深色面板拉開最大對比
            color: Colors.black,
            border: Border(
              left: BorderSide(
                  color: error ? const Color(0xFFFF6B6B) : kAmber,
                  width: 3),
              top: const BorderSide(color: Color(0xFF4A4A52)),
              right: const BorderSide(color: Color(0xFF4A4A52)),
              bottom: const BorderSide(color: Color(0xFF4A4A52)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.9),
                blurRadius: 22,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            message,
            style: const TextStyle(
                fontSize: 13,
                color: kText,
                height: 1.35,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400,
                fontFamily: 'NotoSansTC'),
          ),
        ),
      ),
    );

    if (top != null) {
      return Positioned(
          top: top, left: 0, right: 0, child: Center(child: pill));
    }
    // 預設落在畫面下方的空白區（工具列上方）
    return Positioned(
        bottom: 150, left: 0, right: 0, child: Center(child: pill));
  }
}

/// 確認對話框（使用者選定 C 款直排大按鈕）：
/// 置中標題＋一行後果說明＋整寬主行動鈕＋文字取消。回傳 true=執行。
Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  /// 補充說明；不給就只顯示標題和按鈕
  String message = '',
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: kText)),
              if (message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12.5, color: kTextDim, height: 1.55)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC'),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(
                  foregroundColor: kTextDim,
                  minimumSize: const Size.fromHeight(40),
                ),
                child: const Text('取消',
                    style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return ok == true;
}

/// 輸出完成後問下一步。回傳 true＝回主畫面、false＝留下來繼續編輯。
///
/// 存完檔直接把人留在編輯頁，他不知道到底成功了沒、也不知道
/// 接下來該按什麼；直接踢回主畫面又會讓想微調再存一次的人重來
/// 回傳 'home'（回主畫面）／'stay'（繼續編輯）／'save'（先存成範本）。
/// [offerSave] 打開時多一顆「存成範本」——問的時機比放一顆常駐按鈕準，
/// 使用者剛做完一組滿意的浮水印才會想留下來
Future<String> askAfterExport(
  BuildContext context,
  String message, {
  bool offerSave = false,
}) async {
  final act = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.check_circle_outline, size: 34, color: kAmber),
              const SizedBox(height: 12),
              const Text('輸出完成',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: kText)),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12.5, color: kTextDim, height: 1.55)),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC'),
                ),
                onPressed: () => Navigator.pop(context, 'home'),
                child: const Text('回主畫面'),
              ),
              if (offerSave) ...[
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    foregroundColor: kText,
                    side: const BorderSide(color: kBorder),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => Navigator.pop(context, 'save'),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text('把這次的浮水印存成範本',
                      style: TextStyle(fontSize: 12.5)),
                ),
              ],
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context, 'stay'),
                style: TextButton.styleFrom(
                  foregroundColor: kTextDim,
                  minimumSize: const Size.fromHeight(40),
                ),
                child: const Text('繼續編輯',
                    style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return act ?? 'stay';
}

/// 輸出照片前選格式。回傳 'jpg' / 'png'，取消回 null。
/// 照片編輯與批次共用——同一個選擇不該長成兩個樣子
Future<String?> askPhotoFormat(BuildContext context) {
  Widget tile(BuildContext context, String fmt, String title, String sub) =>
      Material(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context, fmt),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kClipBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.image_outlined, size: 20, color: kAmber),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: kText)),
                      const SizedBox(height: 2),
                      Text(sub,
                          style: const TextStyle(
                              fontSize: 11.5, color: kTextDim, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  return showDialog<String>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: kBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: kBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('輸出到相簿',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              tile(context, 'jpg', 'JPEG',
                  '檔案小很多（約 1/8），肉眼看不出跟 PNG 差別'),
              const SizedBox(height: 8),
              tile(context, 'png', 'PNG 無損', '完全不壓縮'),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 點到重疊處時的說明。三個編輯畫面講同一句
String overlapHint(int layers) => '這裡疊了 $layers 層，再點一次選下面那層';

/// 剛加入馬賽克時的說明。影片和照片講同一句，
/// 不然同一個功能在兩邊聽起來像兩件事
const kMosaicHint = '拖曳調位置、雙指縮放；再點一下可調樣式';

/// 區塊小標（灰字、寬字距，如「開始新專案」）
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 3,
          color: kTextDim,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

