import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/diagnostics.dart';

void main() {
  setUp(Diag.reset);
  tearDown(Diag.reset);

  test('unconfirmed startup cannot improve or inflate successful latency', () {
    Diag.notePlayLatency(400, confirmed: false, buffering: true);
    expect(Diag.playLatencies, isEmpty);
    expect(Diag.playLatencyText, contains('尚未確認'));

    Diag.notePlayLatency(80);
    Diag.notePlayLatency(100);
    expect(Diag.playLatencies, [80, 100]);
    expect(Diag.playLatencyText, contains('平均 90ms'));
    expect(Diag.report(), contains('起播確認逾時：1 次（未納入延遲平均）'));
    expect(Diag.report(), contains('非首幀呈現'));
    expect(Diag.playBuffering, 1);
    Diag.reset();
    expect(Diag.playConfirmationTimeouts, 0);
    expect(Diag.playLatencies, isEmpty);
  });

  test(
    'background composition and seek acknowledgements are not screen FPS',
    () {
      final summary = Diag.scrubSummary(
        milliseconds: 3431,
        seeks: 11,
        coalesced: 7,
        compositorFrames: 297,
      );
      expect(summary, contains('seek 完成 11 發'));
      expect(summary, contains('CI 完成 297 格'));
      expect(summary, contains('含背景工作，非螢幕幀率'));
      expect(summary, isNot(contains('87')));
      expect(summary, isNot(contains('張/秒')));
    },
  );

  test('reset counters cannot yield a negative throughput measurement', () {
    final summary = Diag.scrubSummary(
      milliseconds: 500,
      seeks: -4,
      coalesced: 0,
      compositorFrames: 5,
    );
    expect(summary, contains('本次不比較'));
    expect(summary, isNot(contains('-4')));
  });
}
