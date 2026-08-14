// 「調整片段順序」那張表的畫面快照（golden）。
//
// 產生／更新圖片：
//   flutter test --update-goldens test/reorder_sheet_golden_test.dart
//
// 這張表是橫排縮圖，版面比直排清單脆弱（卡片寬度、序號、長度、
// 底部漸層都靠絕對位置疊），改壞了 golden 會立刻對不上。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/screens/video_editor_screen.dart';

late final List<String> _imgs;

/// 三張純色小圖當縮圖，長度各不相同——快照才看得出序號與長度
/// 是不是各自對到自己那張卡
const _pngs = <List<int>>[
  [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 16, 0, 0, 0, 16, 8, 2, 0, 0, 0, 144, 145, 104, 54, //
    0, 0, 0, 25, 73, 68, 65, 84, 120, 218, 99, 140, 201, 104, 96, 32, 5, //
    48, 49, 144, 8, 70, 53, 140, 106, 24, 58, 26, 0, 17, 224, 1, 100, //
    127, 148, 104, 21, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ],
  [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 16, 0, 0, 0, 16, 8, 2, 0, 0, 0, 144, 145, 104, 54, //
    0, 0, 0, 25, 73, 68, 65, 84, 120, 218, 99, 236, 73, 136, 96, 32, 5, //
    48, 49, 144, 8, 70, 53, 140, 106, 24, 58, 26, 0, 18, 56, 1, 100, //
    218, 44, 63, 229, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ],
  [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 16, 0, 0, 0, 16, 8, 2, 0, 0, 0, 144, 145, 104, 54, //
    0, 0, 0, 25, 73, 68, 65, 84, 120, 218, 99, 140, 168, 200, 96, 32, 5, //
    48, 49, 144, 8, 70, 53, 140, 106, 24, 58, 26, 0, 237, 61, 1, 88, //
    148, 228, 224, 126, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ],
];

const _lens = [7.9, 5.1, 3.6];

Map<String, dynamic> _draft() {
  var at = 0.0;
  final clips = <Map<String, dynamic>>[];
  for (var i = 0; i < 3; i++) {
    clips.add(
      TimelineClip(
        id: i + 1,
        sourceIndex: i,
        trimStart: 0,
        trimEnd: _lens[i],
        offset: at,
        track: 0,
      ).toJson(),
    );
    at += _lens[i];
  }
  return {
    'savedAt': '2026-08-14T00:00:00.000',
    'sources': [
      for (var i = 0; i < 3; i++)
        MediaSource(
          path: _imgs[i],
          name: 'clip$i.png',
          kind: ClipKind.image,
          w: 1080,
          h: 1920,
          duration: 3600,
        ).toJson(),
    ],
    'clips': clips,
    'speed': 1.0,
    'ratio': 0,
    'res': 0,
    'quality': 0,
    'wmStart': 0.0,
    'extraTracks': 0,
  };
}

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

    for (final path in const [
      'assets/fonts/NotoSansTC.ttf',
      'assets/fonts/NotoSansTC-Bold.ttf',
    ]) {
      final loader = FontLoader('NotoSansTC')
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }

    final dir = Directory.systemTemp.createTempSync('markcut_reorder');
    _imgs = [
      for (var i = 0; i < 3; i++)
        '${dir.path}${Platform.pathSeparator}c$i.png',
    ];
    for (var i = 0; i < 3; i++) {
      File(_imgs[i]).writeAsBytesSync(_pngs[i]);
    }

    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1125, 2436);
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
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  testWidgets('調整片段順序：橫排縮圖', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: VideoEditorScreen(draft: _draft()),
      ),
    );
    await _settle(tester);

    await tester.tap(find.text('排序'));
    await _settle(tester);

    // 抓 MaterialApp：底部表單畫在 Navigator 的 overlay 上
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/reorder_sheet.png'),
    );
  });
}
