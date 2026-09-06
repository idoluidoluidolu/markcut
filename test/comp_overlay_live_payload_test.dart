// 合成播放器 payload 的「即時疊加物通道」契約（見 wm_hide_show_hdr_test
// 的故事）。
//
// HDR 預覽的浮水印／文字走原生 CI 合成器的即時清單（setOverlays）。
// 原生端掛不掛合成器以前只看「組建當下清單空不空」——浮水印隱藏中重建
// 就組出不收清單的合成，之後打開只能由 Flutter 畫（HDR 上就是灰的）。
// 現在 Dart 端用 ovLive 明講「這份合成要收即時清單」，跟清單空不空無關。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';

void main() {
  const ch = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> sent;

  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    sent = [];
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          sent.add(Map<Object?, Object?>.from(call.arguments as Map));
          return <String, dynamic>{'textureId': 1, 'duration': 5.0};
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
  });

  /// HDR 影片 0~5 秒（workHdrPath＝HDR 判定免探測，不碰檔案系統）
  TimelineModel tl() {
    final m = TimelineModel();
    m.sources.add(
      MediaSource(
        path: '/a.mov',
        name: 'a',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/a.work.mp4',
        workHdrPath: '/a.hlg.mp4',
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
    return m;
  }

  test('liveOverlays：清單空的也要送 ovLive（合成器留著、之後打開才收得下）', () async {
    expect(
      await CompPlayer.build(tl(), hdrOut: true, liveOverlays: true),
      isNotNull,
    );
    expect(sent.single['ovLive'], isTrue);
    expect(sent.single['overlays'], isEmpty);
    expect(sent.single['hdrOut'], isTrue);
  });

  test('預設 ovLive=false：SDR／沒有疊加物內容的合成一個位元都不變', () async {
    expect(await CompPlayer.build(tl(), hdrOut: true), isNotNull);
    expect(sent.single['ovLive'], isFalse);
    expect(await CompPlayer.build(tl()), isNotNull);
    expect(sent.last['ovLive'], isFalse);
    expect(sent.last['hdrOut'], isFalse);
  });
}
