import 'package:flutter/foundation.dart';

import 'waveform_decode_io.dart'
    if (dart.library.js_interop) 'waveform_decode_web.dart';

/// 音訊波形快取：第一次要求時背景解碼，
/// 好了通知監聽者（時間軸重繪成真實波形）。
class WaveformCache extends ChangeNotifier {
  WaveformCache._();

  static final WaveformCache instance = WaveformCache._();

  final _peaks = <String, List<double>>{};
  final _loading = <String>{};
  final _failed = <String>{};

  /// 拿某個檔案的波形峰值；還沒好（或解不出來）回 null
  List<double>? of(String path) {
    final p = _peaks[path];
    if (p != null) return p;
    if (_failed.contains(path) || _loading.contains(path)) return null;
    _loading.add(path);
    decodeWaveformPeaks(path).then((v) {
      _loading.remove(path);
      if (v != null && v.isNotEmpty) {
        _peaks[path] = v;
        notifyListeners();
      } else {
        _failed.add(path);
      }
    }).catchError((_) {
      _loading.remove(path);
      _failed.add(path);
    });
    return null;
  }
}
