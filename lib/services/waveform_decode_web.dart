import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web：抓 blob → AudioContext 解碼 → 取每段峰值（0~1）。
/// 回傳 null＝解不出來（時間軸會退回示意波形）。
Future<List<double>?> decodeWaveformPeaks(String path) async {
  try {
    final resp = await web.window.fetch(path.toJS).toDart;
    final jsBuf = await resp.arrayBuffer().toDart;
    final ctx = web.AudioContext();
    try {
      final audio = await ctx.decodeAudioData(jsBuf).toDart;
      final data = audio.getChannelData(0).toDart;
      return peaksFromSamples(
        data.length,
        (i) => data[i].abs(),
        sampleRate: audio.sampleRate.round(),
      );
    } finally {
      await ctx.close().toDart;
    }
  } catch (_) {
    return null;
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
