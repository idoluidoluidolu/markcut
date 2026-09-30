import 'dart:async';
import 'package:flutter/foundation.dart';
import 'waveform_job.dart';

import 'waveform_decode_io.dart'
    if (dart.library.js_interop) 'waveform_decode_web.dart';

typedef WaveformDecoder =
    Future<List<double>?> Function(String path, {WaveformJob? job});

/// Visible clips lease their results. Completion only updates that file's UI.
/// A single decoder and bounded admission also cover pending/failed work.
class WaveformCache extends ChangeNotifier {
  WaveformCache._() : _decode = decodeWaveformPeaks, _maxEntries = 128;
  @visibleForTesting
  WaveformCache.forTest(this._decode, {int maxEntries = 128})
    // Public test budget keeps admission regressions reproducible.
    // ignore: prefer_initializing_formals
    : _maxEntries = maxEntries;

  static final WaveformCache instance = WaveformCache._();
  final WaveformDecoder _decode;
  final int _maxEntries;
  final _peaks = <String, List<double>>{};
  final _jobs = <String, WaveformJob>{};
  final _failed = <String>{};
  final _deferred = <String>{};
  final _owners = <Object, Set<String>>{};
  final _signals = <String, ValueNotifier<List<double>?>>{};
  bool _draining = false;
  bool _disposed = false;
  static const _warmEntries = 12;

  Set<String> get _wanted => {for (final paths in _owners.values) ...paths};

  void retain(Object owner, Set<String> paths) {
    if (_disposed || setEquals(_owners[owner], paths)) return;
    _owners[owner] = Set.of(paths);
    _cancelUnused();
  }

  void release(Object owner) {
    _owners.remove(owner);
    _cancelUnused();
  }

  /// Acquire after retain; remove listeners before release.
  ValueListenable<List<double>?> listenTo(String path) =>
      _signals.putIfAbsent(path, () => ValueNotifier(of(path)));

  void _cancelUnused() {
    final keep = _wanted;
    for (final path in _jobs.keys.toList()) {
      if (!keep.contains(path)) _jobs.remove(path)?.cancel();
    }
    _failed.removeWhere((path) => !keep.contains(path));
    _deferred.removeWhere((path) => !keep.contains(path));
    for (final path in _signals.keys.toList()) {
      if (!keep.contains(path)) _signals.remove(path)?.dispose();
    }
    final cold = _peaks.keys.where((p) => !keep.contains(p)).toList();
    for (final path in cold.take(
      (cold.length - _warmEntries).clamp(0, cold.length),
    )) {
      _peaks.remove(path);
    }
    _admitDeferred();
  }

  bool _makeRoom() {
    if (_jobs.length + _peaks.length < _maxEntries) return true;
    final keep = _wanted;
    for (final path in _peaks.keys.toList()) {
      if (!keep.contains(path)) {
        _peaks.remove(path);
        return true;
      }
    }
    return false;
  }

  List<double>? of(String path) {
    if (_disposed) return null;
    final p = _peaks.remove(path);
    if (p != null) {
      _peaks[path] = p;
      return p;
    }
    if (_failed.contains(path) || _jobs.containsKey(path)) return null;
    if (!_makeRoom()) {
      if (_wanted.contains(path)) _deferred.add(path);
      return null;
    }
    _jobs[path] = WaveformJob();
    if (!_draining) unawaited(_drain());
    return null;
  }

  void _admitDeferred() {
    if (_disposed) return;
    for (final path in _deferred.toList()) {
      if (!_makeRoom()) break;
      _deferred.remove(path);
      of(path);
    }
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_jobs.isNotEmpty && !_disposed) {
        final entry = _jobs.entries.first;
        List<double>? peaks;
        try {
          peaks = await _decode(entry.key, job: entry.value);
        } catch (_) {}
        if (_disposed ||
            entry.value.cancelled ||
            !identical(_jobs[entry.key], entry.value)) {
          continue;
        }
        _jobs.remove(entry.key);
        if (peaks != null && peaks.isNotEmpty) {
          // 128 * 6000 * 4 = 3,072,000 bytes of sample storage at most.
          final compact = Float32List.fromList(peaks.take(6000).toList());
          _peaks[entry.key] = compact;
          _signals[entry.key]?.value = compact;
          notifyListeners();
        } else {
          _failed.add(entry.key);
          while (_failed.length > _maxEntries) {
            _failed.remove(_failed.first);
          }
        }
        _admitDeferred();
      }
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      job.cancel();
    }
    for (final signal in _signals.values) {
      signal.dispose();
    }
    _signals.clear();
    _jobs.clear();
    _peaks.clear();
    _owners.clear();
    _deferred.clear();
    super.dispose();
  }
}
