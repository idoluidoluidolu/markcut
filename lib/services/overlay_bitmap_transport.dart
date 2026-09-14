import 'dart:typed_data';

/// Only the currently acknowledged bitmap IDs are retained, never image bytes.
/// Native reuse is scoped to its current overlay list. A rebuild or eviction
/// rejects the entire delta before display; retrying the full list is atomic.
class OverlayBitmapTransport {
  final Expando<String> _ids = Expando<String>('overlayBitmapIds');
  static int _nextId = 0;
  Set<String> _acknowledged = {};
  bool? _supportsDelta;
  int _revision = 0;
  int lastSentBytes = 0;
  int lastReusedParts = 0;
  int fullRetries = 0;

  Future<bool> send(
    List<Map<String, dynamic>> overlays, {
    required Future<bool?> Function(String, Map<String, dynamic>) invoke,
    List<Map<String, dynamic>>? live,
    List<Map<String, dynamic>> Function()? liveProvider,
    bool noNudge = false,
  }) async {
    final revision = ++_revision;
    lastSentBytes = 0;
    lastReusedParts = 0;
    final full = [
      for (final overlay in overlays)
        <String, dynamic>{
          for (final entry in overlay.entries)
            if (!entry.key.startsWith('_')) entry.key: entry.value,
        },
    ];
    final nextIds = <String>{};
    final delta = <Map<String, dynamic>>[];
    for (final part in full) {
      final bytes = part['raw'] ?? part['png'];
      if (bytes is Uint8List) {
        final id = _ids[bytes] ??= 'bitmap-${++_nextId}';
        part['bitmapId'] = id;
        nextIds.add(id);
        if (_supportsDelta != false && _acknowledged.contains(id)) {
          delta.add(
            {...part}
              ..remove('raw')
              ..remove('png'),
          );
          lastReusedParts++;
          continue;
        }
      }
      delta.add(part);
    }
    Map<String, dynamic> payload(List<Map<String, dynamic>> parts) => {
      'overlays': parts,
      'live': ?(liveProvider?.call() ?? live),
      'noNudge': noNudge,
    };
    int byteCount(List<Map<String, dynamic>> parts) => parts.fold(0, (n, p) {
      final b = p['raw'] ?? p['png'];
      return n + (b is Uint8List ? b.lengthInBytes : 0);
    });
    if (_supportsDelta != false) {
      lastSentBytes += byteCount(delta);
      final accepted = await invoke('setOverlayParts', payload(delta));
      // A newer update may have passed us while this channel call was waiting.
      // Never retry an older full bitmap/geometry snapshot over that update.
      if (revision != _revision) return accepted == true;
      _supportsDelta = accepted != null;
      if (accepted == true) {
        _acknowledged = nextIds;
        return true;
      }
      fullRetries++;
    }
    // Also supports older native builds without the delta method.
    lastReusedParts = 0;
    lastSentBytes += byteCount(full);
    final restored = await invoke('setOverlays', payload(full)) == true;
    if (revision == _revision) _acknowledged = restored ? nextIds : {};
    return restored;
  }
}
