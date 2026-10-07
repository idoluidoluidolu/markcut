// 迴歸（實機回報：「草稿沒有顯示縮圖」——個人中心最新的幾份草稿只剩
// 灰底＋膠卷圖示）。編輯器那頭修好之後（見 draft_cover_*_test），頁面這頭：
//
//   1. 已經沒有封面的草稿（那幾版存下來的）：個人中心顯示時補一張
//   2. 封面晚到（按「保留草稿」回到個人中心時，背景那張還在畫）：畫好要
//      換上去，不能停在灰底或上一版封面
//   3. 「查看全部」裡第四格以後的草稿也一樣補
//
// 只寫一支 testWidgets：DraftStore 的存檔佇列是靜態的，補封面在這支的
// 假時間裡排過隊，下一支測試接在後面就永遠排不到（見 draft_cover_harness）
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/theme.dart';

import 'editor_harness.dart' show solidPng;

/// 讀檔、解碼、背景 isolate 都是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 畫面上每一張草稿封面的位元組（Image.memory，照格子尺寸解碼）
List<Uint8List> _shownCovers(WidgetTester t) => [
  for (final image in t.widgetList<Image>(find.byType(Image)))
    if ((image.image is ResizeImage
            ? (image.image as ResizeImage).imageProvider
            : image.image)
        case final MemoryImage m)
      m.bytes,
];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('沒有封面的草稿補一張、晚到的封面換上去、查看全部也補', (t) async {
    late Directory dir;
    final photos = <String>[];
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('profile-cover-');
      for (var i = 1; i <= 5; i++) {
        final f = File('${dir.path}${Platform.pathSeparator}p$i.png');
        await f.writeAsBytes(solidPng(40 * i, 20, 200 - 30 * i, size: 40));
        photos.add(f.path);
      }
    });
    for (final ch in const [
      'markcut/frames',
      'markcut/pick',
      'flutter.arthenica.com/ffmpeg_kit',
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    addTearDown(() {
      for (final ch in const [
        'markcut/frames',
        'markcut/pick',
        'flutter.arthenica.com/ffmpeg_kit',
        'plugins.flutter.io/path_provider',
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(ch),
          null,
        );
      }
    });

    // 五份影片草稿（新到舊 p1…p5），素材是照片；只有 p2 有封面（版本 r1）
    final coverA = base64Encode(solidPng(255, 255, 0, size: 12));
    final coverB = base64Encode(solidPng(0, 255, 255, size: 12));
    final now = DateTime(2026, 10, 7, 12);
    final metas = <Map<String, dynamic>>[];
    final data = <String, Object>{
      'wm_presets_seeded_v1': true,
      'wm_presets_seeded_v2': true,
      'wm_presets_seeded_v3': true,
      'wm_presets_seeded_v4': true,
    };
    for (var i = 1; i <= 5; i++) {
      final id = 'p$i';
      final at = now.subtract(Duration(minutes: i)).toIso8601String();
      metas.add({
        'id': id,
        'createdAt': at,
        'savedAt': at,
        if (i == 2) 'hasThumb': true,
        if (i == 2) 'thumbAspect': 1.0,
        if (i == 2) 'coverRevision': 'r1',
        'clips': 1,
        'dur': 5.0,
      });
      data['project_data_$id'] = jsonEncode({
        'savedAt': at,
        'sources': [
          MediaSource(
            path: photos[i - 1],
            name: id,
            kind: ClipKind.image,
            duration: 5,
            w: 40,
            h: 40,
          ).toJson(),
        ],
        'clips': [
          TimelineClip(
            id: 1,
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 5,
            offset: 0,
            track: 0,
          ).toJson(),
        ],
      });
    }
    data['project_thumb_p2'] = coverA;
    data['projects_index_v1'] = jsonEncode(metas);
    SharedPreferences.setMockInitialValues(data);

    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: ProfileScreen()),
      ),
    );
    await _settle(t, 60);

    // 1. 四格都要有封面（第四格是「查看全部」，底下照樣是 p4 的封面）
    expect(
      find.byIcon(Icons.movie_outlined),
      findsNothing,
      reason: '沒有封面的草稿要補一張，不能是灰底膠卷',
    );
    expect(_shownCovers(t), hasLength(4));
    for (final id in ['p1', 'p3', 'p4']) {
      String? thumb;
      await t.runAsync(() async => thumb = await DraftStore.thumb(id));
      expect(thumb, isNotNull, reason: '$id 補的封面要存下來，下次不用再補');
    }
    expect(
      _shownCovers(t).map(base64Encode),
      contains(coverA),
      reason: '本來就有封面的照用',
    );

    // 2. 背景畫好的封面晚到（編輯器已經離開了）：換上去
    DraftStore.updateCover(
      'p2',
      revision: 'r1',
      thumb: coverB,
      aspect: 1,
    ).ignore();
    await _settle(t, 20);
    final shown = _shownCovers(t).map(base64Encode).toList();
    expect(shown, contains(coverB), reason: '封面換了要換上去');
    expect(shown, isNot(contains(coverA)), reason: '不能停在上一版封面');

    // 3. 「查看全部」：第五份（個人中心沒畫到）也要補
    await t.tap(find.byKey(const ValueKey('profile-drafts-more')));
    await _settle(t, 60);
    expect(find.byType(DraftsScreen), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
    String? p5;
    await t.runAsync(() async => p5 = await DraftStore.thumb('p5'));
    expect(p5, isNotNull);

    await t.pumpWidget(const SizedBox());
    await _settle(t, 10);
    await t.runAsync(() => dir.delete(recursive: true));
  });
}
