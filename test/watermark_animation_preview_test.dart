import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/widgets/watermark_animation_preview.dart';

void main() {
  testWidgets('動畫時鐘只重建預覽，靜態、背景與其他路由會停下', (t) async {
    final enabled = ValueNotifier(false);
    addTearDown(enabled.dispose);
    var parentBuilds = 0;
    var previewBuilds = 0;
    double? time;
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, _) {
            parentBuilds++;
            return WatermarkAnimationPreview(
              enabled: value,
              builder: (_, seconds) {
                previewBuilds++;
                time = seconds;
                return const SizedBox();
              },
            );
          },
        ),
      ),
    );
    expect(time, isNull);
    var count = previewBuilds;
    await t.pump(const Duration(seconds: 1));
    expect(previewBuilds, count);
    enabled.value = true;
    await t.pump();
    await t.pump();
    final parents = parentBuilds;
    await t.pump(const Duration(milliseconds: 500));
    expect(time, closeTo(0.5, 0.01));
    expect(parentBuilds, parents);

    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    count = previewBuilds;
    await t.pump(const Duration(seconds: 2));
    expect(previewBuilds, count);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    final before = time!;
    await t.pump(const Duration(milliseconds: 250));
    expect(time!, greaterThan(before));

    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await t.pumpAndSettle();
    count = previewBuilds;
    await t.pump(const Duration(seconds: 1));
    expect(previewBuilds, count);
    nav.currentState!.pop();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    enabled.value = false;
    await t.pumpAndSettle();
    expect(time, isNull);
    count = previewBuilds;
    await t.pump(const Duration(seconds: 1));
    expect(previewBuilds, count);
    await t.pumpWidget(const SizedBox());
    expect(t.takeException(), isNull);
  });
}
