import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

/// 效能檢測模式（關於頁開關）：顯示 Flutter 的 UI/Raster 執行緒圖表，
/// 卡頓時截圖就能判斷瓶頸在哪一層
final ValueNotifier<bool> kPerfOverlay = ValueNotifier(false);

// ===== 「碳黑 ＋ 琥珀」設計系統 =====
//
// 底一路黑到底：主流剪輯 App（CapCut、剪映、iMovie）的編輯畫面幾乎
// 都是純黑，因為畫面上唯一該亮的是使用者的素材。面板只比底黑高一階，
// 靠間距與邊線分區，不靠亮度——面板一亮，眼睛就會被 UI 拉走
// 整個工作區同一個近黑（Edits 的做法）：純黑只留給畫布，
// 輸出範圍靠「畫布黑 vs 介面近黑」自己浮出來
const kBg = Color(0xFF0C0F14);
// D 案「只留線框」：卡片完全不填色（跟背景同色），輪廓全靠框線。
// 常數留著，哪天要回填色只改這一行
const kPanel = kBg;
const kPanelHi = Color(0xFF1A1A1C); // 面板亮階（icon 磚、選中底）
const kBorder = Color(0xFF252528); // 邊線
const kClipBorder = Color(0xFF2A2A2E); // 時間軸片段邊線
// 預覽區的底（畫布外圍那圈）。幾乎是純黑，只留一階讓黑色畫布的邊界
// 還看得出來——比例不同的素材會留黑邊，全一樣黑就分不出畫面到哪裡
// 跟整個工作區同一個顏色（不再是自己一塊）
const kPreviewBg = kBg;

const kAmber = Color(0xFFFFFFFF); // 強調色＝純白（沿用變數名，全 App 通用）
// 選取狀態只有兩種，不要再長出第三種：
//   設定面板裡的「選項」被選中 → kAmber（純白）框 + kPanelHi 底
//   疊在使用者照片／影片上的「物件」被選中 → kSelect（琥珀）
// 後者不能用白：白框疊在白色縮圖或亮照片上會整個看不見
const kSelect = Color(0xFFFFC24B); // 時間軸/縮圖/預覽選取框 專用琥珀
const kText = Color(0xFFE8E8EA);
const kTextDim = Color(0xFF8B8B95);
const kIcon = Color(0xFFB9B9C2);

// ===== 尺寸常數 =====
// 圓角本來散在 3～18 之間（卡片就六種），是各畫面各自手刻的結果。
// 新畫面一律引用這裡，不要再寫死數字
//
// 挑這幾個值的理由：主要按鈕已經是膠囊，卡片配 12 才不會顯得方；
// 對話框 16 是這一輪新做的三個共用對話框已經在用的值；
// 小標籤 6 跟輸入框同階，讀起來是同一個家族
const kCardRadius = 12.0; // 卡片
const kDialogRadius = 16.0; // 對話框
const kTagRadius = 6.0; // 小標籤、狀態標
const kFieldRadius = 12.0; // 大的文字輸入框

/// 對話框最大寬度（窄的那些讀起來會太擠）
const kDialogWidth = 280.0;

// 滑桿列：左邊標籤欄、右邊數值欄。
// 兩邊都固定寬，同一頁上下捲動時軌道的左右緣才不會一直跳
const kSliderLabelW = 56.0;
const kSliderValueW = 44.0;
const kRecord = Color(0xFFFF3B30); // 錄音中：紅鈕與即時波形

/// 共用元件（對話框、選項列）在深色與淺色頁都會出現，顏色得看當下的佈景。
///
/// 不直接用 ColorScheme 推是刻意的：深色那組值一個都不能變，而
/// kTextDim、kClipBorder 在 ColorScheme 裡沒有對應的位置，硬推會飄色
typedef PageColors = ({
  Color text,
  Color dim,
  Color line,
  Color accent,
  Color panelHi,
  Color bg,
});

