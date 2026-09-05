import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/batch_overlay_cache.dart';

void main() {
  test(
    'reuses identical output, invalidates size/settings and caps memory',
    () async {
      final cache = BatchOverlayCache(maxBytes: 4);
      var calls = 0;
      Future<Uint8List> render() async {
        calls++;
        return Uint8List(4);
      }

      final first = await cache.get('1080|1920|styleA', render);
      expect(await cache.get('1080|1920|styleA', render), same(first));
      expect(calls, 1);
      await cache.get('1920|1080|styleA', render);
      await cache.get('1920|1080|styleB', render);
      expect(calls, 3);
      await cache.get('large', () async => Uint8List(5));
      await cache.get('large', render);
      expect(calls, 4);
    },
  );

  test('failed rendering can retry', () async {
    final cache = BatchOverlayCache();
    await expectLater(
      cache.get('a', () async => throw StateError('failed')),
      throwsStateError,
    );
    expect(await cache.get('a', () async => Uint8List(3)), hasLength(3));
  });
}
