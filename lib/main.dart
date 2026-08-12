import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/home_screen.dart';
import 'theme.dart';

/// 未捕捉錯誤的畫面顯示器：抓到什麼就貼在畫面最上面。
/// web 上錯誤只會進 console、畫面直接死掉看不到原因，
/// 這樣使用者截圖就能直接回報錯誤原文
final ValueNotifier<String?> kLastError = ValueNotifier(null);

void _reportError(Object e, StackTrace? s) {
  final text = '$e\n${s ?? ''}';
  kLastError.value = text.length > 700 ? text.substring(0, 700) : text;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _reportError(details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (e, s) {
    _reportError(e, s);
    return true;
  };
  // media_kit 播放引擎（Web 用不到也沒帶函式庫）
  if (!kIsWeb) MediaKit.ensureInitialized();
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
          child: Stack(
            children: [
              ?child,
              // 錯誤橫幅：有未捕捉錯誤時蓋在最上面，點「關閉」收掉
              ValueListenableBuilder<String?>(
                valueListenable: kLastError,
                builder: (context, err, _) {
                  if (err == null) return const SizedBox.shrink();
                  return Positioned(
                    left: 8,
                    right: 8,
                    top: 40,
                    child: Material(
                      color: const Color(0xE6470B0B),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    '出錯了，請截圖回報這個畫面',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => kLastError.value = null,
                                  child: const Text(
                                    '關閉',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              err,
                              maxLines: 14,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFFFD3D3),
                                fontSize: 10,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
