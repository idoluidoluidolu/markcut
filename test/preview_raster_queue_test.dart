import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/preview_raster_queue.dart';

void main() {
  test(
    'one raster in flight; interaction precedes queued settled refinements',
    () async {
      final queue = PreviewRasterQueue<int>();
      final first = Completer<int>();
      final order = <int>[];
      final a = queue.run(() {
        order.add(1);
        return first.future;
      }, interactive: false);
      final b = queue.run(() async {
        order.add(2);
        return 2;
      }, interactive: false);
      final c = queue.run(() async {
        order.add(3);
        return 3;
      }, interactive: true);
      expect(order, [1]);
      expect(queue.pending, 2);
      first.complete(1);
      expect(await Future.wait([a, b, c]), [1, 2, 3]);
      expect(order, [1, 3, 2]);
      expect(queue.pending, 0);
      queue.dispose();
    },
  );

  test(
    'failed raster releases its slot without dropping the next update',
    () async {
      final queue = PreviewRasterQueue<int>();
      final first = Completer<int>();
      final a = queue.run(() => first.future, interactive: true);
      final failed = expectLater(a, throwsStateError);
      final b = queue.run(() async => 2, interactive: true);
      first.completeError(StateError('raster failed'));
      await failed;
      expect(await b, 2);
      queue.dispose();
    },
  );

  test(
    'dispose cancels queued work, lets active resources finish and release',
    () async {
      final queue = PreviewRasterQueue<int>();
      final first = Completer<int>();
      final a = queue.run(() => first.future, interactive: false);
      var queuedRan = false;
      final b = queue.run(() async {
        queuedRan = true;
        return 2;
      }, interactive: true);
      queue.dispose();
      expect(await b, isNull);
      expect(await queue.run(() async => 3, interactive: true), isNull);
      first.complete(1);
      expect(await a, 1);
      expect(queuedRan, isFalse);
    },
  );
}
