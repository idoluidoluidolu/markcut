import 'dart:typed_data';

/// One batch owns this cache. Keep only the latest overlay, with a byte limit,
/// so a batch of 4K clips does not retain an overlay for every output size.
class BatchOverlayCache {
  BatchOverlayCache({this.maxBytes = 16 * 1024 * 1024});

  final int maxBytes;
  String? _key;
  Uint8List? _bytes;

  Future<Uint8List> get(
    String key,
    Future<Uint8List> Function() render,
  ) async {
    if (_key == key && _bytes != null) return _bytes!;
    _key = null;
    _bytes = null;
    final bytes = await render();
    if (bytes.length <= maxBytes) {
      _key = key;
      _bytes = bytes;
    }
    return bytes;
  }
}
