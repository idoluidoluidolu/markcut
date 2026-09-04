// 多選素材進時間軸的順序＝使用者在相簿裡點選的順序（使用者指定）。
//
// 三條入口都用真的編輯頁跑：
// 1. 首頁多選影片 → VideoEditorScreen(videoPaths)
// 2. 首頁多選照片「串成一段影片」 → VideoEditorScreen(photoPaths)
// 3. 編輯頁「加素材 → 圖片」多選（ImagePicker.pickMultiImage）
//
// 守的是「不能照完成順序接」：每支素材的中繼資料探測故意讓第一支最慢、
// 最後一支最快，長度也各不相同——要是哪天匯入改成並行、誰探完誰先
// 接上去，這裡就會紅。名稱刻意亂排（c、a、b），照名稱排序也會紅
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';

/// 8×8 PNG（測試自己寫出來，不依賴任何外部檔案）
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';

late Directory _dir;

/// 每支「影片」的長度與探測延遲（毫秒）：第一支最慢、最後一支最快，
/// 長度也不按檔名、不按位置排
const _videos = <String, ({double dur, int delayMs})>{
  'c_long.mp4': (dur: 9.0, delayMs: 240),
  'a_short.mp4': (dur: 2.0, delayMs: 20),
  'b_mid.mp4': (dur: 5.0, delayMs: 120),
  'd_tiny.mp4': (dur: 1.0, delayMs: 5),
};

String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

Future<void> _settle(WidgetTester t, [int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 拿到時間軸快照（透過編輯頁的測試鉤子）
TimelineModel _tl() {
  late TimelineModel out;
  VideoEditorScreen.debugTimeline!((tl) => out = tl);
  return out;
}

/// 第 [track] 軌的片段照時間排，回每段的素材路徑與起點
List<({String path, double offset, double len})> _lane(
  TimelineModel tl,
  int track,
) {
  final clips = tl.clips.where((c) => c.track == track).toList()
    ..sort((a, b) => a.offset.compareTo(b.offset));
  return [
    for (final c in clips)
      (path: tl.sourceOf(c).path, offset: c.offset, len: c.length),
  ];
}

/// 假的 image_picker 平台端：多選圖片回固定清單（順序＝「點選順序」）
class _FakeImagePicker extends ImagePickerPlatform {
  _FakeImagePicker(this.files);
  final List<XFile> files;

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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_import_order_');
    final png = base64Decode(_pngB64);
    for (final n in const ['c.png', 'a.png', 'b.png']) {
      File(_p(n)).writeAsBytesSync(png);
    }
    // 影片只要「檔案存在」就好（探測結果由假通道回）
    for (final n in _videos.keys) {
      File(_p(n)).writeAsStringSync('video $n');
    }
    // 匯入會在背景備工作檔：測試環境沒有 path_provider，資料夾直接指過來
    WorkFiles.supportDirOverride = _dir;
    WorkFiles.holdSweep = false;

    final b = TestWidgetsFlutterBinding.ensureInitialized();
    // 測試環境沒有這些原生外掛，擋掉不然頁面一開就丟例外
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    // path_provider 回真的暫存目錄：回 null 的話 getTemporaryDirectory
    // 會丟 MissingPlatformDirectoryException
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _dir.path,
    );
    // FFmpeg 的事件通道：測試環境沒有原生端，不擋的話光是訂閱
    // 就會丟出沒人接的 MissingPluginException
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.arthenica.com/ffmpeg_kit'),
      (_) async => null,
    );
    // 中繼資料探測：照檔名回長度，並故意讓完成順序跟輸入順序相反
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            final path = call.arguments as String;
            final name = path.split(Platform.pathSeparator).last;
            final v = _videos[name];
            if (v == null) return null;
            await Future<void>.delayed(Duration(milliseconds: v.delayMs));
            return <String, dynamic>{
              'w': 1920,
              'h': 1080,
              'codec': 'avc1',
              'rotated': false,
              'sdr709': true,
              'durSec': v.dur,
            };
          case 'probe':
            // 關鍵幀夠密＝規格已合，工作檔只是複製一份（不用假轉檔）
            return <String, dynamic>{
              'frames': 300,
              'keyframes': 60,
              'maxGopFrames': 6,
            };
        }
        return null;
      },
    );
  });

  /// 收尾：讓提示條、合成器延遲刷新之類的計時器走完，
  /// 不然測試框架會抱怨「widget 樹拆了還有 Timer 掛著」
  Future<void> drain(WidgetTester t) async {
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(seconds: 3));
  }

  testWidgets('首頁多選影片：時間軸順序＝點選順序，不是探測完成順序', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // 亂序輸入：最慢的排第一、最快的排最後；名稱與長度都不單調
    final picked = [
      _p('c_long.mp4'),
      _p('a_short.mp4'),
      _p('b_mid.mp4'),
      _p('d_tiny.mp4'),
    ];
    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(videoPaths: picked)));
    await _settle(t, 60);

    final lane = _lane(_tl(), 0);
    expect(
      [for (final c in lane) c.path],
      picked,
      reason: '第 1 軌的片段要照挑選順序排',
    );
    // 頭尾相接：每段起點＝前面所有段的長度總和（照輸入順序累加）
    var at = 0.0;
    for (var i = 0; i < lane.length; i++) {
      expect(lane[i].offset, closeTo(at, 0.001), reason: '第 ${i + 1} 段的起點');
      final name = picked[i].split(Platform.pathSeparator).last;
      expect(lane[i].len, closeTo(_videos[name]!.dur, 0.001));
      at += lane[i].len;
    }
    await drain(t);
  });

  testWidgets('首頁多選照片串成影片：照點選順序接', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final picked = [_p('c.png'), _p('a.png'), _p('b.png')];
    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(photoPaths: picked)));
    await _settle(t, 10);
    // 進場先問每張幾秒
    expect(find.text('3 張圖片串成影片'), findsOneWidget);
    await t.tap(find.text('加入'));
    await _settle(t, 20);

    final lane = _lane(_tl(), 0);
    expect([for (final c in lane) c.path], picked);
    expect([for (final c in lane) c.offset], [0.0, 3.0, 6.0]);
    await drain(t);
  });

  testWidgets('編輯頁「加素材 → 圖片」多選：照點選順序接', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final picked = [_p('b.png'), _p('c.png'), _p('a.png')];
    final prev = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _FakeImagePicker([
      for (final p in picked) XFile(p, name: p.split(Platform.pathSeparator).last),
    ]);
    addTearDown(() => ImagePickerPlatform.instance = prev);

    await t.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(blank: true)),
    );
    await _settle(t, 10);

    await t.tap(find.text('加素材'));
    await _settle(t, 10);
    await t.tap(find.text('圖片'));
    await _settle(t, 15);
    expect(find.text('3 張圖片串成影片'), findsOneWidget);
    await t.tap(find.text('加入'));
    await _settle(t, 20);

    final tl = _tl();
    // 圖片放到新的一層（空專案＝第 1 軌）；不管落在哪一軌，同一軌內要照順序
    final track = tl.clips.first.track;
    final lane = _lane(tl, track);
    expect([for (final c in lane) c.path], picked);
    expect([for (final c in lane) c.offset], [0.0, 3.0, 6.0]);
    await drain(t);
  });
}
