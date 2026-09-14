import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/preview_seek_dispatcher.dart';

void main() {
  testWidgets('leading seek is immediate; burst sends only the latest target', (
    t,
  ) async {
    final queue = PreviewSeekDispatcher(
      interval: const Duration(milliseconds: 16),
    );
    final sent = <int>[];
    queue.submit(() => sent.add(0), exact: false);
    expect(sent, [0]);
    for (var i = 1; i <= 10; i++) {
      queue.submit(() => sent.add(i), exact: false);
    }
    expect(sent, [0]);
    await t.pump(const Duration(milliseconds: 16));
    expect(sent, [0, 10]);
    expect(queue.coalesced, 9);
    await t.pump(const Duration(milliseconds: 40));
    expect(sent, [0, 10]);
    queue.dispose();
  });

  testWidgets('release bypasses cadence and cancels older approximate target', (
    t,
  ) async {
    final queue = PreviewSeekDispatcher();
    final sent = <int>[];
    queue.submit(() => sent.add(0), exact: false);
    queue.submit(() => sent.add(1), exact: false);
    queue.submit(() => sent.add(2), exact: true);
    expect(sent, [0, 2]);
    await t.pump(const Duration(seconds: 1));
    expect(sent, [0, 2]);
    queue.submit(() => sent.add(3), exact: false);
    expect(sent, [0, 2, 3]);
    queue.dispose();
  });

  testWidgets(
    'cancel and dispose prevent trailing work after lifecycle changes',
    (t) async {
      final queue = PreviewSeekDispatcher();
      final sent = <int>[];
      queue.submit(() => sent.add(0), exact: false);
      queue.submit(() => sent.add(1), exact: false);
      queue.cancel();
      await t.pump(const Duration(seconds: 1));
      expect(sent, [0]);
      queue.submit(() => sent.add(2), exact: false);
      queue.submit(() => sent.add(3), exact: false);
      queue.dispose();
      queue.submit(() => sent.add(4), exact: true);
      await t.pump(const Duration(seconds: 1));
      expect(sent, [0, 2]);
    },
  );
}
