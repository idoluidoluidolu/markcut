// 迴歸（實機回報：「草稿沒有顯示縮圖」）：按「保留草稿」離開編輯頁。
//
// 存完草稿，封面才開始在背景畫：原生端抽那一格（背景優先序，排在拖曳
// 抽格後面）多半還在路上，編輯頁就已經 pop、dispose 了。dispose 以前馬上
// releaseNativeFrames——原生端的 release 是 cancelAll，那一格被一起取消，
// 封面落空。抽格器要等封面畫完才放；離開之後背景畫好的封面照樣要落地。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';

import 'draft_cover_harness.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('按「保留草稿」離開：封面那一格回來之前不放抽格器，離開後封面照樣落地', (t) async {
    final native = CoverNative(binding);
    await native.install(t);
    const id = 'leave-cover';
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const SizedBox(),
      ),
    );
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => VideoEditorScreen(draftId: id, draft: native.draft()),
        ),
      ),
    );
    await settle(t);
    expect(find.byType(VideoEditorScreen), findsOneWidget);
    // 從這裡開始，封面那一格扣在原生端（實機：還在解）
    native.holdCover = Completer<void>();
    native.calls.clear();
    unawaited(nav.currentState!.maybePop());
    await settle(t, 5);
    await t.tap(find.text('保留草稿'));
    await settle(t, 25);
    expect(find.byType(VideoEditorScreen), findsNothing, reason: '存完就離開了');
    expect(
      native.calls,
      isNot(contains('release')),
      reason: '封面那一格還沒回來：這時候 release（cancelAll）會把它一起取消',
    );
    native.holdCover!.complete();
    final thumb = await pollUntil(
      t,
      () => DraftStore.thumb(id),
      (v) => v != null,
    );
    expect(thumb, isNotNull, reason: '離開之後背景畫完的封面照樣落地');
    await settle(t, 5);
    expect(native.calls, containsAllInOrder(['cover', 'release']));
    await native.dispose(t);
  });
}
