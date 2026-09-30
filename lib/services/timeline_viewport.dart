import 'dart:math' as math;
import '../models/timeline.dart';

/// Build once per content revision, query only clips intersecting the viewport.
/// Prefix maximum end times also handle legacy overlapping/long clips.
class TimelineViewportIndex {
  TimelineViewportIndex(Iterable<TimelineClip> clips) {
    for (final clip in clips) {
      (_tracks[clip.track] ??= []).add(clip);
      usedTracks = math.max(usedTracks, clip.track + 1);
      duration = math.max(duration, clip.end);
      _byId.putIfAbsent(clip.id, () => clip);
    }
    for (final entry in _tracks.entries) {
      entry.value.sort((a, b) => a.offset.compareTo(b.offset));
      var end = double.negativeInfinity;
      _ends[entry.key] = [
        for (final c in entry.value) end = math.max(end, c.end),
      ];
    }
  }
  int usedTracks = 0;
  double duration = 0;
  int? trackOf(int id) => _byId[id]?.track;
  final _tracks = <int, List<TimelineClip>>{};
  final _ends = <int, List<double>>{};
  final _byId = <int, TimelineClip>{};
  List<TimelineClip> onTrack(int track) => _tracks[track] ?? const [];

  List<TimelineClip> visible(
    int track,
    double start,
    double end,
    Set<int> pinned,
  ) {
    final clips = onTrack(track);
    final ends = _ends[track];
    if (ends == null) return [];
    var lo = 0, hi = ends.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (ends[mid] < start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final result = <TimelineClip>[];
    final found = <int>{};
    for (var i = lo; i < clips.length && clips[i].offset <= end; i++) {
      final clip = clips[i];
      if (clip.end >= start) {
        result.add(clip);
        found.add(clip.id);
      }
    }
    for (final id in pinned) {
      final clip = _byId[id];
      if (clip != null && clip.track == track && found.add(id)) {
        result.add(clip);
      }
    }
    return result;
  }
}
