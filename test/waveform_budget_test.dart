import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/waveform_cache.dart';
import 'package:markcut/services/waveform_decode_io.dart';
import 'package:markcut/services/waveform_job.dart';

void main() {
  test(
    '32 visible waveforms are decoded once and notify only their own listener',
    () async {
      final started = <String>[];
      final cache = WaveformCache.forTest((path, {job}) async {
        started.add(path);
        return List.filled(8000, .5);
      });
      final paths = List.generate(32, (i) => 'audio$i');
      final owner = Object();
      cache.retain(owner, paths.toSet());
      final calls = <String, int>{};
      for (final path in paths) {
        cache
            .listenTo(path)
            .addListener(
              () => calls.update(path, (n) => n + 1, ifAbsent: () => 1),
            );
      }
      await Future<void>.delayed(Duration.zero);
      for (var pass = 0; pass < 3; pass++) {
        for (final path in paths) {
          expect(cache.of(path)?.length, 6000);
        }
      }
      expect(started, paths);
      expect(calls, {for (final path in paths) path: 1});
      cache.release(owner);
      cache.dispose();
    },
  );

  test(
    'admission waits for capacity instead of evicting visible waveforms',
    () async {
      final started = <String>[];
      final cache = WaveformCache.forTest((path, {job}) async {
        started.add(path);
        return [.25];
      }, maxEntries: 2);
      final owner = Object();
      cache.retain(owner, {'a', 'b', 'c'});
      for (final p in ['a', 'b', 'c']) {
        cache.listenTo(p);
      }
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b']);
      expect(cache.of('a'), [.25]);
      cache.retain(owner, {'b', 'c'});
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b', 'c']);
      expect(cache.of('b'), [.25]);
      expect(cache.of('c'), [.25]);
      cache.release(owner);
      cache.dispose();
    },
  );

  test(
    'one decoder at a time; leaving removes queued work and cancels running work',
    () async {
      final gates = <Completer<List<double>?>>[];
      final jobs = <WaveformJob>[];
      final started = <String>[];
      final cache = WaveformCache.forTest((path, {job}) {
        started.add(path);
        jobs.add(job!);
        final gate = Completer<List<double>?>();
        gates.add(gate);
        return gate.future;
      });
      final owner = Object();
      cache.retain(owner, {'a', 'b', 'c'});
      cache.of('a');
      cache.of('b');
      cache.of('c');
      expect(started, ['a']);
      gates.first.complete([.5]);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b']);
      cache.release(owner);
      expect(jobs.last.cancelled, isTrue);
      gates.last.complete([.7]);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b'], reason: 'c must never start after leaving');
      cache.dispose();
    },
  );
  test(
    'PCM chunk scan keeps peaks across chunk and bucket boundaries',
    () async {
      final dir = await Directory.systemTemp.createTemp('markcut_pcm_');
      try {
        final bytes = ByteData(65536 + 800);
        bytes.setInt16(65534, -32768, Endian.little);
        bytes.setInt16(65536, 16384, Endian.little);
        final file = await File(
          '${dir.path}/audio.pcm',
        ).writeAsBytes(bytes.buffer.asUint8List());
        final peaks = pcmFilePeaks(file.path)!;
        expect(peaks.reduce((a, b) => a > b ? a : b), 1);
        expect(peaks.length, (bytes.lengthInBytes ~/ 2 + 199) ~/ 200);
        expect(peaks.length, lessThanOrEqualTo(6000));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
