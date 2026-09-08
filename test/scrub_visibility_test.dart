import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/scrub_visibility.dart';

TimelineModel fiveVideos({int topWidth = 1080, int topHeight = 1920}) {
  final timeline = TimelineModel();
  for (var i = 0; i < 5; i++) {
    timeline.sources.add(
      MediaSource(
        path: '/$i.mp4',
        name: '$i',
        kind: ClipKind.video,
        duration: 10,
        w: i == 4 ? topWidth : 1080,
        h: i == 4 ? topHeight : 1920,
      ),
    );
    timeline.clips.add(
      TimelineClip(
        id: i,
        sourceIndex: i,
        trimStart: 0,
        trimEnd: 10,
        offset: 0,
        track: i,
      ),
    );
  }
  return timeline;
}

List<int> candidates(
  TimelineModel timeline, {
  Set<String> opaque = const {'/4.mp4'},
  double time = 1,
  Set<int> hidden = const {},
  double canvas = 9 / 16,
}) => scrubVideoCandidates(
  timeline,
  time: time,
  canvasAspect: canvas,
  hiddenTracks: hidden,
  knownOpaquePaths: opaque,
).map((c) => c.id).toList();

void main() {
  test(
    'five stacked opaque full-canvas videos request only the top source',
    () {
      expect(candidates(fiveVideos()), [4]);
      // Ordinary global watermark settings do not add a timeline source, so
      // the standard watermark editor remains eligible for this fast path.
    },
  );

  test(
    'PiP, portrait letterboxing and an unknown aspect retain all layers',
    () {
      final pip = fiveVideos()..clips.last.scale = 0.5;
      expect(candidates(pip), [0, 1, 2, 3, 4]);
      expect(candidates(fiveVideos(topWidth: 1920, topHeight: 1080)), [
        0,
        1,
        2,
        3,
        4,
      ]);
      expect(candidates(fiveVideos(topWidth: 0)), [0, 1, 2, 3, 4]);
      expect(candidates(fiveVideos(), canvas: 1), [0, 1, 2, 3, 4]);
    },
  );

  test('unknown alpha or a changed file path cannot occlude lower videos', () {
    expect(candidates(fiveVideos(), opaque: {}), [0, 1, 2, 3, 4]);
    final changed = fiveVideos();
    changed.sources.last.workPath = '/new-proxy.mp4';
    expect(candidates(changed), [0, 1, 2, 3, 4]);
    expect(candidates(changed, opaque: {'/new-proxy.mp4'}), [4]);
  });

  test(
    'transparency, fades, rotation, crop, color and reverse remain conservative',
    () {
      final changes = <void Function(TimelineClip)>[
        (c) => c.opacity = 0.99,
        (c) => c.fadeIn = 1,
        (c) => c.fadeOut = 1,
        (c) => c.rotation = 90,
        (c) => c.cropW = 0.9,
        (c) => c.cropL = 0.1,
        (c) => c.px = 0.6,
        (c) => c.scale = double.nan,
        (c) => c.color.brightness = 0.1,
        (c) => c.reverse = true,
      ];
      for (final change in changes) {
        final timeline = fiveVideos();
        change(timeline.clips.last);
        expect(candidates(timeline), [0, 1, 2, 3, 4]);
      }
    },
  );

  test(
    'mixed still/GIF/mosaic/text/watermark clips preserve the existing cache path',
    () {
      for (final kind in [
        ClipKind.image,
        ClipKind.mosaic,
        ClipKind.text,
        ClipKind.wm,
      ]) {
        final timeline = fiveVideos();
        timeline.sources.add(
          MediaSource(
            path: '/overlay',
            name: 'overlay',
            kind: kind,
            duration: 10,
            isGif: kind == ClipKind.image,
          ),
        );
        timeline.clips.add(
          TimelineClip(
            id: 5,
            sourceIndex: 5,
            trimStart: 0,
            trimEnd: 10,
            offset: 0,
            track: 5,
          ),
        );
        expect(candidates(timeline), [0, 1, 2, 3, 4]);
        expect(candidates(timeline, hidden: {5}), [4]);
      }
    },
  );

  test(
    'audio does not obstruct visibility and hidden top video exposes the next',
    () {
      final timeline = fiveVideos();
      timeline.sources.add(
        MediaSource(
          path: '/audio',
          name: 'audio',
          kind: ClipKind.audio,
          duration: 10,
        ),
      );
      timeline.clips.add(
        TimelineClip(
          id: 5,
          sourceIndex: 5,
          trimStart: 0,
          trimEnd: 10,
          offset: 0,
          track: 5,
        ),
      );
      expect(candidates(timeline), [4]);
      expect(candidates(timeline, hidden: {4}, opaque: {'/3.mp4'}), [3]);
    },
  );

  test(
    'a full middle layer cannot conceal a smaller highest layer for this cache',
    () {
      final timeline = fiveVideos()..clips.last.scale = 0.5;
      expect(candidates(timeline, opaque: {'/3.mp4', '/4.mp4'}), [
        0,
        1,
        2,
        3,
        4,
      ]);
      expect(candidates(fiveVideos(), time: 10), [0, 1, 2, 3, 4]);
      expect(candidates(fiveVideos(), canvas: double.nan), [0, 1, 2, 3, 4]);
    },
  );

  test(
    'native opacity proof belongs to its successful player, older native stays unknown',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('markcut/comp');
      var includeProof = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'available') return true;
        if (call.method == 'build') {
          return <String, dynamic>{
            'textureId': 1,
            'duration': 10.0,
            if (includeProof) 'opaqueSourcePaths': ['/4.mp4', '/4.mp4'],
          };
        }
        return null;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final timeline = fiveVideos();
      for (final source in timeline.sources) {
        source.workPath = source.path;
      }
      final first = await CompPlayer.build(timeline);
      expect(first, isNotNull);
      expect(first!.knownOpaquePaths, {'/4.mp4'});
      expect(
        () => first.knownOpaquePaths.add('/unknown.mp4'),
        throwsUnsupportedError,
      );
      includeProof = false;
      final next = await CompPlayer.build(timeline);
      expect(next, isNotNull);
      expect(next!.knownOpaquePaths, isEmpty);
      expect(first.knownOpaquePaths, {'/4.mp4'});
    },
  );
}
