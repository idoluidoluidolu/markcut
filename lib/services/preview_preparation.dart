import 'dart:async';

import '../models/timeline.dart';

/// Reorder preparation jobs, never the user's clips or source list. The video
/// at the playhead gets the first decoder turn; other visible short jobs then
/// complete before a long background clip can monopolize the encoder.
List<int> prioritizePreviewPreparation({
  required TimelineModel timeline,
  required Iterable<int> pending,
  required double position,
  Set<int> hiddenTracks = const {},
}) {
  final jobs = pending
      .where((i) => i >= 0 && i < timeline.sources.length)
      .where((i) => timeline.sources[i].isVideo)
      .toSet()
      .toList();
  final top = timeline.videoAt(position, skipTracks: hiddenTracks);
  final scores = <int, ({int tier, double distance, double cost})>{};
  for (final i in jobs) {
    var tier = 3;
    var distance = double.infinity;
    for (final clip in timeline.clips) {
      if (clip.sourceIndex != i || hiddenTracks.contains(clip.track)) continue;
      if (clip.coversForDisplay(position)) {
        tier = top?.sourceIndex == i ? 0 : 1;
        distance = 0;
        break;
      }
      tier = 2;
      final gap = position < clip.offset
          ? clip.offset - position
          : position - clip.end;
      if (gap < distance) distance = gap;
    }
    final duration = timeline.sources[i].duration;
    scores[i] = (
      tier: tier,
      distance: distance,
      cost: duration.isFinite && duration > 0 ? duration : double.infinity,
    );
  }
  jobs.sort((a, b) {
    final x = scores[a]!, y = scores[b]!;
    final tier = x.tier.compareTo(y.tier);
    if (tier != 0) return tier;
    final distance = x.distance.compareTo(y.distance);
    if (distance != 0) return distance;
    final cost = x.cost.compareTo(y.cost);
    return cost != 0 ? cost : a.compareTo(b);
  });
  return jobs;
}

/// Yield immediately to interaction, but resume only after a stable idle
/// interval. Repeated idle notifications do not postpone the same timer.
class PreviewPreparationActivity {
  PreviewPreparationActivity({
    required this.onChanged,
    this.idleDelay = const Duration(milliseconds: 600),
  });

  final void Function(bool interactive) onChanged;
  final Duration idleDelay;
  Timer? _resume;
  bool _interactive = false;
  bool _disposed = false;

  bool get interactive => _interactive;

  void update(bool interactive) {
    if (_disposed) return;
    if (interactive) {
      _resume?.cancel();
      _resume = null;
      if (!_interactive) {
        _interactive = true;
        onChanged(true);
      }
    } else if (_interactive && _resume == null) {
      _resume = Timer(idleDelay, () {
        _resume = null;
        _interactive = false;
        onChanged(false);
      });
    }
  }

  void dispose() {
    _disposed = true;
    _resume?.cancel();
    _resume = null;
    if (_interactive) {
      _interactive = false;
      onChanged(false);
    }
  }
}