PageColors pageColors(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? (
            text: kText,
            dim: kTextDim,
            line: kBorder,
            accent: kAmber,
            panelHi: kPanelHi,
            bg: kBg,
          )
        : (
            text: kLText,
            dim: kLTextDim,
            line: kLBorder,
            accent: kLAccent,
            panelHi: kLPanelHi,
            bg: kLBg,
          );

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
  final cardShape =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCardRadius));

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
      shape: cardShape.copyWith(side: const BorderSide(color: kBorder)),
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
      // 細版：一張表常常四五條滑桿疊在一起，Material 預設的把手 10
      // 會讓那排白點比標籤和數值加起來還搶。
      // 觸控範圍另外由 overlayShape 撐到 28px，
      // 所以圓點縮小完全不影響好不好按
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6.5),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      rangeThumbShape: RoundRangeSliderThumbShape(enabledThumbRadius: 6.5),
      trackHeight: 2.5,
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
    // 圓角改成 kDialogRadius：所有 AlertDialog 一次跟上
    dialogTheme: DialogThemeData(
      // 底色比面板亮一階＋真實陰影，跟壓暗的背景拉開層次
      backgroundColor: const Color(0xFF151519),
      barrierColor: Colors.black.withValues(alpha: 0.85),
      elevation: 24,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kDialogRadius),
          side: const BorderSide(color: Color(0xFF2E2E36))),
      // 標題字級跟自訂的那幾個對話框對齊（原本 16 只有這裡在用）
      titleTextStyle: const TextStyle(
          fontSize: 15.5,
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
      dragHandleColor: const Color(0xFF55555E),
      dragHandleSize: const Size(34, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        side: BorderSide(color: Color(0xFF33333B)),
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
              top: const BorderSide(color: Color(0xFF33333B)),
              right: const BorderSide(color: Color(0xFF33333B)),
              bottom: const BorderSide(color: Color(0xFF33333B)),
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
  final c = pageColors(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: kDialogWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 26, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: c.text)),
              if (message.isNotEmpty) ...[
                SizedBox(height: 8),
                Text(message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: c.dim, height: 1.55)),
              ],
              SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC'),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
              SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(
                  foregroundColor: c.dim,
                  minimumSize: const Size.fromHeight(40),
                ),
                child: Text('取消',
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
/// 回傳 'home'（回主畫面）或 'stay'（繼續編輯）。
/// [note] 是次要說明（例如「此平台不支援 JPEG，已改用 PNG」），
/// 用小灰字放在主訊息下面——那種話不該跟「成功了」搶同一行
Future<String> askAfterExport(
  BuildContext context,
  String message, {
  String? note,
}) async {
  final c = pageColors(context);
  final act = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: kDialogWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.check_circle_outline, size: 34, color: c.accent),
              SizedBox(height: 12),
              Text('輸出完成',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: c.text)),
              SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: kIcon, height: 1.55)),
              if (note != null) ...[
                SizedBox(height: 6),
                Text(note,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11, color: c.dim, height: 1.5)),
              ],
              SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC'),
                ),
                onPressed: () => Navigator.pop(context, 'home'),
                child: Text('回主畫面'),
              ),
              SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context, 'stay'),
                style: TextButton.styleFrom(
                  foregroundColor: c.dim,
                  minimumSize: const Size.fromHeight(40),
                ),
                child: Text('繼續編輯',
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
  final c = pageColors(context);
  Widget tile(BuildContext context, String fmt, String title, String sub) =>
      Material(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context, fmt),
          child: Container(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.line),
            ),
            child: Row(
              children: [
                Icon(Icons.image_outlined, size: 20, color: c.accent),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: c.text)),
                      SizedBox(height: 2),
                      Text(sub,
                          style: TextStyle(
                              fontSize: 11.5, color: c.dim, height: 1.4)),
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
      backgroundColor: c.bg,
      insetPadding: EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
        side: BorderSide(color: c.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: kDialogWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('輸出到相簿',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              SizedBox(height: 14),
              tile(context, 'jpg', 'JPEG',
                  '檔案小很多（約 1/8），肉眼看不出跟 PNG 差別'),
              SizedBox(height: 8),
              tile(context, 'png', 'PNG 無損', '完全不壓縮'),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 挑一個顏色。回傳 ARGB 整數，取消回 null。
///
/// 這段本來在六個地方各寫了一份（浮水印面板、照片馬賽克、
/// 影片文字描邊、影片文字顏色、影片馬賽克、拼圖格線），
/// 完全一樣的程式碼，只有拼圖那份標題寫「格線顏色」
Future<int?> pickColor(
  BuildContext context,
  Color initial, {
  String title = '顏色',
}) async {
  var color = initial;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
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
  return ok == true ? color.toARGB32() : null;
}

/// 離開編輯畫面時的三選一：保留／捨棄／繼續編輯。
/// 回傳 'keep'、'discard'、'stay'。
///
/// 影片、照片、工作室的離開對話框本來各寫一份，寬度、按鈕高度、
/// 間距都不一樣。統一走這裡
Future<String> showLeaveChoice(
  BuildContext context, {
  required String title,
  required String message,
  required String keepLabel,
  String discardLabel = '捨棄',
}) async {
  final c = pageColors(context);
  final act = await showDialog<String>(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: kDialogWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 26, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: c.text)),
              SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: c.dim, height: 1.55)),
              SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC'),
                ),
                onPressed: () => Navigator.pop(context, 'keep'),
                child: Text(keepLabel),
              ),
              SizedBox(height: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  foregroundColor: c.text,
                  side: BorderSide(color: c.line),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(context, 'discard'),
                child: Text(discardLabel,
                    style: TextStyle(fontSize: 13.5)),
              ),
              SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context, 'stay'),
                style: TextButton.styleFrom(
                  foregroundColor: c.dim,
                  minimumSize: const Size.fromHeight(40),
                ),
                child: Text('繼續編輯',
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

/// 預覽與面板之間的控制列：上一步／重做。
///
/// 四個編輯畫面都用這一條。原本工作室與批次把它放在標題列右上角，
/// 但那個位置在大螢幕手機上拇指按不到，而上一步是高頻動作
Widget undoRedoBar({
  required VoidCallback? onUndo,
  required VoidCallback? onRedo,
  List<Widget> leading = const [],
}) {
  // 按鈕收到最小高度：這條列夾在預覽跟面板中間，IconButton 預設的
  // 觸控高度會把兩邊撐出一大截空白（使用者：「間隔太多」）
  Widget btn(IconData icon, String tip, VoidCallback? onTap) => IconButton(
        tooltip: tip,
        icon: Icon(icon, size: 20, color: onTap != null ? kIcon : kTextDim),
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 42, minHeight: 30),
      );

  // 不畫上下邊線：整個工作區走無邊線的風格，靠色階分層就夠了
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    color: kBg,
    child: Row(
      children: [
        ...leading,
        const Spacer(),
        btn(Icons.undo, '上一步', onUndo),
        btn(Icons.redo, '重做', onRedo),
      ],
    ),
  );
}

