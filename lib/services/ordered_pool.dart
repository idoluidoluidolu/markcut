import 'dart:async';
import 'dart:math' as math;

/// 依序交回 [count] 個工作的結果，最多 [window] 個同時在做。
///
/// 第 i 個做完才交第 i 個（順序永遠照排：拼圖照挑選的順序放格子），但
/// 第 i+1、i+2…個已經先開始了——iOS 的原生縮圖在背景一張張排著做，
/// 這邊解前一張、放上畫面的同時，後面那幾張已經在縮了。
///
/// - [run] 丟例外或回錯誤＝那一個的結果是 null（呼叫端當「讀不出來」）
/// - [onResult] 拿到結果的所有權（不用的自己釋放）；回 false＝不要了
///   （畫面收掉、沒有空格），還在做的那幾個做完就交給 [discard]
/// - [window] 小於 1 當 1（＝一個做完才開始下一個）
Future<void> orderedPool<T extends Object>(
  int count, {
  required int window,
  required Future<T> Function(int i) run,
  required bool Function(int i, T? value) onResult,
  void Function(T value)? discard,
}) async {
  final width = math.max(1, window);
  final queue = <Future<T?>>[];
  var started = 0;
  void fill() {
    while (started < count && queue.length < width) {
      final i = started++;
      queue.add(
        Future<T>.sync(
          () => run(i),
        ).then<T?>((v) => v, onError: (Object _) => null),
      );
    }
  }

  fill();
  try {
    for (var i = 0; i < count; i++) {
      final value = await queue.removeAt(0);
      // 先補滿再交：交出去的那一下（放格子、setState）也跟後面的重疊
      fill();
      if (!onResult(i, value)) return;
    }
  } finally {
    for (final rest in queue) {
      unawaited(
        rest.then((v) {
          if (v != null) discard?.call(v);
        }),
      );
    }
  }
}
