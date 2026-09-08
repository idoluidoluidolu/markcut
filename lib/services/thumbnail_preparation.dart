import 'dart:async';

/// Give every clip a cover before spending time on a complete thumbnail strip.
/// [items] is read again between requests so new clips and priority changes are
/// picked up without launching a second decoder. Failed requests are attempted
/// only once per run; a later run can retry them.
Future<void> prepareTimelineThumbnails<T extends Object>({
  required List<T> Function() items,
  required bool Function() alive,
  required bool Function() canLoadCover,
  required bool Function(T) needsCover,
  required bool Function(T) needsStrip,
  required Future<void> Function() waitForStrip,
  required Future<void> Function(T item, bool coverOnly) load,
  Future<void> Function()? waitWhileBusy,
}) async {
  final coversAttempted = <T>{};
  final stripsAttempted = <T>{};
  Future<void> pause() =>
      waitWhileBusy?.call() ??
      Future<void>.delayed(const Duration(milliseconds: 200));

  T? nextCover() {
    for (final item in items()) {
      if (!coversAttempted.contains(item) && needsCover(item)) return item;
    }
    return null;
  }

  while (alive()) {
    final cover = nextCover();
    if (cover != null) {
      // Scrubbing does not need to stop just to get a 200 px identification
      // cover. Playback/export still own the decoder while they are running.
      if (!canLoadCover()) {
        await pause();
        continue;
      }
      coversAttempted.add(cover);
      await load(cover, true);
      continue;
    }

    final pending = items().where(
      (item) => !stripsAttempted.contains(item) && needsStrip(item),
    );
    if (pending.isEmpty) return;
    await waitForStrip();
    if (!alive()) return;
    // Imports/edits can happen while waiting for an idle preview. Their first
    // cover still has priority over a second frame from an existing clip.
    if (nextCover() != null) continue;
    final current = items().where(
      (item) => !stripsAttempted.contains(item) && needsStrip(item),
    );
    if (current.isEmpty) return;
    final item = current.first;
    stripsAttempted.add(item);
    await load(item, false);
  }
}