/// 主要動作鈕（輸出／匯出／完成）。膠囊、46 高、圖示 18、14pt。
///
/// 影片編輯不用這顆——它的匯出是一個「分頁」而不是一顆浮在面板上的
/// 按鈕，結構本來就不同，硬套過去只會讓那一頁更奇怪
Widget primaryAction({
  required String label,
  required VoidCallback? onPressed,
  IconData icon = Icons.ios_share,
}) => FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 14)),
    );

/// 次要動作鈕（存成範本…）：跟主要鈕同高同圓角，只差描邊
Widget secondaryAction({
  required String label,
  required VoidCallback? onPressed,
  IconData? icon,
}) => OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        foregroundColor: kText,
        side: const BorderSide(color: kClipBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      icon: Icon(icon ?? Icons.bookmark_add_outlined, size: 17),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );

/// 選單彈窗裡的一列（畫面比例／解析度／畫質都用這個）。
/// 選中的那列標題轉琥珀色＋粗體，右邊打勾；[trailing] 放檔案大小之類的
/// 數字，[badge] 放「推薦」那種小標
Widget optionRow({
  required BuildContext context,
  required String title,
  required bool selected,
  required VoidCallback onTap,
  String? subtitle,
  String? trailing,
  String? badge,
  bool first = false,
}) {
  final c = pageColors(context);
  return InkWell(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: c.panelHi)),
            ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 標題一律粗體。本來是「選中才粗」，在深底上淺字
                    // 看起來本來就重，換到白底就變得又細又小——同一段
                    // 程式碼、兩種底色，讀起來完全不是同一回事。
                    // 選中與否改用顏色分，不用粗細分
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: selected ? c.accent : c.text,
                      ),
                    ),
                    if (badge != null) ...[
                      SizedBox(width: 6),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(kTagRadius),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: c.accent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: c.dim,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null)
            Text(
              trailing,
              style: TextStyle(
                fontSize: 12,
                color: selected ? c.accent : c.dim,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (selected) ...[
            SizedBox(width: 6),
            Icon(Icons.check, size: 17, color: c.accent),
          ],
        ],
      ),
    ),
  );
}

