// 素材貼上要貼在指針目前的位置（使用者：「素材貼上應該貼上在指針目前位置」）。
//
// 影片／圖片／聲音同一軌不能疊。以前指針落在同軌某一段的身體裡時，貼上去
// 的那段會被吸到那一段的頭或尾——看起來就是沒貼在指針上。現在：
// - 指針在別段身上：在那一軌上面插一層新的，貼在指針上；原本那段不動、
//   不裁、不蓋
// - 指針在空隙裡：照舊貼在那一軌、指針上（身體壓到後面的段才推開）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
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
            'duration': 10.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  testWidgets('指針在同軌別段身上：插一層新的貼在指針上；在空隙裡：照舊貼在那一軌', (t) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _tick(t, 5);
    late TimelineModel tl;
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
    });
    await _tick(t, 15);
    final a = tl.clips.single;
    TimelineEditor timeline() =>
        t.widget<TimelineEditor>(find.byType(TimelineEditor));

    // 選 A、複製
    timeline().onSelect(a.id);
    await _tick(t, 3);
    await t.tap(find.text('複製'));
    await _tick(t, 3);

    // 指針移到 A 的身體裡（2.5 秒）再貼上
    timeline().onSeek(2.5);
    await _tick(t, 5);
    final tracksBefore = tl.usedTracks;
    await t.tap(find.text('貼上'));
    await _tick(t, 10);
    expect(tl.clips.length, 2);
    final p1 = tl.clips.firstWhere((c) => c.id != a.id);
    expect(p1.offset, 2.5, reason: '貼在指針上，不被吸到 A 的頭或尾');
    expect(a.offset, 0, reason: 'A 不動');
    expect(a.length, closeTo(5, 1e-9), reason: 'A 不被裁');
    expect(p1.track, lessThan(a.track), reason: '新的一層插在 A 上面');
    expect(tl.usedTracks, tracksBefore + 1);
    expect(tl.firstOverlapOnTracks(), isNull);
    expect(timeline().selectedId, p1.id, reason: '貼上的那段選起來');

    // 指針移到 A 那一軌的空隙（6 秒）、選 A 再貼：照舊貼在 A 那一軌
    timeline().onSelect(a.id);
    await _tick(t, 3);
    timeline().onSeek(6.0);
    await _tick(t, 5);
    final tracksMid = tl.usedTracks;
    await t.tap(find.text('貼上'));
    await _tick(t, 10);
    expect(tl.clips.length, 3);
    final p2 = tl.clips.firstWhere((c) => c.id != a.id && c.id != p1.id);
    expect(p2.offset, 6.0);
    expect(p2.track, a.track, reason: '空隙裡貼在原本那一軌');
    expect(tl.usedTracks, tracksMid, reason: '沒有多插一層');
    expect(a.offset, 0);
    expect(p1.offset, 2.5);
    expect(tl.firstOverlapOnTracks(), isNull);
    expect(t.takeException(), isNull);
  });
}
