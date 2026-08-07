import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/home_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 播放引擎（Web 用不到也沒帶函式庫）
  if (!kIsWeb) MediaKit.ensureInitialized();
  // 拖曳預覽的快取幀很密（8fps），預設 100 張的圖片快取一下就滿、
  // 一滿就得重新解碼＝拖曳卡頓。放大到能裝下數秒份的幀
  PaintingBinding.instance.imageCache
    ..maximumSize = 900
    ..maximumSizeBytes = 320 << 20; // 320MB
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
        // 點任何非輸入元件的地方就收鍵盤（全 App 生效）。
        // translucent＋不吃掉事件：底下的按鈕照樣正常反應
        builder: (context, child) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: child,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
