import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// GIF 的時間表：第幾格在第幾毫秒結束（累計）。
///
/// 從檔頭的區塊直接讀，不用為了「現在該顯示哪一格」先把整支動畫解開。
/// 讀不懂的檔（截斷、怪區塊）回 null，由預覽池改用解碼器逐格量。
class GifTimeline {
  GifTimeline(this.endMs) : assert(endMs.isNotEmpty);

  /// 每格「結束於第幾毫秒」（累計）
  final List<int> endMs;
  int get length => endMs.length;
  int get durationMs => endMs.last;

  /// 0ms 的格（壞檔慣例）當 100ms 用，跟瀏覽器、解碼器那條路一致
  static int frameMs(int ms) => ms < 10 ? 100 : ms;

  /// [seconds] 這一刻該顯示哪一格（整支循環播放）
  int frameAt(double seconds) {
    final ms = (math.max(0.0, seconds) * 1000).round() % durationMs;
    // 二分找「結束時間 > ms」的第一格
    var lo = 0, hi = endMs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (endMs[mid] > ms) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  static GifTimeline? read(Uint8List bytes) {
    try {
      if (bytes.length < 13 ||
          String.fromCharCodes(bytes.sublist(0, 3)) != 'GIF') {
        return null;
      }
      var p = 13;
      final packed = bytes[10];
      if (packed & 0x80 != 0) p += 3 * (1 << ((packed & 7) + 1));
      void skipBlocks() {
        while (true) {
          final n = bytes[p++];
          if (n == 0) return;
          p += n;
          if (p > bytes.length) throw const FormatException('GIF block');
        }
      }

      var delay = 100, total = 0;
      final ends = <int>[];
      while (p < bytes.length) {
        switch (bytes[p++]) {
          case 0x3b:
            return ends.isEmpty ? null : GifTimeline(ends);
          case 0x21:
            final label = bytes[p++];
            if (label == 0xf9) {
              if (bytes[p] != 4) return null;
              delay = frameMs((bytes[p + 2] | bytes[p + 3] << 8) * 10);
            }
            skipBlocks();
          case 0x2c:
            final imagePacked = bytes[p + 8];
            p += 9;
            if (imagePacked & 0x80 != 0) {
              p += 3 * (1 << ((imagePacked & 7) + 1));
            }
            p++; // LZW 最小碼長
            skipBlocks();
            total += delay;
            ends.add(total);
            delay = 100;
          default:
            return null;
        }
      }
      // 沒有結尾區塊（截斷檔）：格數不一定跟解碼器一樣，交給解碼器量
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// 循序解 GIF 的解碼器（動畫格只能從頭往後一格一格解）
abstract interface class GifPreviewDecoder<T> {
  int get frameCount;

  /// 下一格的圖與它的顯示時間
  Future<(T, Duration)> nextFrame();
  void dispose();
}

class _ImageGifDecoder implements GifPreviewDecoder<ui.Image> {
  _ImageGifDecoder(this.codec);
  final ui.Codec codec;
  @override
  int get frameCount => codec.frameCount;
  @override
  Future<(ui.Image, Duration)> nextFrame() async {
    final frame = await codec.getNextFrame();
    return (frame.image, frame.duration);
  }

  @override
  void dispose() => codec.dispose();
}

/// 編輯器裡所有 GIF 片段共用的預覽池。
///
/// 以前每個 GIF 片段掛上去就把整支動畫解開留著（最多 300 格）：480×480
/// 一格 0.9MB，300 格就是 264MB；而且動畫的解碼器根本不管 targetWidth，
/// 大尺寸 GIF 是用原尺寸整支留著。現在：
/// - 只解每個片段「現在這格」跟後面 [prefetch] 格，解好縮到 480 再留；
/// - 留著的格子全部 GIF 共用一個總量上限 [byteBudget]，超過就丟最久沒用的
///   （各片段眼前要用的那幾格除外，見 [_store]）；
/// - 全部來源同一時間只跑一步解碼，GIF 再多也不會一起搶 CPU；
/// - 每個片段自己拿一份目前那格的複本，快取被淘汰不會讓畫面上的圖失效。
///
/// 同一支 GIF 被兩個片段在不同進度同時用到時，各自配一個解碼游標
/// （[cursorsPerSource]），不會為了在兩個進度之間跳來跳去每格都從頭解。
class TimelineGifPreviewPool<T> {
  TimelineGifPreviewPool({
    required this.open,
    required this.prepare,
    required this.bytesOf,
    required this.clone,
    required this.disposeImage,
    this.byteBudget = 32 << 20,
    this.prefetch = 2,
    this.cursorsPerSource = 2,
  }) : assert(byteBudget > 0 && prefetch >= 0 && cursorsPerSource > 0);

  final Future<GifPreviewDecoder<T>> Function(Uint8List bytes) open;

  /// 把解出來的原尺寸格子做成預覽用的那張；一律接手 [image]（失敗也要負責釋放）
  final Future<T> Function(T image) prepare;
  final int Function(T image) bytesOf;
  final T Function(T image) clone;
  final void Function(T image) disposeImage;
  final int byteBudget, prefetch, cursorsPerSource;

  final _sources = HashMap<Uint8List, _GifSource<T>>.identity();

  /// 留著的格子，最久沒用的排最前面（字面值的 Map／Set 照放入順序走）
  final _cache = <(_GifSource<T>, int), T>{};
  final _queue = <_GifSource<T>>{};
  int _cacheBytes = 0;
  int _clock = 0;
  bool _running = false, _disposed = false;

  /// 快取裡留著的格子總共多大（不含各片段手上那一格的複本：那是同一份像素）
  int get cacheBytes => _cacheBytes;
  int get sourceCount => _sources.length;

  /// 目前開著的解碼游標數（測試／診斷用）
  int get openDecoders =>
      _sources.values.fold(0, (n, s) => n + s.cursors.length);

  /// 還有解碼工作在跑（測試用：等它停下來再看結果）
  bool get running => _running;

  TimelineGifPreview<T> acquire(Uint8List bytes, void Function() onChanged) {
    if (_disposed) throw StateError('GIF pool disposed');
    final source = _sources.putIfAbsent(
      bytes,
      () => _GifSource(bytes, GifTimeline.read(bytes)),
    );
    // 之前解失敗過：新掛上來的片段再給它一次機會（失敗可能只是一時的，
    // 例如記憶體吃緊時 toImage 失敗）。只在掛上時重來，不會每個刻度都重解
    source.failed = false;
    final view = TimelineGifPreview<T>._(this, source, onChanged);
    source.views.add(view);
    return view;
  }

  T? _cached(_GifSource<T> source, int index) {
    final key = (source, index);
    final found = _cache.remove(key);
    if (found != null) _cache[key] = found;
    return found;
  }

  void _request(TimelineGifPreview<T> view, double seconds) {
    final source = view._source;
    view._seconds = seconds;
    if (_disposed || source.dead || source.failed) return;
    final timeline = source.timeline;
    if (timeline == null) {
      // 時間表要先用解碼器量出來（量好會回頭補這一格）
      _enqueue(source);
      return;
    }
    final index = timeline.frameAt(seconds);
    if (view._index == index) return;
    view._index = index;
    final found = _cached(source, index);
    if (found != null) view._show(found, notify: false);
    _refreshWanted(source);
  }

  void _refreshWanted(_GifSource<T> source) {
    final timeline = source.timeline;
    if (source.dead || source.failed || timeline == null) return;
    source.wanted.clear();
    final count = timeline.length;
    // 每個片段「現在這格」排在預先解的前面
    for (final view in source.views) {
      if (view._index >= 0 && !_cache.containsKey((source, view._index))) {
        source.wanted.add(view._index);
      }
    }
    // 預先解後面幾格；播到最後一格時繞回開頭，循環接回去不會卡一下
    for (var d = 1; d <= prefetch && d < count; d++) {
      for (final view in source.views) {
        if (view._index < 0) continue;
        final index = (view._index + d) % count;
        if (!_cache.containsKey((source, index))) source.wanted.add(index);
      }
    }
    _enqueue(source);
  }

  bool _needsWork(_GifSource<T> source) =>
      !_disposed &&
      !source.dead &&
      !source.failed &&
      (source.timeline == null || source.wanted.isNotEmpty);

  void _enqueue(_GifSource<T> source) {
    if (!_needsWork(source)) return;
    _queue.add(source);
    if (!_running) unawaited(_run());
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final source = _queue.first;
        _queue.remove(source);
        if (!_needsWork(source)) continue;
        source.busy = true;
        try {
          await _step(source);
        } catch (_) {
          // 解不開的檔：停在這裡，畫面留著最後解好的那格。
          // 不重試——下一個時鐘刻度又從頭解到同一格再失敗，就是空轉
          source.failed = true;
          source.wanted.clear();
          _closeCursors(source);
        } finally {
          source.busy = false;
          if (source.dead) _closeCursors(source);
        }
        _enqueue(source);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _step(_GifSource<T> source) async {
    if (source.timeline == null) {
      await _scan(source);
      return;
    }
    final target = source.wanted.first;
    final cursor = await _cursorFor(source, target);
    if (cursor == null || source.dead || _disposed) return;
    cursor.used = ++_clock;
    final index = cursor.next++;
    final (raw, _) = await cursor.decoder.nextFrame();
    // 解到最後一格的游標沒用了，早點放掉它手上的整張畫布
    if (cursor.next >= cursor.decoder.frameCount) _closeCursor(source, cursor);
    if (source.dead || _disposed || !source.wanted.contains(index)) {
      disposeImage(raw);
      return;
    }
    final frame = await prepare(raw);
    if (source.dead || _disposed || !source.wanted.remove(index)) {
      disposeImage(frame);
      return;
    }
    for (final view in source.views.toList()) {
      if (view._index == index) view._show(frame, notify: true);
    }
    _store(source, index, frame);
  }

  /// 拿一個能往後解到 [target] 的游標：挑離目標最近、還沒超過它的；
  /// 沒有就開新的，開滿了就把最久沒用的那個從頭重開
  Future<_GifCursor<T>?> _cursorFor(_GifSource<T> source, int target) async {
    _GifCursor<T>? best;
    for (final c in source.cursors) {
      if (c.next <= target && (best == null || c.next > best.next)) best = c;
    }
    if (best != null) return best;
    if (source.cursors.length >= cursorsPerSource) {
      _closeCursor(
        source,
        source.cursors.reduce((a, b) => a.used <= b.used ? a : b),
      );
    }
    final decoder = await open(source.bytes);
    if (source.dead || _disposed) {
      decoder.dispose();
      return null;
    }
    if (decoder.frameCount != source.timeline!.length) {
      decoder.dispose();
      if (source.measured) {
        throw const FormatException('GIF frame count changed');
      }
      // 檔頭讀出來的格數跟解碼器對不上：時間表改由解碼器量
      source.timeline = null;
      source.wanted.clear();
      for (final view in source.views) {
        view._index = -1;
      }
      return null;
    }
    final cursor = _GifCursor<T>(decoder);
    source.cursors.add(cursor);
    return cursor;
  }

  /// 讀不懂檔頭時的退路：整支逐格解一次，只記每格的時間、圖當場丟掉
  Future<void> _scan(_GifSource<T> source) async {
    final decoder = await open(source.bytes);
    try {
      final ends = <int>[];
      var total = 0;
      for (var i = 0; i < decoder.frameCount; i++) {
        final (image, duration) = await decoder.nextFrame();
        disposeImage(image);
        if (source.dead || _disposed) return;
        total += GifTimeline.frameMs(duration.inMilliseconds);
        ends.add(total);
      }
      if (ends.isEmpty) throw const FormatException('GIF has no frames');
      source.timeline = GifTimeline(ends);
      source.measured = true;
    } finally {
      decoder.dispose();
    }
    // 時間表有了：每個片段照自己最後要的時間重新對格
    for (final view in source.views.toList()) {
      final seconds = view._seconds;
      if (seconds == null) continue;
      view._index = source.timeline!.frameAt(seconds);
      final found = _cached(source, view._index);
      if (found != null) view._show(found, notify: true);
    }
    _refreshWanted(source);
  }

  void _store(_GifSource<T> source, int index, T frame) {
    final size = bytesOf(frame);
    if (size > byteBudget) {
      disposeImage(frame);
      return;
    }
    final old = _cache.remove((source, index));
    if (old != null) {
      _cacheBytes -= bytesOf(old);
      disposeImage(old);
    }
    _cache[(source, index)] = frame;
    _cacheBytes += size;
    // 超量就丟最久沒用的。各片段眼前要用的那幾格（現在這格到預先解的
    // 最後一格）不丟：游標只能往後走，預先解好的格子還沒播到就被丟掉，
    // 播到時就得倒回第 0 格重解。畫面上同時的 GIF 多到連這幾格都放不下
    // 時，寧可暫時超量
    while (_cacheBytes > byteBudget) {
      (_GifSource<T>, int)? victim;
      for (final key in _cache.keys) {
        if (!_inUse(key.$1, key.$2)) {
          victim = key;
          break;
        }
      }
      if (victim == null) break;
      final oldest = _cache.remove(victim) as T;
      _cacheBytes -= bytesOf(oldest);
      disposeImage(oldest);
    }
  }

  /// [index] 是不是某個片段「現在這格」或預先解的那幾格
  bool _inUse(_GifSource<T> source, int index) {
    final count = source.timeline?.length ?? 0;
    if (count == 0) return false;
    for (final view in source.views) {
      if (view._index < 0) continue;
      if ((index - view._index) % count <= prefetch) return true;
    }
    return false;
  }

  void _closeCursor(_GifSource<T> source, _GifCursor<T> cursor) {
    if (source.cursors.remove(cursor)) cursor.decoder.dispose();
  }

  void _closeCursors(_GifSource<T> source) {
    for (final cursor in source.cursors) {
      cursor.decoder.dispose();
    }
    source.cursors.clear();
  }

  void _release(TimelineGifPreview<T> view) {
    final source = view._source;
    source.views.remove(view);
    if (source.views.isNotEmpty) {
      _refreshWanted(source);
      return;
    }
    if (identical(_sources[source.bytes], source)) {
      _sources.remove(source.bytes);
    }
    _drop(source);
  }

  void _drop(_GifSource<T> source) {
    source.dead = true;
    source.wanted.clear();
    _queue.remove(source);
    // 正在解的那一步收尾時會自己關（見 _run 的 finally）
    if (!source.busy) _closeCursors(source);
    for (final key in _cache.keys.where((k) => k.$1 == source).toList()) {
      final image = _cache.remove(key) as T;
      _cacheBytes -= bytesOf(image);
      disposeImage(image);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final source in _sources.values.toList()) {
      for (final view in source.views.toList()) {
        view.dispose();
      }
      _drop(source);
    }
    _sources.clear();
  }
}

class _GifSource<T> {
  _GifSource(this.bytes, this.timeline);
  final Uint8List bytes;

  /// null＝檔頭讀不懂、還沒用解碼器量
  GifTimeline? timeline;

  /// 時間表是解碼器量出來的（不會再跟解碼器對不上）
  bool measured = false;
  final views = <TimelineGifPreview<T>>{};

  /// 要解的格子，照優先順序（各片段現在這格在前、預先解的在後）
  final wanted = <int>{};
  final cursors = <_GifCursor<T>>[];
  bool dead = false, busy = false, failed = false;
}

class _GifCursor<T> {
  _GifCursor(this.decoder);
  final GifPreviewDecoder<T> decoder;

  /// 下一次 nextFrame 會拿到第幾格
  int next = 0;
  int used = 0;
}

/// 一個 GIF 片段在預覽池裡的位置：跟著時鐘 [seek]，畫 [image]
class TimelineGifPreview<T> {
  TimelineGifPreview._(this._pool, this._source, this._onChanged);
  final TimelineGifPreviewPool<T> _pool;
  final _GifSource<T> _source;
  final void Function() _onChanged;
  int _index = -1;
  double? _seconds;
  bool _disposed = false;
  T? _image;

  /// 目前該畫的那格（還沒解好任何一格時是 null）
  T? get image => _image;

  void seek(double seconds) {
    if (!_disposed) _pool._request(this, seconds);
  }

  void _show(T image, {required bool notify}) {
    if (_disposed) return;
    final previous = _image;
    _image = _pool.clone(image);
    if (previous != null) _pool.disposeImage(previous);
    if (notify) _onChanged();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final previous = _image;
    _image = null;
    if (previous != null) _pool.disposeImage(previous);
    _pool._release(this);
  }
}

TimelineGifPreviewPool<ui.Image> createTimelineGifPreviewPool() =>
    TimelineGifPreviewPool<ui.Image>(
      open: (bytes) async =>
          _ImageGifDecoder(await ui.instantiateImageCodec(bytes)),
      prepare: resizeGifPreviewFrame,
      bytesOf: (image) => image.width * image.height * 4,
      clone: (image) => image.clone(),
      disposeImage: (image) => image.dispose(),
    );

/// 把一格縮到長邊 [maxSide] 再留：動畫的解碼器不管 targetWidth，
/// 解出來永遠是原尺寸。原尺寸那張當場釋放
Future<ui.Image> resizeGifPreviewFrame(
  ui.Image source, {
  int maxSide = 480,
}) async {
  final scale = math.min(1.0, maxSide / math.max(source.width, source.height));
  if (scale == 1) return source;
  ui.Picture? picture;
  try {
    final width = math.max(1, (source.width * scale).round());
    final height = math.max(1, (source.height * scale).round());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    picture = recorder.endRecording();
    return await picture.toImage(width, height);
  } finally {
    picture?.dispose();
    source.dispose();
  }
}
