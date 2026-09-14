import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/preview_cache_pressure.dart';

void main() {
  test(
    'repeated pressure evicts history but preserves active bitmap identity',
    () {
      final old = Uint8List(8), active = Uint8List(8);
      final cache = {'old': old, 'active': active};
      final maps = [
        {'raw': active},
        {'png': active},
      ];
      for (var i = 0; i < 20; i++) {
        expect(
          trimPreviewPartCache(cache, maps, bytesOf: (p) => p, maxBytes: 8),
          isTrue,
        );
        expect(cache.keys, ['active']);
        expect(cache['active'], same(active));
      }
    },
  );

  test(
    'over-budget active maps are released atomically, including uncached bytes',
    () {
      final active = Uint8List(8), other = Uint8List(1);
      final cache = {'active': active};
      expect(
        trimPreviewPartCache(
          cache,
          [
            {'raw': active},
            {'png': other},
          ],
          bytesOf: (p) => p,
          maxBytes: 8,
        ),
        isFalse,
      );
      expect(cache, isEmpty);
    },
  );

  test('no active maps releases all history', () {
    final cache = {'old': Uint8List(8)};
    expect(
      trimPreviewPartCache(cache, [], bytesOf: (p) => p, maxBytes: 8),
      isTrue,
    );
    expect(cache, isEmpty);
  });
}
