import 'package:flutter/foundation.dart';

/// 播放診斷紀錄器。
///
/// 「卡頓」「慢半拍」「閃一下」這種回報，光靠描述沒辦法分辨是哪一段
/// 出問題——是按下去到影片動很久，還是影片動了但指針對不上？是背景
/// 抽幀吃掉 CPU，還是播放器起轉本來就慢？這裡把每個關鍵時間點記下來，
/// 使用者玩一輪之後把報告複製出來就看得到。
///
/// 設計成隨時可以留在正式版裡：只有環形緩衝區的字串，不打網路、
/// 不寫檔，關掉之後連記錄都不做
/// 這班 build 的版本（main 啟動時填入）。遠端回報要對版用：
/// 「這班到底含不含某個修正」不能再用猜的
String appVersionTag = '?';

class PlaybackTrace {
  PlaybackTrace._();
  static final instance = PlaybackTrace._();

  /// 預設關閉。從診斷畫面打開，避免平常白白累積字串
  bool enabled = false;

  static const _cap = 400;
  final _lines = <String>[];
  final _env = <String, String>{};
  final _sw = Stopwatch();

  /// 一次「播放」從按下去開始的相對計時
  Stopwatch? _run;

  /// 環境資訊（播放引擎、素材規格、FFmpeg 能力），只記一次
  void env(String key, String value) {
    _env[key] = value;
  }

  String? envOf(String key) => _env[key];

  void start() {
    if (!enabled) return;
    _run = Stopwatch()..start();
    if (!_sw.isRunning) _sw.start();
    log('▶ 按下播放');
  }

  void log(String msg) {
    if (!enabled) return;
    final t = _run?.elapsedMilliseconds ?? _sw.elapsedMilliseconds;
    _lines.add('${t.toString().padLeft(5)}ms  $msg');
    if (_lines.length > _cap) _lines.removeAt(0);
  }

  /// 播放中每一格的間隔；只把「明顯掉格」的記下來，不然一秒六十行
  void tick(double dtSec) {
    if (!enabled) return;
    if (dtSec > 0.05) log('⚠ 掉格：這一格間隔 ${(dtSec * 1000).round()}ms');
  }

  void clear() {
    _lines.clear();
    _run = null;
  }

  /// 給人看也給我看的純文字報告
  String report() {
    final b = StringBuffer()
      ..writeln('=== 播放診斷 ===')
      // 版本一定要進報告：遠端來回時「這班 build 到底含不含修正」
      // 猜過太多次了，報告第一行就要能對版
      ..writeln('版本：$appVersionTag')
      ..writeln('平台：${defaultTargetPlatform.name}${kIsWeb ? ' (web)' : ''}');
    for (final e in _env.entries) {
      b.writeln('${e.key}：${e.value}');
    }
    b
      ..writeln('--- 事件（時間從按下播放起算）---')
      ..writeln(_lines.isEmpty ? '(還沒有紀錄，打開後播放一次)' : _lines.join('\n'));
    return b.toString();
  }
}
