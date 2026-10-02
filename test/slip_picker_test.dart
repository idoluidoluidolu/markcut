import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/slip_picker.dart';
import 'package:markcut/widgets/slip_strip.dart';

import 'editor_harness.dart' show solidPng;

Finder get _strip => find.byKey(const ValueKey('slip-strip'));
Finder get _preview => find.byKey(const ValueKey('slip-preview-start'));
Finder get _image =>
    find.descendant(of: _preview, matching: find.byType(Image));

Future<void> _select(WidgetTester t, double seconds) async {
  final rect = t.getRect(_strip);
  final duration = t.widget<SlipStrip>(_strip).duration;
  await t.tapAt(
    Offset(rect.left + seconds / duration * rect.width, rect.center.dy),
  );
  await t.pump();
}

Future<void> _open(
  WidgetTester t, {
  double start = 2,
  double duration = 20,
  double length = 4,
  Future<Uint8List?> Function(double)? load,
  Future<Uint8List?> Function(double)? thumbnail,
  ValueChanged<double>? commit,
  double textScale = 1,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      home: Scaffold(
        backgroundColor: kBg,
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.88,
              child: SlipPicker(
                duration: duration,
                start: start,
                length: length,
                loadFrame: load ?? (_) async => null,
                loadThumbnail: thumbnail ?? (_) async => null,
                onCommit: commit ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets('直接顯示單一大預覽，點縮圖換開頭；片段長度不變', (t) async {
    final commits = <double>[];
    await _open(t, commit: commits.add);
    final preview = t.getRect(_preview);
    expect(preview.width, 350);
    expect(preview.height, greaterThan(350), reason: '進入換段就要是大預覽');
    expect(preview.bottom, lessThan(t.getRect(_strip).top));
    expect(find.byKey(const ValueKey('slip-preview-結尾')), findsNothing);
    await _select(t, 10);
    expect(commits.last, closeTo(10, 1e-6));

    expect(commits, hasLength(1));
    await _select(t, 13);
    expect(commits.last, closeTo(13, 1e-6));
    expect(t.widget<SlipStrip>(_strip).length, 4);
    expect(find.text('開頭 00:13.00'), findsOneWidget);
    expect(find.textContaining('結尾'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('拖曳夾住頭尾，短片仍能操作', (t) async {
    final commits = <double>[];
    await _open(
      t,
      start: 0.05,
      duration: 0.35,
      length: 0.2,
      commit: commits.add,
    );
    final width = t.getSize(_strip).width;
    await t.drag(_strip, Offset(-width, 0));
    await t.pump();
    expect(commits.last, 0);
    await _select(t, 0.1);
    expect(commits.last, closeTo(0.1, 1e-9));
    await t.drag(_strip, Offset(width, 0));
    await t.pump();
    expect(commits.last, closeTo(0.15, 1e-9));
    expect(t.widget<SlipStrip>(_strip).length, 0.2);
    expect(t.takeException(), isNull);
  });

  testWidgets('拖動中即時更新開頭，放手才提交，不再抽結尾大圖', (t) async {
    final samples = <double>[];
    final commits = <double>[];
    await _open(
      t,
      load: (s) async {
        samples.add(s);
        return null;
      },
      commit: commits.add,
    );
    await t.pump();
    expect(samples, [2]);
    final g = await t.startGesture(t.getCenter(_strip));
    await g.moveBy(const Offset(25, 0));
    await t.pump();
    await g.moveBy(const Offset(35, 0));
    await t.pump();
    final start = t.widget<SlipStrip>(_strip).start;
    expect(start, greaterThan(2));
    expect(commits, isEmpty);
    expect(samples, contains(closeTo((start * 1000).round() / 1000, 0.0001)));
    await g.up();
    await t.pump();
    expect(commits.single, start);
  });

  testWidgets('新起點優先，過期回覆不冒充新畫面，關閉後不繼續抽圖', (t) async {
    final requests = <double>[];
    final jobs = <Completer<Uint8List?>>[];
    await _open(
      t,
      load: (s) {
        requests.add(s);
        final job = Completer<Uint8List?>();
        jobs.add(job);
        return job.future;
      },
    );
    expect(requests, [2]);
    await _select(t, 2.1);
    await _select(t, 2.2);
    expect(requests, [2], reason: '同時只能有一個解碼請求');
    jobs[0].complete(solidPng(255, 0, 0));
    await t.pump();
    expect(requests, [2, 2.2], reason: '略過中間的 2.1，只抽最新開頭');
    expect(_image, findsNothing);
    jobs[1].complete(solidPng(0, 255, 0));
    await t.pump();
    expect(_image, findsOneWidget);
    expect(requests, [2, 2.2], reason: '開頭載好後不抽結尾大圖');
    await _select(t, 2.3);
    final count = requests.length;
    await t.pumpWidget(const SizedBox());
    jobs.last.complete(solidPng(0, 0, 255));
    await t.pump();
    expect(requests, hasLength(count));
    expect(t.takeException(), isNull);
  });

  testWidgets('解碼失敗顯示狀態；大字與小螢幕沒有溢位', (t) async {
    await _open(
      t,
      textScale: 1.5,
      load: (_) async => throw StateError('missing'),
    );
    t.view.physicalSize = const Size(320, 640);
    await t.pump();
    await t.pump();
    expect(find.text('無法預覽'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.ensureVisible(_strip);
    await _select(t, 2.1);
    expect(t.widget<SlipStrip>(_strip).start, closeTo(2.1, 1e-9));
  });

  testWidgets('縮圖與大預覽分開載入，同秒的小圖不冒充大圖', (t) async {
    final previews = <double>[];
    final thumbs = <double>[];
    await _open(
      t,
      load: (s) async {
        previews.add(s);
        return solidPng(255, 0, 0);
      },
      thumbnail: (s) async {
        thumbs.add(s);
        return solidPng(0, 255, 0);
      },
    );
    await t.pump();
    expect(previews, [2]);
    expect(thumbs, isNotEmpty);
    await _select(t, thumbs.first);
    await t.pump();
    expect(previews.last, closeTo(thumbs.first, 0.001));
    expect(_image, findsOneWidget);
    final memory = t.widget<Image>(_image).image as MemoryImage;
    expect(memory.bytes, orderedEquals(solidPng(255, 0, 0)));
    await t.tap(_preview);
    await t.pump();
    expect(find.byType(Dialog), findsNothing, reason: '大預覽不再另開放大視窗');
    expect(t.takeException(), isNull);
  });
}
