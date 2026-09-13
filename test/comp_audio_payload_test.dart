// 合成播放器 payload 的「聲音片段」契約。
//
// iOS 預設走合成模式：合成接手後逐片段播放器全被放掉（_trimPlayers），
// 而 build 的 payload 以前只有 clips/mosaics/stills/overlays——配樂、旁白、
// 「從影片提取聲音」的片段在預覽完全無聲，匯出卻有聲（匯出的 payload
// 一直都有 audios）。修法是 Dart 端照原生匯出一模一樣的欄位送 audios，
// Swift 端共用同一個解析器。這裡釘住：
//   1. 欄位集合就是匯出那一套：path/start/end/offset/volume/speed/fadeIn/fadeOut
//   2. 隱藏軌不進、整軌靜音烘成音量 0、還掛 reverse 旗標的不進
//   3. 編輯器的指紋（_compSig）有把聲音片段算進去：加了音樂要重組
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';

/// 跟 native_export 的 audios 一模一樣的鍵（Swift 端一個解析器吃兩邊）
const _exportAudioKeys = {
  'id', // stable clip identity for live volume updates
  'path',
  'start',
  'end',
  'offset',
  'volume',
  'speed',
  'fadeIn',
  'fadeOut',
};

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  const ch = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> sent;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
    for (final c in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(c),
        (_) async => null,
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    sent = [];
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          sent.add(call.arguments as Map<Object?, Object?>);
          return <String, dynamic>{
            'textureId': 1,
            'duration': 8.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'setHiddenImageTracks':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
  });

  /// 影片 0~5 秒在軌 0（給 workPath＝不探 HDR、不碰檔案系統）
  TimelineModel base() {
    final tl = TimelineModel();
    tl.sources.add(
      MediaSource(
        path: '/a.mp4',
        name: 'a',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/a.work.mp4',
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      ),
    );
    return tl;
  }

  /// 配樂：素材 [path]，取 [trimStart]~[trimEnd]，放在 [at] 秒、軌 [track]
  TimelineClip addAudio(
    TimelineModel tl, {
    String path = '/m.m4a',
    double trimStart = 1,
    double trimEnd = 4,
    double at = 0.5,
    int track = 1,
    double volume = 0.7,
    double speed = 1.5,
    double fadeIn = 0.25,
    double fadeOut = 0.5,
    bool reverse = false,
  }) {
    tl.sources.add(
      MediaSource(path: path, name: 'm', kind: ClipKind.audio, duration: 30),
    );
    final c = TimelineClip(
      id: tl.nextId(),
      sourceIndex: tl.sources.length - 1,
      trimStart: trimStart,
      trimEnd: trimEnd,
      offset: at,
      track: track,
      volume: volume,
      speed: speed,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
      reverse: reverse,
    );
    tl.clips.add(c);
    return c;
  }

  List<Map<Object?, Object?>> audiosOf(Map<Object?, Object?> payload) =>
      (payload['audios'] as List<Object?>).cast<Map<Object?, Object?>>();

  group('CompPlayer.build 的 audios', () {
    test('配樂片段：欄位跟原生匯出的 audios 一模一樣、值照片段送', () async {
      final tl = base();
      addAudio(tl);
      expect(await CompPlayer.build(tl), isNotNull);
      expect(sent, hasLength(1));
      expect(sent.single.containsKey('audios'), isTrue, reason: '鍵一定要送');

      final au = audiosOf(sent.single);
      expect(au, hasLength(1));
      final a = au.single;
      expect(
        a.keys.cast<String>().toSet(),
        _exportAudioKeys,
        reason: 'Swift 端共用匯出的解析器：鍵不能多也不能少',
      );
      expect(a['path'], '/m.m4a');
      expect(a['start'], 1.0, reason: 'start＝trimStart');
      expect(a['end'], 4.0, reason: 'end＝trimEnd');
      expect(a['offset'], 0.5);
      expect(a['volume'], 0.7);
      expect(a['speed'], 1.5);
      expect(a['fadeIn'], 0.25);
      expect(a['fadeOut'], 0.5);
    });

    test('沒有聲音片段：audios 是空清單（鍵照送，Swift 端不用判 nil）', () async {
      final tl = base();
      expect(await CompPlayer.build(tl), isNotNull);
      expect(sent.single['audios'], isA<List<Object?>>());
      expect(sent.single['audios'], isEmpty);
    });

    test('整軌靜音：音量烘成 0（跟影片片段、跟匯出同一套）', () async {
      final tl = base();
      addAudio(tl, track: 1, volume: 0.9);
      expect(await CompPlayer.build(tl, mutedTracks: {1}), isNotNull);
      expect(audiosOf(sent.single).single['volume'], 0.0);
    });

    test('隱藏軌：整條不進（畫面與聲音都不進，跟匯出一致）', () async {
      final tl = base();
      addAudio(tl, track: 1);
      addAudio(tl, path: '/n.m4a', track: 2, at: 2);
      expect(await CompPlayer.build(tl, hiddenTracks: {1}), isNotNull);
      final au = audiosOf(sent.single);
      expect(au, hasLength(1));
      expect(au.single['path'], '/n.m4a');
    });

    test('音量超過 1 夾回 1（跟匯出同一個 clamp）', () async {
      final tl = base();
      addAudio(tl, volume: 1.7);
      expect(await CompPlayer.build(tl), isNotNull);
      expect(audiosOf(sent.single).single['volume'], 1.0);
    });

    test('還掛著 reverse 旗標的聲音片段不進（播放器倒不了，正著播更誤導）', () async {
      final tl = base();
      addAudio(tl, reverse: true);
      expect(await CompPlayer.build(tl), isNotNull);
      expect(sent.single['audios'], isEmpty);
    });

    test('影片片段本身不會跑進 audios（它們走 clips）', () async {
      final tl = base();
      expect(await CompPlayer.build(tl), isNotNull);
      expect(sent.single['audios'], isEmpty);
      expect(sent.single['clips'], hasLength(1));
    });
  });

  // ── 編輯器的指紋：加了音樂要重組，不然 payload 有 audios 也沒用 ──
  testWidgets('加入配樂之後合成要重組，而且新的 payload 帶著它', (t) async {
    late TimelineModel tl;
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
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
    });
    await _tick(t, 15);
    expect(sent, hasLength(1), reason: '影片接上就組一次');
    expect(sent.last['audios'], isEmpty);

    // 加一段配樂：trim/offset 之類影片的欄位一個都沒變，只有聲音片段
    // 多了一段——以前的指紋只記影片，這裡不會重組
    VideoEditorScreen.debugTimeline!((m) {
      addAudio(m, at: 1, trimStart: 0, trimEnd: 3);
    });
    await _tick(t, 15);
    expect(sent, hasLength(2), reason: '加了音樂要重組');
    final au = audiosOf(sent.last);
    expect(au, hasLength(1));
    expect(au.single['path'], '/m.m4a');
    expect(au.single['offset'], 1.0);

    // 把配樂往後搬：一樣只動聲音片段，也要重組
    VideoEditorScreen.debugTimeline!((m) {
      m.clips.last.offset = 2;
    });
    await _tick(t, 15);
    expect(sent, hasLength(3), reason: '搬動配樂要重組');
    expect(audiosOf(sent.last).single['offset'], 2.0);
    expect(tl.clips, hasLength(2));
    await _tick(t, 100);
  });
}
