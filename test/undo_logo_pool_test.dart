// 復原快照的 Logo 池子也要涵蓋貼圖／浮水印素材的 wmStyle。
//
// 以前只有全域浮水印（_settings）的 logos[].b64 換成池子編號；素材上的
// wmStyle.logos[].b64（1024px PNG，一張幾百 KB）每次 _pushUndo 都整包
// jsonEncode 在主執行緒、60 份快照各存全量——放五張貼圖再拉一趟滑桿就是
// 幾十次 MB 級編碼。
//
// 池子的可觀察痕跡：復原之後素材拿回來的 b64 是池子裡「同一個」字串物件
//（identical），不是 jsonDecode 出來的新複本
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  const compCh = MethodChannel('markcut/comp');

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
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
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          return <String, dynamic>{
            'textureId': 1,
            'duration': 5.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'position':
          return 0;
        case 'setHiddenImageTracks':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  testWidgets('復原之後貼圖的 b64 是池子裡同一個字串（不是整包重編碼再解回來的）', (
    t,
  ) async {
    // 一張真的（8×8）PNG：預覽層會拿它解圖，內容要合法。在執行期重新編
    // 一次，拿到的是一個新的字串物件——字面常數會被編譯期共用，
    // identical 就分不出「池子的參照」跟「常數」
    final bigB64 = base64Encode(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
        'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=',
      ),
    );
    late TimelineModel tl;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: const VideoEditorScreen(blank: true),
      ),
    );
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!((m) {
      tl = m;
      m.sources.add(
        MediaSource(
          path: '/v.mp4',
          name: 'v',
          kind: ClipKind.video,
          duration: 100,
          workPath: '/v.work.mp4',
        ),
      );
      m.clips.add(
        TimelineClip(
          id: m.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 5,
          offset: 0,
          track: 0,
        ),
      );
      // 貼圖：沒有文字、只有一張圖的浮水印素材
      m.sources.add(
        MediaSource(
          path: '',
          name: '貼圖',
          kind: ClipKind.wm,
          duration: 3600,
          isSticker: true,
          wmStyle: WatermarkSettings(
            text: TextMark(text: ''),
            logo: LogoMark(enabled: true, b64: bigB64),
          ),
        ),
      );
      m.clips.add(
        TimelineClip(
          id: m.nextId(),
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 3,
          offset: 0,
          track: 1,
        ),
      );
    });
    await _tick(t, 15);
    expect(identical(tl.sources[1].wmStyle!.logo.b64, bigB64), isTrue);

    // 拍一份快照（修剪起手）→ 改點東西 → 上一步。
    // 拉 1 秒：太短會被磁吸吸回影片原本的結尾
    final tlWidget = t.widget<TimelineEditor>(find.byType(TimelineEditor));
    final videoId = tl.clips[0].id;
    tlWidget.onTrimStart!();
    tlWidget.onTrim(videoId, 1.0, false);
    tlWidget.onTrimEnd!();
    await _tick(t, 3);
    final before = tl.clips[0].trimEnd;
    await t.tap(find.byIcon(Icons.undo));
    await _tick(t, 5);

    expect(tl.clips[0].trimEnd, lessThan(before), reason: '真的退回去了');
    final restored = tl.sources[1].wmStyle!.logo.b64;
    expect(restored, bigB64, reason: '內容要一樣');
    expect(
      identical(restored, bigB64),
      isTrue,
      reason: '快照裡存的是池子編號：還原拿回來的是同一個字串物件，'
          '不是 jsonEncode 整包再 jsonDecode 出來的新複本',
    );
    await _tick(t, 100);
  });
}
