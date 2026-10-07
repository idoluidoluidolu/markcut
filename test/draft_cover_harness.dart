// 草稿封面迴歸測試（draft_cover_*_test）的共用件：假的原生端、一份一支
// 影片的草稿、真時間輪詢。
//
// 一個檔只放一支會寫草稿的編輯頁測試：DraftStore 的存檔佇列是靜態的
// Future，編輯頁在某一支測試的假時間裡存過檔，佇列尾巴就屬於那個 zone——
// 下一支測試接在它後面的存檔永遠排不到（那個 zone 已經沒人推了）。
// 每個測試檔各自一個 isolate，就沒有這個問題。
//
// 檔名不帶 _test：不是測試，flutter test 不會跑它
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/video_engine.dart' as engine;

import 'editor_harness.dart';

/// 測試的原生端：合成播放器在（存完草稿緊接著的 _compRefreshIfChanged
/// 會跑，跟實機預設一樣）、抽格回一張圖（[frames] 為 false 時一格都
/// 抽不到）。草稿封面那一格（maxH 720）可以用 [holdCover] 扣住，看抽格器
/// 是不是在它回來之前就被放掉
class CoverNative {
  CoverNative(this.binding, {this.frames = true});

  final TestWidgetsFlutterBinding binding;
  final bool frames;
  final frame = solidPng(200, 40, 40, size: 32);

  /// 依序記下：cover（封面那一格回來了）、release（抽格器被放掉）
  final calls = <String>[];
  Completer<void>? holdCover;

  late Directory root;
  late File source;

  Future<void> install(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    Diag.reset();
    Diag.playerLayer.value = false;
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('draft-cover-');
      source = await File('${root.path}/source.mov').writeAsBytes([1, 2, 3]);
    });
    mockEditorPlugins(binding, tempDir: root);
    for (final name in ['markcut/comp', 'markcut/prep', 'markcut/frames']) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async {
          if (call.method == 'available') return name == 'markcut/comp';
          if (call.method == 'build') {
            return {
              'textureId': 1,
              'duration': 2.0,
              'width': 320.0,
              'height': 240.0,
              'ci': false,
            };
          }
          if (name != 'markcut/frames') return null;
          if (call.method == 'release') {
            calls.add('release');
            return null;
          }
          if (call.method != 'frameAt') return null;
          if ((call.arguments as Map)['maxH'] == 720) {
            final hold = holdCover;
            if (hold != null) await hold.future;
            calls.add('cover');
          }
          return frames ? frame : null;
        },
      );
    }
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  /// 一支影片（320×240、2 秒）從 0 秒開始的草稿內容
  Map<String, dynamic> draft() => {
    'sources': [
      MediaSource(
        path: source.path,
        name: 'v',
        kind: ClipKind.video,
        duration: 2,
        w: 320,
        h: 240,
      ).toJson(),
    ],
    'clips': [
      TimelineClip(
        id: 1,
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 2,
        offset: 0,
        track: 0,
      ).toJson(),
    ],
  };

  /// 離開編輯頁後的補存與背景封面都讓它在這支測試的假時間裡跑完
  Future<void> dispose(WidgetTester t) async {
    final hold = holdCover;
    if (hold != null && !hold.isCompleted) hold.complete();
    holdCover = null;
    await t.pumpWidget(const SizedBox());
    await settle(t, 80);
    await t.runAsync(() => root.delete(recursive: true));
  }
}

/// 真時間一輪一輪等，直到 [done]（最多 [rounds] 輪）
Future<T?> pollUntil<T>(
  WidgetTester t,
  Future<T?> Function() read,
  bool Function(T?) done, {
  int rounds = 100,
}) async {
  T? v;
  for (var i = 0; i < rounds; i++) {
    await settle(t, 3);
    await t.runAsync(() async => v = await read());
    if (done(v)) break;
  }
  return v;
}

/// 索引裡這一份的那一筆
Future<DraftMeta?> draftMetaOf(WidgetTester t, String id) async {
  DraftMeta? m;
  await t.runAsync(() async {
    m = (await DraftStore.list()).where((e) => e.id == id).firstOrNull;
  });
  return m;
}

/// 編輯頁推在一個首頁上面（實機是從首頁／個人中心推進來的）：返回鍵與
/// 「回主畫面」的 popUntil((r) => r.isFirst) 才有地方回去
Future<GlobalKey<NavigatorState>> pushEditor(
  WidgetTester t,
  Widget editor,
) async {
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      theme: ThemeData(splashFactory: InkRipple.splashFactory),
      home: const SizedBox(),
    ),
  );
  unawaited(
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => editor)),
  );
  await settle(t);
  return nav;
}

/// 匯出一次而且成功：切到匯出分頁按「匯出」，整趟匯出（編碼＋存相簿）
/// 由 debugExportOverride 直接回成功，等到「匯出完成」問下一步為止
Future<void> exportSucceeds(WidgetTester t) async {
  engine.debugExportOverride = (_) async =>
      (ok: true, message: '已存到「浮水印」相簿', cancelled: false);
  addTearDown(() => engine.debugExportOverride = null);
  await t.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text('匯出')),
  );
  await settle(t, 10);
  await t.tap(
    find.ancestor(
      of: find.text('匯出'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ),
  );
  await waitUntil(
    t,
    () => find.text('匯出完成').evaluate().isNotEmpty,
    reason: '匯出成功要問下一步',
  );
}
