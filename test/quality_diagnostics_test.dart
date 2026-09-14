import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/quality_diagnostics.dart';
import 'package:markcut/widgets/quality_diagnostics_sheet.dart';

void main() {
  test(
    'empty and small samples are not passes; failure is not a fast success',
    () {
      final d = QualityDiagnostics()..start(buildTag: 'test+203');
      expect(d.report(), contains('待量測｜浮水印幾何通道'));
      d.record(QualityMetric.geometryAck, 0, success: false);
      final s = d.samples[QualityMetric.geometryAck]!;
      expect(s.count, 0);
      expect(s.p95, isNull);
      expect(s.status(QualityMetric.geometryAck), '需處理');
      expect(d.priorities, isNotEmpty);
    },
  );

  test('P95 is bounded and lifetime maximum preserves isolated stalls', () {
    final d = QualityDiagnostics()..start(buildTag: 'x');
    d.record(QualityMetric.geometryAck, 800);
    for (var i = 0; i < 400; i++) {
      d.record(QualityMetric.geometryAck, 10);
    }
    final s = d.samples[QualityMetric.geometryAck]!;
    expect(s.count, 401);
    expect(s.values.length, 300);
    expect(s.p95, 10);
    expect(s.maximum, 800);
    expect(s.status(QualityMetric.geometryAck), '需處理');
    d.record(QualityMetric.geometryAck, double.nan);
    d.record(QualityMetric.geometryAck, -1);
    expect(s.count, 401);
  });

  test(
    'reset ignores previous asynchronous work; finish is idempotent',
    () async {
      final d = QualityDiagnostics()..start(buildTag: 'old');
      final old = d.begin(QualityMetric.overlayBake);
      d.start(buildTag: 'new');
      d.finish(old);
      expect(d.samples, isEmpty);
      final span = d.begin(QualityMetric.overlayBake);
      d.finish(span);
      d.finish(span);
      expect(d.samples[QualityMetric.overlayBake]!.count, 1);
      final pending = d.begin(QualityMetric.composition);
      expect(d.toJson()['pendingOperations'] as List, hasLength(1));
      d.stop();
      d.finish(pending);
      d.record(QualityMetric.uiBuild, 99);
      expect(d.samples.containsKey(QualityMetric.composition), isFalse);
      expect(d.samples.containsKey(QualityMetric.uiBuild), isFalse);
    },
  );

  test(
    'throwing measurements are failures and are removed from pending',
    () async {
      final d = QualityDiagnostics()..start(buildTag: 'x');
      await expectLater(
        d.measure<void>(
          QualityMetric.logoDecode,
          () async => throw StateError('decode'),
        ),
        throwsStateError,
      );
      expect(d.samples[QualityMetric.logoDecode]!.failures, 1);
      expect(d.toJson()['pendingOperations'] as List, isEmpty);
    },
  );

  test(
    'manual observations are bounded, versioned, and not color certification',
    () {
      final d = QualityDiagnostics()..start(buildTag: '1.1+203');
      for (var i = 0; i < 110; i++) {
        d.observe(
          QualityScenario.flicker,
          QualityObservation.problem,
          position: 1.25,
        );
      }
      final j = jsonDecode(d.jsonReport()) as Map;
      expect(j['schemaVersion'], 2);
      expect(j['build'], '1.1+203');
      expect(j['events'], hasLength(100));
      expect(j['manualChecks']['color'], 'untested');
      expect(d.report(), contains('HDR 標記 ≠ 色準'));
      expect(d.report(), contains('非上屏'));
      expect(d.priorities.first, contains('不閃動'));
      d.start(buildTag: 'next');
      expect(d.events, isEmpty);
      expect(d.observations, isEmpty);
    },
  );

  testWidgets(
    'sheet refreshes, records a problem, and copies a stable JSON schema',
    (t) async {
      final d = QualityDiagnostics()..start(buildTag: 'test');
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      var refreshes = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QualityDiagnosticsSheet(
              diagnostics: d,
              buildTag: 'test',
              position: () => 3.5,
              refresh: () async {
                refreshes++;
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(refreshes, 1);
      await t.tap(find.text('有問題').first);
      await t.pump();
      expect(d.events.single['timelineSeconds'], 3.5);
      await t.tap(find.text('複製 JSON'));
      await t.pumpAndSettle();
      expect(jsonDecode(copied!)['schemaVersion'], 2);
      expect(refreshes, 2); // copy refreshes, not a stale panel snapshot
      expect(find.text('已複製 JSON，可貼回來分析。'), findsOneWidget);
      await t.tap(find.text('停止記錄'));
      await t.pump();
      expect(d.recording, isFalse);
    },
  );

  test('slow spans preserve operation-start context, not completion state', () {
    final d = QualityDiagnostics()..start(buildTag: 'test');
    final context = <String, Object?>{'playing': false, 'selectedClip': 7};
    d.contextProvider = () => context;
    final span = d.begin(QualityMetric.overlayBake)!;
    context['playing'] = true;
    context['selectedClip'] = 9;
    d.finish(span, success: false);
    expect(d.events.single['context'], {'playing': false, 'selectedClip': 7});
    expect(d.events.single['startedAtMs'], isA<num>());
    expect(() => span.context['playing'] = true, throwsUnsupportedError);
    d.contextProvider = () => throw StateError('unavailable');
    d.mark('memoryPressure');
    expect(d.events.last['context'], {'contextUnavailable': true});
  });

  test(
    'native waits are actionable but never presented as visual failures',
    () {
      final d = QualityDiagnostics()..start(buildTag: 'test');
      expect(d.priorities, isEmpty);
      d.nativeSnapshot = {
        'playerInstance': 'test',
        'redrawSeekMaxMs': 700,
        'redrawMainQueueMaxMs': 30,
        'redrawCallbackFailures': 1,
      };
      expect(d.priorities, hasLength(3));
      expect(d.priorities.join(), contains('非上屏延遲'));
      for (var i = 0; i < 50; i++) {
        d.increment('counter$i');
      }
      expect(d.counters, hasLength(32));
      d.increment('counter0');
      expect(d.counters['counter0'], 2);
      d.start(buildTag: 'next');
      expect(d.counters, isEmpty);
      expect(d.priorities, isEmpty);
    },
  );

  test('resource ring preserves round peak, rejects stale/stopped samples', () {
    final d = QualityDiagnostics()..start(buildTag: 'test');
    final session = d.session;
    final initial = <String, Object?>{'memoryMB': 1500, 'playing': false};
    d.recordResources(initial, session: session);
    initial['memoryMB'] = 1;
    for (var i = 0; i < 100; i++) {
      d.recordResources({'memoryMB': 1000 + i}, session: session);
    }
    expect(d.resourceHistory, hasLength(90));
    expect(d.peakMemorySample!['memoryMB'], 1500);
    d.recordResources({'memoryMB': null}, session: session);
    expect(d.resourceHistory.last['memoryMB'], isNull);
    expect(d.peakMemorySample!['memoryMB'], 1500);
    final report = d.report();
    final json = jsonDecode(
      report.split('\n').where((s) => s.startsWith('{')).last,
    );
    expect(json['resourceHistory'], hasLength(90));
    expect(json['coverageLimits'], isNotEmpty);
    d.stop();
    d.recordResources({'memoryMB': 2000}, session: session);
    expect(d.peakMemorySample!['memoryMB'], 1500);
    d.start(buildTag: 'next');
    d.recordResources({'memoryMB': 2000}, session: session);
    expect(d.resourceHistory, isEmpty);
    expect(d.peakMemorySample, isNull);
  });
}