/// 點到重疊處時的說明。三個編輯畫面講同一句
String overlapHint(int layers) => '這裡疊了 $layers 層，再點一次選下面那層';

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


// ===== 淺色頁面（編輯畫面以外全部走這一套）=====
//
// 編輯畫面留黑：畫面上唯一該亮的是使用者的素材，UI 一亮就搶戲。
// 但主畫面、範本、個人頁這些「不看素材」的頁面沒有這個限制，白底
// 讀起來輕鬆得多，也跟系統的相簿、設定同一個調性
/// 頁面底＝純白。
///
/// 一度改成 #F7F7F9，為的是讓純白卡「浮」起來；但那讓整頁看起來灰灰的。
/// 改回純白之後卡片改用髮絲邊線分層（見 lightCard），不靠底色差
const kLBg = Color(0xFFFFFFFF);

/// 浮在頁面上的面：卡片、對話框、抽屜、輸入框
const kLCard = Color(0xFFFFFFFF);
const kLPanel = kLCard; // 沿用舊名：面板就是卡片那一層
const kLPanelHi = Color(0xFFECECF0); // 面板亮階（選中底）
const kLBorder = Color(0xFFE3E3E8); // 邊線
const kLText = Color(0xFF121216);
const kLTextDim = Color(0xFF70707A);
const kLIcon = Color(0xFF44444C);

/// 淺色頁的強調色。深色頁用純白，白底上當然不能用白——
/// 一樣走無彩色，換成近黑
const kLAccent = Color(0xFF121216);

/// 卡片裡那塊圖示磚的底。比卡片本身深一階，但不能用 kLPanelHi——
/// 卡片已經是純白＋陰影了，磚再灰下去整張會顯髒
const kLTile = Color(0xFFF2F2F6);

/// 淺色頁的卡片：純白底＋一條髮絲邊線，不打陰影。
///
/// 頁面是純白的，所以分層只能靠邊線。陰影在淺色頁上會拖出一條灰邊，
/// 而且只有往下那一層時上緣會消失，整張卡看起來像一段浮著的文字
BoxDecoration lightCard({double radius = kCardRadius}) => BoxDecoration(
      color: kLCard,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFFEDEDF2), width: 1.4),
    );

