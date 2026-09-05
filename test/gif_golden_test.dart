// GIF 相關畫面的快照。Web 版沒有 FFmpeg 所以那些入口是隱藏的，
// 在瀏覽器裡看不到——這裡用 widget test 把它們畫出來。
//
//   flutter test --update-goldens test/gif_golden_test.dart
//
// 產生／更新圖片：
//   flutter test --update-goldens test/export_tab_golden_test.dart
// 圖片會寫在 test/goldens/ 底下。
//
// 這支測試同時是回歸保護：匯出頁的版面或文案被改動時，
// golden 對不上就會失敗，改動一定是有意識的。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/profile_screen.dart';

late final String _tmpDir;
late final String _imgPath;
late final String _vidPath;

/// 素材：一張真的 PNG 當畫面上的片段，外加一支「有檔案、沒片段」的
/// 影片素材——匯出頁的畫質是依素材的位元率（檔案大小÷長度）挑的，
/// 沒有影片素材就量不到位元率，也就看不到「自動」那個狀態。
/// 不掛片段是因為掛了就要開播放器，測試環境沒有原生外掛
Map<String, dynamic> _draft() => {
  'savedAt': '2026-08-14T00:00:00.000',
  'sources': [
    MediaSource(
      path: _imgPath,
      name: 'photo.png',
      kind: ClipKind.image,
      w: 1080,
      h: 1920,
      duration: 3600,
    ).toJson(),
    MediaSource(
      path: _vidPath,
      name: 'clip.mp4',
      kind: ClipKind.video,
      w: 1920,
      h: 1080,
      duration: 10,
    ).toJson(),
  ],
  'clips': [
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 12,
      offset: 0,
      track: 0,
    ).toJson(),
  ],
  'speed': 1.0,
  'ratio': 0,
  'res': 0,
  'quality': 0,
  'qualityAuto': true,
  'wmStart': 0.0,
  'extraTracks': 0,
};

Future<void> _settle(WidgetTester t, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();

    // 真的把 App 的字體載進來，不然中文全是空白框，快照看了也沒用
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(
          File(path).readAsBytes().then((b) => b.buffer.asByteData()),
        );
      await loader.load();
    }

    final dir = Directory.systemTemp.createTempSync('markcut_golden');
    _tmpDir = dir.path;
    _imgPath = '${dir.path}${Platform.pathSeparator}photo.png';
    _vidPath = '${dir.path}${Platform.pathSeparator}clip.mp4';
    // 1×1 的透明 PNG：只是要有個真的檔案讓草稿還原得動
    File(_imgPath).writeAsBytesSync(<int>[
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
      0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, //
      13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ]);
    // 10 秒、10 MB → 8 Mbps，正好是手機 1080p 錄影的量級。
    // 內容是什麼不重要，量的是檔案大小
    File(_vidPath).writeAsBytesSync(List<int>.filled(10 * 1024 * 1024, 0));

    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1125, 2436); // iPhone 尺寸
    v.devicePixelRatio = 3.0;

    for (final ch in const [
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    // path_provider 回真的暫存目錄：回 null 的話 getTemporaryDirectory
    // 會丟 MissingPlatformDirectoryException，縮圖那條路就整個炸開
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    // FFmpeg 的事件通道：測試環境沒有原生端，不擋的話光是訂閱
    // 就會丟出沒人接的 MissingPluginException
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  testWidgets('首頁：四顆入口（GIF 直接在首頁，不再藏在選單裡）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        debugShowCheckedModeBanner: false,
        home: const HomeScreen(),
      ),
    );
    await _settle(tester);
    // 四顆：浮水印／照片拼圖／GIF／影片編輯，圖示＋文字對齊在同一個 x
    //（圖示在這裡是空方框：測試環境沒載 Material Icons，跟其他快照一樣）
    expect(find.text('GIF'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home.png'),
    );
  });

  testWidgets('編輯器：加素材選單（多了 GIF）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: VideoEditorScreen(draft: _draft()),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('加素材'));
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/gif_add_menu.png'),
    );
  });

  testWidgets('個人中心：我的 GIF', (tester) async {
    // 先放兩個真的 GIF 檔進 GifStore 的資料夾
    // path_provider 的 mock 把文件目錄指到 _tmpDir（見 setUpAll）
    final gifDir = Directory('$_tmpDir${Platform.pathSeparator}gifs');
    gifDir.createSync(recursive: true);
    // 最小的合法 GIF（1×1 透明）
    const gif = <int>[
      71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, //
      255, 255, 255, 33, 249, 4, 1, 10, 0, 1, 0, 44, 0, 0, 0, 0, //
      1, 0, 1, 0, 0, 2, 2, 76, 1, 0, 59,
    ];
    for (final n in ['a', 'b']) {
      File('${gifDir.path}${Platform.pathSeparator}gif_$n.gif')
          .writeAsBytesSync(gif);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        debugShowCheckedModeBanner: false,
        home: const ProfileScreen(),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/gif_profile.png'),
    );
  });
}
