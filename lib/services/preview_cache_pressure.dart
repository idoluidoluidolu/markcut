import 'dart:collection';
import 'dart:typed_data';

Set<Uint8List> _bitmapSet(List<Map<String, dynamic>> parts) {
  final bytes = HashSet<Uint8List>.identity();
  for (final part in parts) {
    final value = part['raw'] ?? part['png'];
    if (value is Uint8List) bytes.add(value);
  }
  return bytes;
}

int previewBitmapBytes(List<Map<String, dynamic>> parts) =>
    _bitmapSet(parts).fold<int>(0, (n, bytes) => n + bytes.lengthInBytes);

/// Keep a bounded current bitmap set, preserving byte identity for native
/// delta reuse. Historical styles are evicted, not rebuilt after every warning.
/// If the current set is too large, release it as a unit (no partial map cache).
bool trimPreviewPartCache<T>(
  Map<String, T> cache,
  List<Map<String, dynamic>> current, {
  required Uint8List Function(T) bytesOf,
  required int maxBytes,
}) {
  final active = _bitmapSet(current);
  final keepCurrent =
      active.fold<int>(0, (n, bytes) => n + bytes.lengthInBytes) <= maxBytes;
  cache.removeWhere(
    (_, part) => !keepCurrent || !active.contains(bytesOf(part)),
  );
  return keepCurrent;
}
