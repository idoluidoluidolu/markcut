import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/overlay_bitmap_transport.dart';

void main() {
  test('full retry samples the latest visibility and geometry', () async {
    final transport = OverlayBitmapTransport();
    var opacity = 1.0;
    await transport.send(
      [
        {'id': 'a', 'png': Uint8List(100)},
      ],
      liveProvider: () => [
        {'id': 'a', 'opacity': opacity},
      ],
      invoke: (method, args) async {
        final live = (args['live'] as List).single as Map;
        if (method == 'setOverlayParts') {
          expect(live['opacity'], 1.0);
          opacity = 0;
          return false;
        }
        expect(live['opacity'], 0.0);
        return true;
      },
    );
  });
  test(
    'an older rejected delta cannot retry over a newer style update',
    () async {
      final transport = OverlayBitmapTransport();
      final gate = Completer<bool?>();
      final old = transport.send(
        [
          {'id': 'a', 'png': Uint8List(100)},
        ],
        invoke: (method, args) {
          expect(method, 'setOverlayParts');
          return gate.future;
        },
      );
      await transport.send([
        {'id': 'a', 'png': Uint8List(200)},
      ], invoke: (_, _) async => true);
      gate.complete(false);
      expect(await old, isFalse);
      expect(transport.fullRetries, 0);
    },
  );
  test(
    'only changed bytes cross the channel; geometry stays in the same update',
    () async {
      final transport = OverlayBitmapTransport();
      final sent = <Map<String, dynamic>>[];
      Future<bool?> invoke(String method, Map<String, dynamic> args) async {
        expect(method, 'setOverlayParts');
        sent.add(args);
        return true;
      }

      final logo = Uint8List(2048), text = Uint8List(64);
      final parts = [
        <String, dynamic>{'id': 'logo', 'png': logo, '_rasterSig': 'local'},
        <String, dynamic>{'id': 'text', 'raw': text, 'rw': 4, 'rh': 4},
      ];
      expect(await transport.send(parts, invoke: invoke), isTrue);
      expect(transport.lastSentBytes, 2112);
      final live = [
        <String, dynamic>{'id': 'logo', 'x': .2},
      ];
      final changed = [
        parts.first,
        {...parts.last, 'raw': Uint8List(64)},
      ];
      expect(await transport.send(changed, invoke: invoke, live: live), isTrue);
      final update = sent.last['overlays'] as List;
      expect(update.first['png'], isNull);
      expect(update.first['_rasterSig'], isNull);
      expect(update.last['raw'], hasLength(64));
      expect(sent.last['live'], same(live));
      expect(transport.lastSentBytes, 64);
      expect(transport.lastReusedParts, 1);
      expect(
        parts.first.containsKey('bitmapId'),
        isFalse,
        reason: 'cached maps are never mutated',
      );
    },
  );

  test(
    'missing native reference retries full list and live state together',
    () async {
      final transport = OverlayBitmapTransport();
      final bytes = Uint8List(100);
      final parts = [
        <String, dynamic>{'id': 'a', 'png': bytes},
      ];
      await transport.send(parts, invoke: (_, _) async => true);
      final calls = <String>[];
      final live = [
        <String, dynamic>{'id': 'a', 'opacity': 0.0},
      ];
      expect(
        await transport.send(
          parts,
          live: live,
          invoke: (method, args) async {
            calls.add(method);
            expect(args['live'], same(live));
            final p = (args['overlays'] as List).single as Map;
            if (method == 'setOverlayParts') {
              expect(p['png'], isNull);
              return false; // native player was rebuilt
            }
            expect(p['png'], same(bytes));
            return true;
          },
        ),
        isTrue,
      );
      expect(calls, ['setOverlayParts', 'setOverlays']);
      expect(transport.fullRetries, 1);
      expect(transport.lastSentBytes, 100);
    },
  );

  test('clearing the list forgets bitmap acknowledgements', () async {
    final transport = OverlayBitmapTransport();
    final bytes = Uint8List(100);
    final parts = [
      <String, dynamic>{'id': 'a', 'png': bytes},
    ];
    await transport.send(parts, invoke: (_, _) async => true);
    await transport.send([], invoke: (_, _) async => true);
    await transport.send(
      parts,
      invoke: (_, args) async {
        expect((args['overlays'] as List).single['png'], same(bytes));
        return true;
      },
    );
    expect(transport.lastReusedParts, 0);
  });

  test(
    'legacy native builds are probed once and always receive full bytes',
    () async {
      final transport = OverlayBitmapTransport();
      final calls = <String>[];
      final parts = [
        <String, dynamic>{'id': 'a', 'png': Uint8List(100)},
      ];
      Future<bool?> invoke(String method, Map<String, dynamic> args) async {
        calls.add(method);
        if (method == 'setOverlayParts') return null;
        expect((args['overlays'] as List).single['png'], hasLength(100));
        return true;
      }

      await transport.send(parts, invoke: invoke);
      await transport.send(parts, invoke: invoke);
      expect(calls, ['setOverlayParts', 'setOverlays', 'setOverlays']);
    },
  );

  test('failed update cannot acknowledge new bitmaps', () async {
    final transport = OverlayBitmapTransport();
    final parts = [
      <String, dynamic>{'id': 'a', 'png': Uint8List(100)},
    ];
    expect(await transport.send(parts, invoke: (_, _) async => false), isFalse);
    await transport.send(
      parts,
      invoke: (_, args) async {
        expect((args['overlays'] as List).single['png'], hasLength(100));
        return true;
      },
    );
  });
}
