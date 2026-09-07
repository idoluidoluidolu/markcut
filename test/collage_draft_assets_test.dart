// 拼圖草稿的素材複本（稽核 #5、#20）：保留草稿時照片複製進 App 自己的
// 目錄、草稿記複本；離開時把選取器的複本清掉；草稿記的路徑不見了
// 但留過複本，續作照樣找得回（個人頁不用改，拼圖頁自己會找）
import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/draft_assets.dart';

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

Future<void> _settle(WidgetTester t, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _waitLoaded(WidgetTester t) async {
  for (
    var i = 0;
    i < 50 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
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
  await _waitLoaded(t);
}

Future<void> _back(WidgetTester t) async {
  unawaited(t.state<NavigatorState>(find.byType(Navigator)).maybePop());
  await t.pumpAndSettle();
}

/// 等到 [ready]。dispose 裡的清理是射後不理的真 I/O，一輪只推得動一步
///（複製、列目錄、刪檔各算一步），固定圈數等於在賭機器快不快
Future<void> _waitFor(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 80 && !ready(); i++) {
    await _settle(t, rounds: 1);
  }
}

bool _allGone(Iterable<String> paths) =>
    paths.every((p) => !File(p).existsSync());

final _sep = Platform.pathSeparator;
late Directory _root;
late Directory _picker;
late Directory _support;

String _own() =>
    '${_support.path}${_sep}draft_assets$_sep${DraftAssets.collage}$_sep';

Future<List<String>> _picked(WidgetTester t, int n) async {
  final out = <String>[];
  await t.runAsync(() async {
    for (var i = 0; i < n; i++) {
      final p = '${_picker.path}${_sep}image_$i.png';
      File(p).writeAsBytesSync(
        await _png(Color(0xFF203040 + i * 0x102030), 60 + i * 20, 40),
      );
      out.add(p);
    }
  });
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _root = Directory.systemTemp.createTempSync('collage_assets_');
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
      kCollageDraftKey,
    );
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  testWidgets('保留草稿：照片複製進 App 自己的目錄、草稿記複本；離開後選取器的複本清掉；續作兩張都在', (t) async {
    final paths = await _picked(t, 2);
    await _pumpFromHome(
      t,
      CollageScreen(photos: [for (final p in paths) XFile(p)]),
    );
    await _back(t);
    expect(find.text('這份拼圖還沒完成'), findsOneWidget);
    await t.tap(find.text('保留草稿'));
    // 存草稿要複製檔案（真 I/O）才會 pop；dispose 裡的清理也是射後不理的真 I/O
    await _settle(t, rounds: 12);
    await t.pumpAndSettle();
    await _settle(t);
    expect(find.text('首頁'), findsOneWidget);

    final d = (await draft())!;
    final photos = (d['photos'] as List).cast<String>();
    expect(photos.length, 2);
    for (final p in photos) {
      expect(p.startsWith(_own()), isTrue, reason: '草稿要記複本：$p');
      expect(File(p).existsSync(), isTrue);
    }
    await _waitFor(t, () => _allGone(paths));
    for (final p in paths) {
      expect(File(p).existsSync(), isFalse, reason: '選取器的複本離開時要清掉：$p');
    }
    for (final p in photos) {
      expect(File(p).existsSync(), isTrue, reason: '草稿在用的複本不能被清理掃掉');
    }

    // 續作：兩張都回來、沒有「已不在」
    await t.pumpWidget(const SizedBox());
    await _pumpFromHome(t, CollageScreen(restore: d));
    expect(find.textContaining('已不在'), findsNothing);
    expect(find.byIcon(Icons.add), findsNWidgets(2), reason: '兩張照片都回來、沒有空格');
    // 沒動就離開：問是照舊（拼圖頁有照片就問），選「繼續編輯」不影響檔案
    await _back(t);
    await t.tap(find.text('繼續編輯'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('草稿記的是已經不在的原路徑、但留過複本：續作找得回；捨棄＝複本一起走', (t) async {
    final paths = await _picked(t, 2);
    late List<String> copies;
    await t.runAsync(() async {
      copies = [
        for (final p in paths)
          (await DraftAssets.secure(DraftAssets.collage, p))!,
      ];
      for (final p in paths) {
        File(p).deleteSync(); // 系統清了 tmp
      }
    });
    final d = <String, dynamic>{
      'photos': paths, // 舊版草稿：記的是選取器的路徑
      'order': [0, 1],
      'cols': 2,
      'rows': 1,
      'free': false,
      'aspect': 1.0,
    };
    SharedPreferences.setMockInitialValues({kCollageDraftKey: jsonEncode(d)});
    await _pumpFromHome(t, CollageScreen(restore: d));
    expect(find.textContaining('已不在'), findsNothing, reason: '複本還在就找得回');
    expect(find.byIcon(Icons.add), findsNWidgets(2), reason: '兩格都有照片');

    // 捨棄：草稿沒了、複本也清掉
    await _back(t);
    await t.tap(find.text('捨棄'));
    await t.pumpAndSettle();
    expect(find.text('首頁'), findsOneWidget);
    await _settle(t);
    expect(await draft(), isNull);
    await _waitFor(t, () => _allGone(copies));
    for (final c in copies) {
      expect(File(c).existsSync(), isFalse, reason: '草稿捨棄了，複本也該走：$c');
    }
    expect(t.takeException(), isNull);
  });
}
