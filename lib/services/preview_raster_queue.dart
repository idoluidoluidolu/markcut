import 'dart:async';

/// One offscreen preview raster/readback at a time. These jobs share Flutter's
/// raster/GPU queue: launching more futures does not provide independent GPUs,
/// but does retain more pictures, textures and readback buffers concurrently.
/// Interactive parts precede queued refinements; running GPU work is not killed.
class PreviewRasterQueue<T> {
  final List<_RasterJob<T>> _pending = [];
  bool _running = false;
  bool _disposed = false;
  int get pending => _pending.length;

  Future<T?> run(Future<T?> Function() draw, {required bool interactive}) {
    if (_disposed) return Future.value();
    final job = _RasterJob(draw, interactive);
    _pending.add(job);
    _drain();
    return job.result.future;
  }

  void _drain() {
    if (_running || _disposed || _pending.isEmpty) return;
    final priority = _pending.indexWhere((j) => j.interactive);
    final job = _pending.removeAt(priority < 0 ? 0 : priority);
    _running = true;
    unawaited(() async {
      try {
        job.result.complete(await job.draw());
      } catch (e, stack) {
        job.result.completeError(e, stack);
      } finally {
        _running = false;
        _drain();
      }
    }());
  }

  void dispose() {
    _disposed = true;
    for (final job in _pending) {
      job.result.complete(null);
    }
    _pending.clear();
  }
}

class _RasterJob<T> {
  _RasterJob(this.draw, this.interactive);
  final Future<T?> Function() draw;
  final bool interactive;
  final result = Completer<T?>();
}
