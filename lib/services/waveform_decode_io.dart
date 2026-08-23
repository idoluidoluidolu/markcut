import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

/// 用 FFmpeg 把音訊解成 8kHz 單聲道 PCM，再取每段的峰值（0~1）。
/// 回傳 null＝解不出來（時間軸會退回示意波形）。
Future<List<double>?> decodeWaveformPeaks(String path) async {
  final dir = await getTemporaryDirectory();
  final out =
      '${dir.path}${Platform.pathSeparator}wave_${path.hashCode.toRadixString(16)}.pcm';
  final session = await FFmpegKit.execute(
    '-y -i "$path" -vn -ac 1 -ar 8000 -f s16le "$out"',
  );
  final rc = await session.getReturnCode();
  if (!ReturnCode.isSuccess(rc)) return null;

  final f = File(out);
  if (!await f.exists()) return null;
  final bytes = await f.readAsBytes();
  try {
    await f.delete();
  } catch (_) {}
  if (bytes.length < 4) return null;

  final samples = Int16List.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.length ~/ 2,
  );
  return peaksFromSamples(samples.length, (i) => samples[i].abs() / 32768.0);
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
