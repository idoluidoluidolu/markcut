import 'package:flutter/material.dart';

enum EditorRegion { preview, controls, timeline, watermark, export }

/// Sections have stable widget identities and their own invalidation signal.
/// UI-only changes do not invalidate the project/render-content revision.
class EditorRegions {
  final _signals = {
    for (final region in EditorRegion.values) region: ValueNotifier(0),
  };
  ValueNotifier<int> signal(EditorRegion region) => _signals[region]!;
  void invalidate(Iterable<EditorRegion> regions) {
    for (final region in regions) {
      signal(region).value++;
    }
  }

  void dispose() {
    for (final signal in _signals.values) {
      signal.dispose();
    }
  }
}

class EditorRegionView extends StatelessWidget {
  const EditorRegionView({
    super.key,
    required this.revision,
    required this.builder,
  });
  final ValueNotifier<int> revision;
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: revision,
    builder: (context, _, child) => builder(context),
  );
}
