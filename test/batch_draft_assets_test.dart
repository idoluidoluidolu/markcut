// 批次草稿的素材複本（稽核 #5、#20）：保留草稿時照片複製進 App 自己的
// 目錄、草稿記複本；離開時把選取器的複本清掉（草稿還在用的除外）；
// 草稿記的路徑不見了但留過複本，續作照樣找得回
import 'dart:async' show Completer, unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 模擬既有 shared_preferences 平台寫入失敗，不增加產品依賴。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/services/draft_assets.dart';

class _FailingBatchPreferences extends InMemorySharedPreferencesStore {
  _FailingBatchPreferences(super.data, this.throwOnFailure) : super.withData();

  final bool throwOnFailure;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$kBatchDraftKey') {
      if (throwOnFailure) throw StateError('disk full');
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _DelayedBatchPreferences extends InMemorySharedPreferencesStore {
  _DelayedBatchPreferences() : super.withData({});

  final release = Completer<void>();
  bool writeStarted = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$kBatchDraftKey') {
      writeStarted = true;
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<Uint8List> _png(Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

Future<void> _settle(WidgetTester t, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 等到 [ready]。dispose 裡的清理是射後不理的真 I/O，一輪只推得動一步
///（複製、列目錄、刪檔各算一步），固定圈數等於在賭機器快不快
Future<void> _waitFor(
  WidgetTester t,
  bool Function() ready, {
  String reason = '非同步檔案作業未在限時內完成',
}) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < const Duration(seconds: 8)) {
    await _settle(t, rounds: 1);
  }
  expect(ready(), isTrue, reason: reason);
}

Future<void> _waitForHome(WidgetTester t) => _waitFor(
  t,
  () =>
      find.byType(BatchWatermarkScreen).evaluate().isEmpty &&
      find.text('首頁').evaluate().length == 1,
  reason: '素材複製與草稿寫入完成後，編輯頁應返回首頁',
);

bool _allGone(Iterable<String> paths) =>
    paths.every((p) => !File(p).existsSync());

final _sep = Platform.pathSeparator;
late Directory _root;
late Directory _picker;
late Directory _support;

String _own() =>
    '${_support.path}${_sep}draft_assets$_sep${DraftAssets.batch}$_sep';

/// 「相簿選取器交出來的複本」：放在選取器目錄底下
Future<List<String>> _picked(WidgetTester t, int n) async {
  final out = <String>[];
  await t.runAsync(() async {
    for (var i = 0; i < n; i++) {
      final p = '${_picker.path}${_sep}image_$i.png';
      File(
        p,
      ).writeAsBytesSync(await _png(Color(0xFF203040 + i * 0x102030), 120, 90));
      out.add(p);
    }
  });
  return out;
}

Future<void> _pumpFromHome(WidgetTester t, Widget screen) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.push(ctx, editRoute(builder: (_) => screen)),
              child: const Text('首頁'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('首頁'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _settle(t);
}

Future<void> _back(WidgetTester t) async {
  unawaited(t.state<NavigatorState>(find.byType(Navigator)).maybePop());
  await t.pumpAndSettle();
}

/// 把畫布比例改掉＝動過了（離開會問）。右上角那顆膠囊顯示目前的比例：
/// 續作的草稿可能已經是 1:1，就改成 16:9
Future<void> _touch(WidgetTester t) async {
  final original = find.text('原始').evaluate().isNotEmpty;
  await t.tap(original ? find.text('原始') : find.text('1:1'));
  await t.pumpAndSettle();
  await t.tap(find.text(original ? '1:1' : '16:9'));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _root = Directory.systemTemp.createTempSync('batch_assets_');
    _picker = Directory('${_root.path}${_sep}picker')..createSync();
    _support = Directory('${_root.path}${_sep}support')..createSync();
    DraftAssets.supportDirOverride = _support;
    DraftAssets.pickerRootsOverride = [_picker];
  });

  tearDown(() {
    DraftAssets.supportDirOverride = null;
    DraftAssets.pickerRootsOverride = null;
    try {
      _root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, dynamic>?> draft() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      kBatchDraftKey,
    );
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  for (final throwsError in [false, true]) {
    testWidgets('草稿寫入${throwsError ? '拋例外' : '回 false'}：留在編輯頁、舊草稿及素材不被清掉', (
      t,
    ) async {
      final paths = await _picked(t, 1);
      final oldPhoto = File('${_own()}previous.png');
      oldPhoto.parent.createSync(recursive: true);
      oldPhoto.writeAsBytesSync(File(paths.first).readAsBytesSync());
      final oldDraft = jsonEncode({
        'files': [oldPhoto.path],
      });
      final previousStore = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _FailingBatchPreferences({
        'flutter.$kBatchDraftKey': oldDraft,
      }, throwsError);
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previousStore;
        SharedPreferences.resetStatic();
      });

      await _pumpFromHome(t, BatchWatermarkScreen(files: [XFile(paths.first)]));
      await _touch(t);
      await _back(t);
      await t.tap(find.text('保留草稿'));
      await _settle(t, rounds: 12);
      expect(find.byType(BatchWatermarkScreen), findsOneWidget);
      expect(find.text('草稿保存失敗，請確認儲存空間後再試一次'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kBatchDraftKey), oldDraft, reason: '不能留下假成功的快取');

      await t.pump(const Duration(seconds: 3));
      await t.pumpWidget(const SizedBox());
      await _settle(t, rounds: 12);
      expect(oldPhoto.existsSync(), isTrue, reason: '失敗不能更新清理引用並刪到舊素材');
      expect((await draft())!['files'], [oldPhoto.path]);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('保留草稿等待真正寫入：尚未完成不能離頁，完成後才返回首頁並清理選取器複本', (t) async {
    final paths = await _picked(t, 2);
    final previousStore = SharedPreferencesStorePlatform.instance;
    final delayed = _DelayedBatchPreferences();
    SharedPreferencesStorePlatform.instance = delayed;
    addTearDown(() {
      if (!delayed.release.isCompleted) delayed.release.complete();
      SharedPreferencesStorePlatform.instance = previousStore;
      SharedPreferences.resetStatic();
    });

    await _pumpFromHome(
      t,
      BatchWatermarkScreen(files: [for (final path in paths) XFile(path)]),
    );
    await _touch(t);
    await _back(t);
    await t.tap(find.text('保留草稿'));
    await _waitFor(t, () => delayed.writeStarted, reason: '素材應先留好複本，才送草稿寫入');
    // Deliberately hold completion beyond the old fixed wait. The UI must
    // remain here until the actual commit, regardless of animation settling.
    await _settle(t, rounds: 20);
    await t.pumpAndSettle();
    expect(find.byType(BatchWatermarkScreen), findsOneWidget);
    expect(find.text('首頁'), findsNothing);
    expect(paths.every((path) => File(path).existsSync()), isTrue);

    delayed.release.complete();
    await _waitForHome(t);
    final saved = (await draft())!;
    final files = (saved['files'] as List).cast<String>();
    expect(files.length, 2);
    expect(files.every((path) => path.startsWith(_own())), isTrue);
    expect(files.every((path) => File(path).existsSync()), isTrue);
    await _waitFor(t, () => _allGone(paths));
    expect(t.takeException(), isNull);
  });

  testWidgets('保留草稿：檔案複製進 App 自己的目錄、草稿記複本、覆寫以複本路徑當鍵；離開後選取器的複本清掉', (t) async {
    final paths = await _picked(t, 2);
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(files: [for (final p in paths) XFile(p)]),
    );
    await _touch(t);
    await _back(t);
    expect(find.text('這批還沒匯出'), findsOneWidget);
    await t.tap(find.text('保留草稿'));
    // pumpAndSettle only drains scheduled frames, not file copy futures. Wait
    // for the actual route transition; full-suite I/O may take over 720 ms.
    await _waitForHome(t);
    expect(find.text('首頁'), findsOneWidget);

    final d = (await draft())!;
    final files = (d['files'] as List).cast<String>();
    expect(files.length, 2);
    for (final f in files) {
      expect(f.startsWith(_own()), isTrue, reason: '草稿要記複本：$f');
      expect(File(f).existsSync(), isTrue);
    }
    expect(files[0].endsWith('${_sep}image_0.png'), isTrue, reason: '檔名要留著');
    await _waitFor(t, () => _allGone(paths));
    for (final p in paths) {
      expect(File(p).existsSync(), isFalse, reason: '選取器的複本離開時要清掉：$p');
    }
    for (final f in files) {
      expect(File(f).existsSync(), isTrue, reason: '草稿在用的複本不能被清理掃掉');
    }
  });

  testWidgets('續作沒動就離開：草稿與它引用的檔案原封不動；捨棄＝草稿跟複本一起走', (t) async {
    final paths = await _picked(t, 2);
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(files: [for (final p in paths) XFile(p)]),
    );
    await _touch(t);
    await _back(t);
    await t.tap(find.text('保留草稿'));
    await _waitForHome(t);
    expect(find.text('首頁'), findsOneWidget);
    final d = (await draft())!;
    final copies = (d['files'] as List).cast<String>();

    // 個人頁續作（複本還在）：沒動就返回
    await t.pumpWidget(const SizedBox()); // 拆掉再重來：這一頁要以草稿續作
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(
        files: [for (final p in copies) XFile(p)],
        restore: batchRestoreFor(d, copies),
      ),
    );
    await _back(t);
    expect(find.text('這批還沒匯出'), findsNothing);
    expect(find.text('首頁'), findsOneWidget);
    await _settle(t, rounds: 6);
    for (final c in copies) {
      expect(File(c).existsSync(), isTrue, reason: '沒動草稿：它的檔案要留著');
    }
    expect(await draft(), isNotNull);

    // 再進去、動一下、捨棄
    await t.pumpWidget(const SizedBox());
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(
        files: [for (final p in copies) XFile(p)],
        restore: batchRestoreFor(d, copies),
      ),
    );
    await _touch(t);
    await _back(t);
    await t.tap(find.text('捨棄'));
    await t.pumpAndSettle();
    expect(find.text('首頁'), findsOneWidget);
    await _settle(t, rounds: 6);
    expect(await draft(), isNull);
    await _waitFor(t, () => _allGone(copies));
    for (final c in copies) {
      expect(File(c).existsSync(), isFalse, reason: '草稿捨棄了，複本也該走');
    }
  });

