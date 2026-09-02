import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;

/// 一格的抽幀：[seconds] 那一刻、允許差 [tolMs] 毫秒
typedef StripFetch =
    Future<Uint8List?> Function(double seconds, {required int tolMs});

/// GIF 頁縮圖帶的漸進載入。
///
/// 原本是十格排隊一格一格（容忍 0.15 秒＝幾乎逐格精準）抽完、再一次
/// 全部上畫面——一支 4K 影片要等好幾秒，中間縮圖帶是空的。改成：
///
/// 1. 粗抽：容忍值給到整支長度＝拿最近的關鍵幀，一格只解一張、
///    幾十毫秒；順序用二分（頭、尾、中、四分之一…），抽到第三格
///    整條就看得出輪廓。抽到一格畫一格、還沒到的格子先借最近的
///    一格（[nearestLoaded]）
/// 2. 細抽（iOS）：容忍值收到半格，把每一格夾回自己那段時間；
///    跟粗抽一樣的就不重畫。Android 的抽幀器本來就只拿關鍵幀，
///    容忍值沒作用，細抽等於白跑，關掉
///
/// 手勢進行中（[isBusy]）先讓路：拖把手時解碼器要留給播放器 seek，
/// 縮圖帶晚幾百毫秒沒關係
class GifStripLoader {
  GifStripLoader({
    required this.duration,
    required this.count,
    required this.fetch,
    required this.onFrame,
    this.refine = true,
    this.isBusy,
    this.yieldWait = const Duration(milliseconds: 50),
    this.maxYield = const Duration(seconds: 2),
  }) : frames = List<Uint8List?>.filled(math.max(0, count), null);

  /// 細抽的容忍下限：原生端本來的預設。太短的影片逐格精準也划不來
  static const int fineTolFloorMs = 150;

  final double duration;
  final int count;
  final StripFetch fetch;

  /// 每一格抽到（或換成更準的一張）就叫一次
  final void Function(int index, Uint8List bytes) onFrame;
  final bool refine;
  final bool Function()? isBusy;
  final Duration yieldWait;

  /// 最多讓路這麼久：手一直按著也要把縮圖帶抽完
  final Duration maxYield;

  final List<Uint8List?> frames;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  /// 粗抽的容忍：整支長度＝最近的關鍵幀在哪就拿哪
  int get coarseTolMs => math.max(fineTolFloorMs, (duration * 1000).ceil());

  /// 細抽的容忍：半格（同一個關鍵幀不會被相鄰兩格共用）
  int get fineTolMs =>
      math.max(fineTolFloorMs, (duration / count / 2 * 1000).floor());

  Future<void> run() async {
    if (duration <= 0 || count <= 0) return;
    final order = stripFillOrder(count);
    await _pass(order, coarseTolMs);
    if (_cancelled || !refine || fineTolMs >= coarseTolMs) return;
    await _pass(order, fineTolMs);
  }

  void cancel() => _cancelled = true;

  Future<void> _pass(List<int> order, int tolMs) async {
    for (final i in order) {
      await _yieldWhileBusy();
      if (_cancelled) return;
      final bytes = await fetch(duration * (i + 0.5) / count, tolMs: tolMs);
      if (_cancelled) return;
      if (bytes == null) continue;
      final prev = frames[i];
      if (prev != null && listEquals(prev, bytes)) continue;
      frames[i] = bytes;
      onFrame(i, bytes);
    }
  }

  Future<void> _yieldWhileBusy() async {
    final busy = isBusy;
    if (busy == null) return;
    var waited = Duration.zero;
    while (!_cancelled && waited < maxYield && busy()) {
      await Future<void>.delayed(yieldWait);
      waited += yieldWait;
    }
  }
}

/// 二分順序：頭、尾、中間、再各段的中間……全部走完剛好每格一次。
/// 先抽到的幾格就能撐出整條的輪廓
List<int> stripFillOrder(int n) {
  if (n <= 0) return const [];
  if (n == 1) return const [0];
  final out = <int>[0, n - 1];
  final seen = <int>{0, n - 1};
  final queue = <(int, int)>[(0, n - 1)];
  while (queue.isNotEmpty) {
    final (lo, hi) = queue.removeAt(0);
    if (hi - lo < 2) continue;
    final mid = (lo + hi) ~/ 2;
    if (seen.add(mid)) out.add(mid);
    queue.add((lo, mid));
    queue.add((mid, hi));
  }
  return out;
}

/// 第 [i] 格要畫什麼：自己有就自己，沒有就借最近的一格；
/// 一格都沒有回 null
Uint8List? nearestLoaded(List<Uint8List?> cells, int i) {
  if (cells.isEmpty) return null;
  final n = cells.length;
  final c = i.clamp(0, n - 1);
  for (var d = 0; d < n; d++) {
    if (c - d >= 0 && cells[c - d] != null) return cells[c - d];
    if (c + d < n && cells[c + d] != null) return cells[c + d];
  }
  return null;
}