ThemeData buildLightTheme() {
  const scheme = ColorScheme.light(
    primary: kLAccent,
    onPrimary: kLCard,
    secondary: kLAccent,
    onSecondary: kLCard,
    surface: kLBg,
    onSurface: kLText,
    surfaceContainerHighest: kLPanelHi,
    outline: kLBorder,
    error: Color(0xFFD1373A),
  );
  final radius6 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
  final cardShape =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCardRadius));

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'NotoSansTC',
    scaffoldBackgroundColor: kLBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kLBg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansTC',
        fontSize: 17,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.0,
        color: kLText,
      ),
      iconTheme: IconThemeData(color: kLIcon, size: 22),
      actionsIconTheme: IconThemeData(color: kLIcon, size: 22),
    ),
    iconTheme: const IconThemeData(color: kLIcon),
    cardTheme: CardThemeData(
      color: kLPanel,
      elevation: 0,
      shape: cardShape.copyWith(side: const BorderSide(color: kLBorder)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kLAccent,
        foregroundColor: kLCard,
        shape: radius6,
        textStyle: const TextStyle(
            fontWeight: FontWeight.w700, fontSize: 14, fontFamily: 'NotoSansTC'),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kLAccent, shape: radius6),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kLText,
        side: const BorderSide(color: kLBorder),
        shape: radius6,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: kLPanel,
      selectedColor: kLPanelHi,
      side: const BorderSide(color: kLBorder),
      shape: radius6,
      labelStyle: const TextStyle(
          fontSize: 12, color: kLText, fontFamily: 'NotoSansTC'),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: kLAccent,
      unselectedLabelColor: kLTextDim,
      indicatorColor: kLAccent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: kLBorder,
      labelStyle: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'NotoSansTC'),
      unselectedLabelStyle: TextStyle(fontSize: 12, fontFamily: 'NotoSansTC'),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: kLAccent,
      inactiveTrackColor: kLPanelHi,
      thumbColor: kLAccent,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6.5),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      trackHeight: 2.5,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? kLBg : kLTextDim),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? kLAccent : kLPanelHi),
      trackOutlineColor: const WidgetStatePropertyAll(kLBorder),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? kLAccent : kLTextDim),
    ),
    dividerTheme: const DividerThemeData(color: kLBorder, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: kLCard,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      elevation: 8,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kDialogRadius),
          side: const BorderSide(color: kLBorder)),
      titleTextStyle: const TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          color: kLText,
          fontFamily: 'NotoSansTC'),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: kLText,
      contentTextStyle: const TextStyle(color: kLCard, fontFamily: 'NotoSansTC'),
      shape: radius6,
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      // 輸入框要比卡片深一階才看得出「這裡可以打字」。
      // kLPanel 現在等於純白，填了跟沒填一樣
      fillColor: const Color(0xFFF4F4F7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: kLBorder)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: kLAccent, width: 1.5)),
      labelStyle: const TextStyle(color: kLTextDim, fontSize: 13),
      hintStyle: const TextStyle(color: kLTextDim, fontSize: 13),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: kLIcon,
      textColor: kLText,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: kLCard,
      modalBackgroundColor: kLCard,
      modalBarrierColor: Colors.black.withValues(alpha: 0.35),
      elevation: 8,
      dragHandleColor: const Color(0xFFC4C4CC),
      dragHandleSize: const Size(34, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        side: BorderSide(color: kLBorder),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: kLAccent,
      linearTrackColor: kLPanelHi,
    ),
  );
}

/// 把一頁換成淺色。編輯畫面以外的頁面都包這個。
///
/// 包一層 Theme 而不是把 App 的預設換掉：編輯畫面的顏色大量寫死在
/// k 開頭的常數裡（那是刻意的，它們要跟素材一起看），整包換掉的話
/// 那些頁面會變成半黑半白
class LightPage extends StatelessWidget {
  final Widget child;

  const LightPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        // 白底要配深色的狀態列圖示，不然電量、時間全看不見
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: kLBg,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: Theme(data: buildLightTheme(), child: child),
      );
}