  testWidgets('草稿記的路徑不見了但留過複本：個人頁那條路（DraftAssets.resolve）找得回', (t) async {
    final paths = await _picked(t, 2);
    // 舊版草稿記的是選取器的路徑；先留好複本、再把原檔清掉（系統清 tmp）
    // 全是真 I/O：要在 runAsync 裡跑，不然假時鐘等不到它
    await t.runAsync(() async {
      final c0 = (await DraftAssets.secure(DraftAssets.batch, paths[0]))!;
      File(paths[0]).deleteSync();
      expect(await DraftAssets.resolve(DraftAssets.batch, paths[0]), c0);
      expect(await DraftAssets.resolve(DraftAssets.batch, paths[1]), paths[1]);
      expect(
        await DraftAssets.resolve(
          DraftAssets.batch,
          '${_picker.path}${_sep}gone.png',
        ),
        isNull,
      );
    });
  });

  test('path_provider 不在（測試環境）：secure 回 null，呼叫端照記原路徑，不炸', () async {
    DraftAssets.supportDirOverride = null;
    // 沒有 mock 的通道會丟 MissingPluginException：要吞掉
    expect(
      await DraftAssets.secure(
        DraftAssets.batch,
        '${_picker.path}${_sep}x.png',
      ),
      isNull,
    );
    expect(await DraftAssets.retain(DraftAssets.batch, {}), 0);
  });

