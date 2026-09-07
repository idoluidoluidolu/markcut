// 迴歸守門（稽核 #7）：上一步撤掉匯入之後再匯入，新素材不能沿用舊素材
// 的縮圖帶／拖曳格子。
//
// 縮圖帶、拖曳格子、最新一格、解碼器、裁切原圖、轉檔重試名單全都以
// 「素材索引」為鍵；復原是唯一會讓 sources 變短的路，而下一支匯入拿的
// 就是同一個索引。以前 _restoreSnapshot 只換 sources、不碰快取：加影片
// A（十張縮圖抽好）→ 上一步 → 加影片 B，_thumbsAfterPrep 看到那格已
// 有十張就跳過，B 的縮圖帶整條是 A 的。SDR 模式要等工作檔換上才順手
// 重抽；HDR 代理那條路不換檔，整場都不會修正。
//
// 兩支都走真的編輯頁：
//   1. 圖片（不需要原生探測）：加兩張 → 上一步 → 縮圖格子要清空；重做
//      → 從檔案讀回來；再上一步、換兩張加 → 是新的那兩張
//   2. 影片（HDR 代理失敗那條路，永遠不會換檔）：加 A（5 秒、十格）→
//      上一步 → 加 B（3 秒、假原生端只給六格）→ 縮圖帶要是 B 的六格，
//      不是 A 留下的十格
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';

import 'editor_harness.dart';

late Directory _dir;
String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

/// 假的 image_picker 平台端：多選圖片回固定清單
class _FakeImagePicker extends ImagePickerPlatform {
  _FakeImagePicker(this.files);
  List<XFile> files;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => files;

  @override
  Future<List<XFile>> getMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
  }) async => files;
}

