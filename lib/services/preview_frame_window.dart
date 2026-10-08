import 'dart:async';
import 'dart:math' as math;

/// 拖曳快取幀的「已解碼窗」：只解播放頭附近的格子，兩道上限都守住。
///
/// - 張數上限 [capacity]，跟位元組上限 [byteBudget]／一格大小取小——一格
///   多大要解過第一格才知道，所以窗的大小在第一格解好後才定下來。
/// - 要解哪幾格（[_wanted]）一開始就照上限截好：窗比上限大的話，多出來的
///   那幾格是「解完當場丟掉」的白工，每移一格就重來一次。
/// - 解碼完成時再限額一次：以前只在開始解之前清，完成後直接塞進快取，
///   兩次跳到不同位置就會留下 42 格。
/// - 解好時已經不在窗內（手指早就拖走了）的結果直接丟掉，不進快取。
/// - 同時在解的張數有上限：快速拖曳不會把解碼工作越堆越多。
/// - 同一支素材可能同時有好幾層在要格子（複製出來的圖層、交界前先掛上的
///   暖身層、切開的倒轉片段——倒轉的連播放中都走快取幀）：每一層各自一個
///   中心，窗是它們的聯集。只記最後一個中心的話，另一層解好的格子會被當成
///   過期丟掉，那一層就一直拿不到。
class PreviewFrameWindow<T> {
  PreviewFrameWindow({
    required this.load,
    required this.bytesOf,
    required this.disposeFrame,
    required this.onReady,
    this.radius = 10,
    this.capacity = 24,
    this.byteBudget = 48 << 20,
    this.maxConcurrent = 2,
  }) : assert(
         radius >= 0 && capacity > 0 && byteBudget > 0 && maxConcurrent > 0,
       );

  final Future<T?> Function(int index) load;
  final int Function(T frame) bytesOf;
  final void Function(T frame) disposeFrame;

  /// 「現在正要顯示的那格」解好了。只有中心格會叫：一次補解十幾格，
  /// 每格都叫就是十幾次重畫
  final void Function() onReady;

  final int radius, capacity, byteBudget, maxConcurrent;

  final Map<int, T> _frames = {};
  final Set<int> _pending = {};

  /// 現在要的格子，照優先順序（各層的中心、+1、-1、+2、-2…；集合照放入
  /// 順序走）
  Set<int> _wanted = {};

  /// 每一層（[focus] 的 consumer）現在的中心，跟它最後一次要格子是第幾次 focus
  final Map<Object, ({int center, int seen})> _anchors = {};
  int _focusCount = 0;

  /// 一層連續這麼多次 focus 都沒再出現（卸下了、不拖了），它的中心就不算
  static const _anchorTtl = 8;
  int _bytes = 0;

  /// 解過的一格有多大（同一個素材的快取幀尺寸都一樣）；0＝還不知道
  int _frameBytes = 0;

  /// 一格就超過整個位元組上限：這個窗不解了，顯示端自己退回用位元組畫
  bool _oversize = false;
  bool _disposed = false;

  int get length => _frames.length;
  int get bytes => _bytes;
  int get pending => _pending.length;
  T? operator [](int index) => _frames[index];

  /// 這個窗實際能留幾格
  int get slots => _oversize
      ? 0
      : _frameBytes <= 0
      ? capacity
      : math.min(capacity, byteBudget ~/ _frameBytes);

  /// 把 [consumer] 這一層的中心移到 [center]：補解窗內缺的，超量就丟離
  /// 中心最遠的。同一支素材只有一層在要格子時 [consumer] 不用給。
  ///
  /// 中心沒動也要重新算：背景抽幀可能剛把旁邊原本空著的格子補上了
  void focus(
    int center, {
    required bool Function(int index) available,
    Object consumer = 0,
  }) {
    if (_disposed) return;
    _focusCount++;
    _anchors[consumer] = (center: center, seen: _focusCount);
    _anchors.removeWhere((_, a) => _focusCount - a.seen > _anchorTtl);
    final centers = [for (final a in _anchors.values) a.center];
    final limit = slots;
    final wanted = <int>{};
    // 各層輪流往外擴：先是每一層的中心，再各層的 ±1、±2…
    for (var d = 0; d <= radius && wanted.length < limit; d++) {
      for (final c in centers) {
        for (final i in d == 0 ? [c] : [c + d, c - d]) {
          if (wanted.length >= limit) break;
          if (available(i)) wanted.add(i);
        }
      }
    }
    _wanted = wanted;
    _trim();
    _pump();
  }

  bool _isCenter(int index) => _anchors.values.any((a) => a.center == index);

  /// 離最近的那個中心多遠
  int _distance(int index) {
    var best = 1 << 30;
    for (final a in _anchors.values) {
      best = math.min(best, (index - a.center).abs());
    }
    return best;
  }

  void _pump() {
    if (_disposed) return;
    for (final index in _wanted) {
      if (_pending.length >= maxConcurrent) break;
      if (_frames.containsKey(index) || _pending.contains(index)) continue;
      _pending.add(index);
      unawaited(_decode(index));
    }
  }

  Future<void> _decode(int index) async {
    T? frame;
    try {
      frame = await load(index);
    } catch (_) {
      // 解不開就算了：顯示端會退回用位元組畫。不在這裡原地重試，
      // 等下一次 focus 再說，免得一張壞圖卡成解碼迴圈
      frame = null;
    }
    _pending.remove(index);
    if (frame != null) {
      _accept(index, frame);
    } else {
      _wanted.remove(index);
    }
    _pump();
  }

  void _accept(int index, T frame) {
    if (_disposed) {
      disposeFrame(frame);
      return;
    }
    final size = bytesOf(frame);
    if (size > byteBudget) {
      _oversize = true;
      _wanted.clear();
      disposeFrame(frame);
      return;
    }
    _frameBytes = size;
    // 解的途中手指已經拖走了：不在窗內的結果不進快取
    if (!_wanted.contains(index)) {
      disposeFrame(frame);
      return;
    }
    _frames[index] = frame;
    _bytes += size;
    // 知道一格多大之後窗可能變小了：要的格子跟著截
    final limit = slots;
    if (_wanted.length > limit) _wanted = _wanted.take(limit).toSet();
    _trim();
    if (_isCenter(index) && _frames.containsKey(index)) onReady();
  }

  /// 超量就丟：先丟窗外的，再丟窗內離中心最遠的
  void _trim() {
    final limit = slots;
    if (_frames.length <= limit && _bytes <= byteBudget) return;
    final keys = _frames.keys.toList()
      ..sort((a, b) {
        final wa = _wanted.contains(a), wb = _wanted.contains(b);
        if (wa != wb) return wa ? 1 : -1;
        return _distance(b).compareTo(_distance(a));
      });
    for (final key in keys) {
      if (_frames.length <= limit && _bytes <= byteBudget) break;
      final frame = _frames.remove(key) as T;
      _bytes -= bytesOf(frame);
      disposeFrame(frame);
      // 放不下的不要再排回去解，不然會解了又丟、丟了又解
      _wanted.remove(key);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wanted.clear();
    for (final frame in _frames.values) {
      disposeFrame(frame);
    }
    _frames.clear();
    _bytes = 0;
  }
}