  test('選取器目錄＝暫存目錄＋Documents/picked_images（後者是舊版殘檔）', () async {
    DraftAssets.pickerRootsOverride = null;
    final docs = Directory('${_root.path}${_sep}docs')..createSync();
    final tmp = Directory('${_root.path}${_sep}tmp')..createSync();
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getTemporaryDirectory' => tmp.path,
        'getApplicationDocumentsDirectory' => docs.path,
        _ => _support.path,
      },
    );
    addTearDown(
      () => b.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
    final inTmp = File('${tmp.path}${_sep}a.png')..writeAsStringSync('x');
    final pickedDir = Directory('${docs.path}${_sep}picked_images')
      ..createSync();
    final inPicked = File('${pickedDir.path}${_sep}image_x.heic')
      ..writeAsStringSync('x');
    final inDocs = File('${docs.path}${_sep}mine.png')..writeAsStringSync('x');
    final n = await DraftAssets.discardPickerCopies([
      inTmp.path,
      inPicked.path,
      inDocs.path,
    ], keep: {});
    expect(n, 2);
    expect(inTmp.existsSync(), isFalse);
    expect(
      inPicked.existsSync(),
      isFalse,
      reason:
          '舊版 file_picker 的複本留在 Documents/picked_images，'
          '清理時還是要掃得到（現在的 fork 已改寫進 tmp）',
    );
    expect(inDocs.existsSync(), isTrue, reason: 'Documents 其他地方的檔案不碰');
  });
}
