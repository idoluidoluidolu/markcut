import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/home_screen.dart';
import 'services/diagnostics.dart';
import 'services/steady_pointer.dart';
import 'services/playback_trace.dart';
import 'theme.dart';

void main() {
  // 一般是 WidgetsFlutterBinding.ensureInitialized()。換成自己那個
  // 是為了在事件進到手勢辨識之前濾掉「抬手那一下的位移」——
  // 全 App 的拖曳與滑桿都會經過這裡，見 SteadyPointerBinding
  SteadyPointerBinding.ensureInitialized();
  // Android：改用系統的相簿選取器。
  // 預設是關的，會走舊的 ACTION_GET_CONTENT——能不能一次選多個
  // 要看手機上是哪個相簿 App 接手，很多機型只選得到一個
  //（使用者回報「多支影片只能選一支」就是這個）。
  // 舊版 Android 沒有系統選取器時，androidx 會自動退到
  // ACTION_OPEN_DOCUMENT，那個的多選也比舊路徑可靠
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final picker = ImagePickerPlatform.instance;
    if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
  }
  // media_kit 播放引擎（Web 用不到也沒帶函式庫）
  if (!kIsWeb) MediaKit.ensureInitialized();
  // 上次執行有沒有做到一半就被系統收掉（匯出閃退不會留當機報告，
  // 只有這個黑盒子留得下現場）。讀完就刪，診斷畫面看得到
  unawaited(Diag.loadLastRun());
  // 草稿清理「不」在啟動時做：它要把每一份草稿的完整 JSON（含縮圖與
  // 圖片，一份好幾百 KB）讀進來比對引用，草稿多的機器等於在啟動路徑上
  // 掃幾十 MB——更新後第一次開就被系統judged 逾時殺掉（實機回報：開機即當）。
  // 改成進草稿頁時清一次、每次存草稿也各清一次（見 DraftStore.prune）
  // 拖曳預覽的快取幀很密，預設 100 張一下就滿、一滿就要重新解碼＝卡頓，
  // 所以要放大一點。但不能放太大：手機上這裡吃掉的記憶體會讓匯出時
  // FFmpeg 要不到記憶體、整個 App 被系統殺掉（拖曳的影格另有自己的
  // 解碼快取，不靠這個）
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 96 << 20; // 96MB
  // 內建字型的 OFL 與 FFmpeg 的 LGPL 聲明，登錄到系統授權清單
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['內建字型'],
      '本程式內建下列字型，皆以 SIL Open Font License 1.1 授權：\n'
      'Noto Sans TC / Noto Serif TC (Google, Adobe)\n'
      'jf open 粉圓 (justfont)\n'
      'LXGW WenKai TC (落霞孤鶩)\n'
      'Chocolate Classical Sans\n'
      'Montserrat / Playfair Display / Pacifico / Bebas Neue /\n'
      'Oswald / Lobster / Anton / Courier Prime\n\n'
      '完整授權條款見 https://scripts.sil.org/OFL',
    );
    yield const LicenseEntryWithLineBreaks(
      ['FFmpeg'],
      '本程式使用 FFmpeg（LGPL v2.1 或後續版本授權）進行影音處理，'
      'H.264 編碼使用裝置的硬體編碼器。\n'
      '浮水印 本身的程式碼以 Mozilla Public License 2.0 散布。\n\n'
      'FFmpeg 為其各自作者所有，詳見 https://ffmpeg.org',
    );
  });
  // 版本標填進診斷（播放診斷／播放偵測的第一行要能對版）
  PackageInfo.fromPlatform()
      .then((i) {
        appVersionTag = '${i.version}+${i.buildNumber}';
      })
      .catchError((_) {});
  runApp(const MarkCutApp());
}

class MarkCutApp extends StatelessWidget {
  const MarkCutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: kPerfOverlay,
      builder: (context, perf, _) => MaterialApp(
        title: '浮水印',
        debugShowCheckedModeBanner: false,
        showPerformanceOverlay: perf,
        theme: buildStudioTheme(),
        // 整個 App 的介面都是繁體中文，Flutter 自己畫的那些字串也要跟上：
        // 文字欄位的選單（貼上／全選／掃描文字）、日期選擇器、
        // 返回鍵的提示……不掛這幾個 delegate 一律是英文。
        // 語系直接釘在 zh-Hant-TW，不看系統設定——介面本來就沒有別的語言，
        // 選單跟著系統變英文反而不搭。
        // iOS 16+ 的文字選單是系統畫的，字串跟著 App 宣告的語系走，
        // 那一半在 ios/Runner/Info.plist 的 CFBundleLocalizations
        locale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'TW',
        ),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
          Locale('zh', 'TW'),
          Locale('zh'),
          Locale('en'),
        ],
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          // 系統字級最多吃到 1.2 倍。
          //
          // 這是剪輯 App，版面密度很高：時間軸、匯出頁、浮水印面板
          // 都是一行擠好幾個數值。完全放行的話開到 1.4 倍以上版面
          // 就會擠爆甚至被切掉，設計稿也永遠對不上（稿是 1.0 畫的）。
          // 1.2 是「看得出放大了、但版面撐得住」的界線。
          // 要完全尊重系統設定就把這一層拿掉
          maxScaleFactor: 1.2,
          // 點任何非輸入元件的地方就收鍵盤（全 App 生效）。
          // translucent＋不吃掉事件：底下的按鈕照樣正常反應
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: child,
          ),
        ),
        home: const LightPage(child: HomeScreen()),
      ),
    );
  }
}
