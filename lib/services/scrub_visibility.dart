import '../models/timeline.dart';

/// The composition cache currently displays only the highest video clip.
/// Consequently this fast path is narrower than native composition culling:
/// only an opaque, unmodified top video covering the entire canvas can make
/// lower frame requests unnecessary. Mixed overlays stay on the existing path.
List<TimelineClip> scrubVideoCandidates(
  TimelineModel timeline, {
  required double time,
  required double canvasAspect,
  Set<int> hiddenTracks = const {},
  Set<String> knownOpaquePaths = const {},
}) {
  final videos = timeline
      .videosAt(time)
      .where((clip) => !hiddenTracks.contains(clip.track))
      .toList();
  if (videos.length < 2 || !canvasAspect.isFinite || canvasAspect <= 0) {
    return videos;
  }
  // Images/GIFs, masks and styled timeline clips may be baked into the native
  // frame. Do not enable the one-video cache cover earlier for those scenes.
  // The ordinary global watermark is a separate overlay, not a timeline clip.
  for (final clip in timeline.clips) {
    if (hiddenTracks.contains(clip.track) || !clip.coversForDisplay(time)) {
      continue;
    }
    final kind = timeline.sourceOf(clip).kind;
    if (kind != ClipKind.video && kind != ClipKind.audio) return videos;
  }

  final top = videos.last;
  final source = timeline.sourceOf(top);
  // Opaqueness must come from the native asset's format/alpha metadata. File
  // extensions and `kind == video` do not prove that HEVC has no alpha channel.
  if (!knownOpaquePaths.contains(source.previewPath) ||
      source.isGif ||
      source.w <= 0 ||
      source.h <= 0 ||
      top.reverse ||
      top.opacity != 1 ||
      top.fadeIn != 0 ||
      top.fadeOut != 0 ||
      top.rotation != 0 ||
      top.cropL != 0 ||
      top.cropT != 0 ||
      top.cropW != 1 ||
      top.cropH != 1 ||
      top.color.hasColor ||
      !top.scale.isFinite ||
      top.scale <= 0 ||
      !top.px.isFinite ||
      !top.py.isFinite ||
      time >= top.end) {
    return videos;
  }

  // Same aspect-fit and centered scale/position as the editor's layerBox.
  // Normalize canvas height to one; no screen-density rounding is introduced.
  final aspect = source.aspect;
  final width = (aspect >= canvasAspect ? canvasAspect : aspect) * top.scale;
  final height =
      (aspect >= canvasAspect ? canvasAspect / aspect : 1) * top.scale;
  final left = top.px * canvasAspect - width / 2;
  final right = top.px * canvasAspect + width / 2;
  final upper = top.py - height / 2;
  final lower = top.py + height / 2;
  const epsilon = 1e-9;
  if (left <= epsilon &&
      right >= canvasAspect - epsilon &&
      upper <= epsilon &&
      lower >= 1 - epsilon) {
    return [top];
  }
  return videos;
}
