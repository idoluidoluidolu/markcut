import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('markcut/comp');
  late Map<String, Object?> health;
  late CompPlayer player;

  setUp(() async {
    health = {
      'usesVC': true,
      'renderW': 720,
      'renderH': 1280,
      'nativeScrub': {
        'frames': 17,
        'bytes': 48024781,
        'budgetBytes': 50331648,
        'hits': 56,
        'misses': 303,
      },
      'nativeScrubPresented': 0,
      'nativeScrubFailures': 29,
      'seekCount': 360,
      'seekAvgMs': 1,
      'seekP50Ms': 2,
      'seekP90Ms': 3,
      'seekMaxMs': 11,
      'seekCoalesced': 2,
    };
    CompPlayer.debugHdrProbe = (_) async => false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          return {'textureId': 1, 'duration': 5.0, 'nativeScrub': true};
        case 'health':
          return health;
      }
      return null;
    });
    final timeline = TimelineModel();
    timeline.sources.add(
      MediaSource(
        path: '/fixture.mov',
        name: 'fixture',
        kind: ClipKind.video,
        duration: 5,
        workPath: '/fixture.work.mp4',
      ),
    );
    timeline.clips.add(
      TimelineClip(
        id: timeline.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      ),
    );
    player = (await CompPlayer.build(timeline))!;
  });

  tearDown(() {
    CompPlayer.debugHdrProbe = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'queue coalescing, seek replies and actual display remain distinct',
    () async {
      health.addAll({
        'nativeScrubCoalesced': 275,
        'nativeScrubActive': true,
        'nativeScrubPending': true,
        'seekSucceeded': 330,
        'seekUnfinished': 30,
        'nativeScrubFailureReasons': {
          'no-visible-host': 2,
          'drawable-unavailable': 3,
          'gpu': 4,
          'presentation-timeout': 20,
        },
        'nativeScrubLastFailure': 'gpu: commandBuffer status=error',
      });
      final report = await player.health();
      expect(report, contains('實際呈現 0 次'));
      expect(report, contains('呈現失敗 29 次'));
      expect(report, contains('合併 275 個中途目標'));
      expect(report, contains('處理中 是／待追最新目標 是'));
      expect(report, contains('合併不算呈現失敗'));
      expect(report, contains('沒有可見的影片視圖 [no-visible-host] 2 次'));
      expect(report, contains('取不到可顯示紋理 [drawable-unavailable] 3 次'));
      expect(report, contains('GPU 執行失敗 [gpu] 4 次'));
      expect(
        report,
        contains('拖曳最近未完成：GPU 執行失敗 [gpu]: commandBuffer status=error'),
      );
      expect(report, contains('等待實際呈現逾時 [presentation-timeout] 20 次'));
      expect(report, contains('定位 seek 回覆：360 發／平均 1ms'));
      expect(report, contains('回報成功 330 發／回報未完成 30 發'));
      expect(report, contains('seek 回覆不代表影格已呈現'));
      expect(report, isNot(contains('拖曳請求到實際呈現：平均')));
    },
  );

  test(
    'older native reports do not invent queue or outcome measurements',
    () async {
      final report = await player.health();
      expect(report, isNot('讀不到'));
      expect(report, contains('實際呈現 0 次'));
      expect(report, isNot(contains('原生拖曳排程')));
      expect(report, isNot(contains('回報成功')));
      expect(report, isNot(contains('回報未完成')));
      expect(report, isNot(contains('拖曳未完成階段')));
    },
  );

  test(
    'unknown failure stages survive while invalid counts cannot hide health',
    () async {
      health.addAll({
        'nativeScrubActive': false,
        'nativeScrubPending': false,
        'nativeScrubFailureReasons': {
          'future-native-stage': 2,
          'gpu': 0,
          'encode': 'unavailable',
        },
        'nativeScrubLastFailure': 'future-native-stage',
      });
      final report = await player.health();
      expect(report, contains('處理中 否／待追最新目標 否'));
      expect(report, contains('future-native-stage 2 次'));
      expect(report, contains('拖曳最近未完成：future-native-stage'));
      expect(report, isNot(contains('[gpu] 0 次')));
      expect(report, isNot(contains('[encode]')));
    },
  );
}