void main() {
  final red = solidPng(255, 0, 0);
  final blue = solidPng(0, 0, 255);
  final frame = solidPng(0, 255, 0);

  /// 「加素材 → 影片」時假的系統選取器回哪幾支
  var pickVideos = <String>[];

  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_undo_import_');
    File(_p('a.png')).writeAsBytesSync(red);
    File(_p('b.png')).writeAsBytesSync(blue);
    // 影片只要「檔案存在」就好（探測結果由假通道回）
    File(_p('a.mp4')).writeAsStringSync('video A');
    File(_p('b.mp4')).writeAsStringSync('video B');
    WorkFiles.supportDirOverride = _dir;
    WorkFiles.holdSweep = false;

    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b, tempDir: _dir);
    // 系統相片選取器（Android 13+ 那條路；測試主機的 defaultTargetPlatform
    // 是 android）
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/pick'),
      (call) async => call.method == 'videos' ? pickVideos : null,
    );
    // 中繼資料探測：a.mp4 5 秒、b.mp4 3 秒，都是 HDR（sdr709=false）；
    // HDR 代理轉檔一律失敗（toWorkFile 回 null）＝素材整場播原檔、不換檔
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            final path = call.arguments as String;
            final name = path.split(Platform.pathSeparator).last;
            if (!name.endsWith('.mp4')) return null;
            return <String, dynamic>{
              'w': 1920,
              'h': 1080,
              'codec': 'hvc1',
              'rotated': false,
              'sdr709': false,
              'durSec': name.startsWith('a') ? 5.0 : 3.0,
            };
          case 'probe':
            return <String, dynamic>{
              'frames': 300,
              'keyframes': 60,
              'maxGopFrames': 6,
            };
          case 'toWorkFile':
            return null;
        }
        return null;
      },
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/export'),
      (call) async => switch (call.method) {
        'available' || 'hasHDR' || 'isHDR' => true,
        _ => null,
      },
    );
    // 縮圖帶：a.mp4 十格都給；b.mp4 只給前 1.8 秒（3 秒十格＝六格）
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async {
        if (call.method != 'frameAt') return null;
        final a = Map<Object?, Object?>.from(call.arguments as Map);
        final path = a['path'] as String;
        final ms = (a['ms'] as num).toInt();
        if (path.endsWith('b.mp4') && ms > 1800) return null;
        return frame;
      },
    );
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
  });

  Future<void> addImages(WidgetTester t) async {
    await t.tap(find.text('加素材'));
    await settle(t, 10);
    await t.tap(find.text('圖片'));
    await settle(t, 15);
    expect(find.text('2 張圖片串成影片'), findsOneWidget);
    await t.tap(find.text('加入'));
    await settle(t, 20);
  }

  Future<void> addVideo(WidgetTester t, String path) async {
    pickVideos = [path];
    await t.tap(find.text('加素材'));
    await settle(t, 10);
    await t.tap(find.text('影片'));
    await settle(t, 20);
    await waitUntil(
      t,
      () =>
          modelOf(t).sources.length == 1 &&
          modelOf(t).sources.first.path == path,
      reason: '$path 要接上時間軸',
    );
  }

  testWidgets('圖片：上一步之後縮圖格子清空、重做長回來、再加是新的那兩張', (t) async {
    final picker = _FakeImagePicker([
      XFile(_p('a.png'), name: 'a.png'),
      XFile(_p('b.png'), name: 'b.png'),
    ]);
    final prev = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = prev);

    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 10);
    await addImages(t);
    expect(modelOf(t).sources.length, 2);
    expect(listEquals(editorOf(t).thumbs[0]?.firstOrNull, red), isTrue);
    expect(listEquals(editorOf(t).thumbs[1]?.firstOrNull, blue), isTrue);

    await t.tap(undoButton());
    await settle(t, 10);
    expect(modelOf(t).sources, isEmpty);
    expect(
      editorOf(t).thumbs,
      isEmpty,
      reason: '來源沒了，以索引為鍵的縮圖要一起作廢（下一支匯入拿的就是同一個索引）',
    );

    await t.tap(redoButton());
    await settle(t, 10);
    expect(modelOf(t).sources.length, 2);
    await waitUntil(
      t,
      () =>
          listEquals(editorOf(t).thumbs[0]?.firstOrNull, red) &&
          listEquals(editorOf(t).thumbs[1]?.firstOrNull, blue),
      reason: '重做：圖片的縮圖（也是圖層畫的那份位元組）要從檔案讀回來',
    );

    await t.tap(undoButton());
    await settle(t, 10);
    expect(editorOf(t).thumbs, isEmpty);
    picker.files = [
      XFile(_p('b.png'), name: 'b.png'),
      XFile(_p('a.png'), name: 'a.png'),
    ];
    await addImages(t);
    expect(modelOf(t).sources.length, 2);
    expect(listEquals(editorOf(t).thumbs[0]?.firstOrNull, blue), isTrue);
    expect(listEquals(editorOf(t).thumbs[1]?.firstOrNull, red), isTrue);
    // 讓併批的草稿存檔與提示跑完，別留計時器
    await settle(t, 80);
  });

  testWidgets('影片（HDR 代理失敗、整場不換檔）：上一步再加，縮圖帶是新素材自己的', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 10);

    await addVideo(t, _p('a.mp4'));
    expect(modelOf(t).clips.single.length, closeTo(5.0, 1e-6));
    await waitUntil(
      t,
      () => (editorOf(t).thumbs[0]?.length ?? 0) == 10,
      maxMs: 30000,
      reason: 'A 的十格縮圖帶要抽好（代理失敗後從原檔抽）',
    );

    await t.tap(undoButton());
    await settle(t, 10);
    expect(modelOf(t).sources, isEmpty);
    expect(editorOf(t).thumbs, isEmpty, reason: '來源沒了，縮圖帶一起作廢');

    await addVideo(t, _p('b.mp4'));
    expect(modelOf(t).clips.single.length, closeTo(3.0, 1e-6));
    await waitUntil(
      t,
      () => (editorOf(t).thumbs[0]?.length ?? 0) == 6,
      maxMs: 30000,
      reason: 'B 的縮圖帶是自己的六格，不是 A 留下的十格',
    );
    await settle(t, 80);
  });
}
