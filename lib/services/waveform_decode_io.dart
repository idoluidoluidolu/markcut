import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';
import 'waveform_job.dart';

/// 用 FFmpeg 把音訊解成 8kHz 單聲道 PCM，再取每段的峰值（0~1）。
/// 回傳 null＝解不出來（時間軸會退回示意波形）。
Future<List<double>?> decodeWaveformPeaks(
  String path, {
  WaveformJob? job,
}) async {
  if (job?.cancelled ?? false) return null;
  final dir = await getTemporaryDirectory();
  final out =
      '${dir.path}${Platform.pathSeparator}wave_${DateTime.now().microsecondsSinceEpoch}.pcm';
  const maxPcmBytes = 128 << 20;
  final done = Completer<FFmpegSession>();
  FFmpegSession? running;
  try {
    running = await FFmpegKit.executeWithArgumentsAsync(
      [
        '-y',
        '-i',
        path,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '8000',
        '-fs',
        '$maxPcmBytes',
        '-f',
        's16le',
        out,
      ],
      (session) {
        if (!done.isCompleted) done.complete(session);
      },
    );
    final sessionId = running.getSessionId();
    job?.onCancel = () => FFmpegKit.cancel(sessionId);
    if (job?.cancelled ?? false) await FFmpegKit.cancel(sessionId);
    final finished = await done.future.timeout(const Duration(minutes: 2));
    if ((job?.cancelled ?? false) ||
        !ReturnCode.isSuccess(await finished.getReturnCode())) {
      return null;
    }
    final file = File(out);
    if (!await file.exists()) return null;
    // Truncated analysis must never appear as the entire track's waveform.
    if (await file.length() >= maxPcmBytes) return null;
    final peaks = await compute(pcmFilePeaks, out);
    return (job?.cancelled ?? false) ? null : peaks;
  } finally {
    job?.onCancel = null;
    if (running != null && !done.isCompleted) {
      await FFmpegKit.cancel(running.getSessionId());
      // Keep the queue slot until its writer stops; do not overlap decoders.
      await done.future;
    }
    try {
      await File(out).delete();
    } catch (_) {}
  }
}

/// Bounded-memory PCM scan on a worker isolate, never a full-file UI allocation.
List<double>? pcmFilePeaks(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync() ~/ 2;
    if (length == 0) return null;
    final bucket = ((length + 5999) ~/ 6000).clamp(200, 1 << 30);
    final peaks = List<double>.filled((length + bucket - 1) ~/ bucket, 0);
    final bytes = Uint8List(64 << 10);
    final data = ByteData.sublistView(bytes);
    var index = 0;
    while (index < length) {
      final count = file.readIntoSync(bytes);
      if (count == 0) break;
      for (var offset = 0; offset + 1 < count; offset += 2) {
        final value = data.getInt16(offset, Endian.little).abs() / 32768.0;
        final slot = index++ ~/ bucket;
        if (value > peaks[slot]) peaks[slot] = value;
      }
    }
    return peaks;
  } finally {
    file.closeSync();
  }
}

/// 把樣本分桶取峰值：每秒約 40 格、全長上限 6000 格
List<double>? peaksFromSamples(
  int length,
  double Function(int) sampleAt, {
  int sampleRate = 8000,
}) {
  if (length == 0) return null;
  var bucket = (sampleRate / 40).round();
  var n = length ~/ bucket;
  if (n > 6000) {
    bucket = length ~/ 6000;
    n = length ~/ bucket;
  }
  if (n <= 0) return null;
  final peaks = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    var m = 0.0;
    final st = i * bucket;
    for (var j = st; j < st + bucket; j++) {
      final v = sampleAt(j);
      if (v > m) m = v;
    }
    peaks[i] = m;
  }
  return peaks;
}
