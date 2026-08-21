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

  /// 峰值快取上限（支）。單例活過整個 App 生命週期，以前完全不清：
  /// 每載入過一支音檔就永久多一條峰值陣列，跨專案一路疊上去。
  /// 超過就丟最久沒被要過的（Map 的插入順序＝LRU，讀到就搬到尾巴）
  static const _maxEntries = 12;

  /// 拿某個檔案的波形峰值；還沒好（或解不出來）回 null
  List<double>? of(String path) {
    final p = _peaks.remove(path);
    if (p != null) {
      _peaks[path] = p; // 搬到尾巴＝最近用過
      return p;
    }
    if (_failed.contains(path) || _loading.contains(path)) return null;
    _loading.add(path);
    decodeWaveformPeaks(path).then((v) {
      _loading.remove(path);
      if (v != null && v.isNotEmpty) {
        _peaks[path] = v;
        while (_peaks.length > _maxEntries) {
          _peaks.remove(_peaks.keys.first);
        }
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
