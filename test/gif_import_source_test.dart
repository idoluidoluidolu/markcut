// 「我的 GIF」總覽頁的 ＋：弄一個 GIF 進來（見 addGifFromDevice）。
//
// ＋ 有三條路：現做一個，或從相簿／檔案收一個現成的。後兩條在裝置上
// 是兩個看不到彼此的選取器（iOS 的 PHPicker 沒有檔案 App 那一區，
// UIDocumentPickerViewController 也列不出相簿），所以 ＋ 會先問一次。
// 這支盯的是五件事：
//   1. 三列都在，順序是「製作 GIF／從相簿選／從檔案選」
//   2. 「製作 GIF」開的是影片選取器（不是挑 GIF 的那一個），挑完走
//      editRoute 進 GIF 製作頁——跟首頁的「GIF」那顆同一條
//   3. 兩條匯入路各自開的是對的選取器（型別／副檔名過濾）
//   4. 挑到不是 GIF 的東西：照樣是那句提示，而且什麼都不會被收進來
//   5. 挑到真的 GIF：檔案會落進 GifStore
//
// FilePicker.platform 是可以換掉的平台實例，這裡換成假的——不然
// 測試會去戳真的原生選取器
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/gif_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/gif_store.dart';
import 'package:markcut/theme.dart';

late Directory _docs;
late String _gifDir;

/// 假的選取器：記下這次被要求開的是哪一種，回傳 [next] 這個檔案
/// （null＝使用者按了取消）
class _FakePicker extends FilePicker {
  FileType? lastType;
  List<String>? lastExtensions;

  /// 製作 GIF 那條走的是多選的影片選取器（見 pickVideoFiles）
  bool? lastMultiple;
  int calls = 0;
  String? next;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    lastType = type;
    lastExtensions = allowedExtensions;
    lastMultiple = allowMultiple;
    final p = next;
    if (p == null) return null;
    return FilePickerResult([
      PlatformFile(
        path: p,
        name: p.split(Platform.pathSeparator).last,
        size: File(p).lengthSync(),
      ),
    ]);
  }
}

late _FakePicker _picker;

/// 一個真的會動的小 GIF（兩格）。假檔案也走得完流程，但真的檔案
/// 連總覽頁量比例那一段也一起走過
String _writeGif(String name) {
  final enc = img.GifEncoder(numColors: 8);
  for (var f = 0; f < 2; f++) {
    final im = img.Image(width: 40, height: 40);
    for (var y = 0; y < 40; y++) {
      for (var x = 0; x < 40; x++) {
        im.setPixelRgb(x, y, x * 6, y * 6, f * 200);
      }
    }
    enc.addFrame(im, duration: 8);
  }
  final path = '${_docs.path}${Platform.pathSeparator}$name';
  File(path).writeAsBytesSync(enc.finish()!);
  return path;
}

/// 這一頁的檔案動作是真的 I/O（複製檔案、量比例），fake async 的
/// pump 推不動它——要 runAsync 讓它真的跑，再 pump 把畫面追上去
Future<void> _settle(WidgetTester t, [int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 記下被推出去的頁：「製作 GIF」那條要進 GIF 製作頁
class _RouteSpy extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Future<void> _pump(WidgetTester t, [NavigatorObserver? spy]) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      navigatorObservers: [?spy],
      home: const LightPage(child: GifsScreen()),
    ),
  );
  await _settle(t);
}

/// 按 ＋，等來源選單出現
Future<void> _tapAdd(WidgetTester t) async {
  await t.tap(find.byType(FloatingActionButton));
  await _settle(t, 10);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(390 * 3, 844 * 3);
    v.devicePixelRatio = 3.0;
    _docs = Directory.systemTemp.createTempSync('markcut_gif_import');
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _docs.path,
    );
    _gifDir = '${_docs.path}${Platform.pathSeparator}gifs';
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final d = Directory(_gifDir);
    if (d.existsSync()) d.deleteSync(recursive: true);
    d.createSync(recursive: true);
    _picker = _FakePicker();
    FilePicker.platform = _picker;
  });

  testWidgets('＋ 有三列，順序是製作／相簿／檔案', (t) async {
    await _pump(t);
    await _tapAdd(t);

    const rows = ['製作 GIF', '從相簿選', '從檔案選'];
    for (final r in rows) {
      expect(find.text(r), findsOneWidget, reason: '選單少了「$r」');
    }
    // 「製作 GIF」擺第一列（使用者指定）：由上而下量位置，
    // 不是只確認三列都在
    final ys = [for (final r in rows) t.getCenter(find.text(r)).dy];
    expect(
      ys[0] < ys[1] && ys[1] < ys[2],
      isTrue,
      reason: '順序不對（由上而下量到 $ys）',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('製作 GIF：開影片選取器，然後走 editRoute 進 GIF 製作頁', (t) async {
    // 挑到的要是「看得出是影片」的檔名——首頁那條也是照副檔名認的
    final mp4 = '${_docs.path}${Platform.pathSeparator}clip.mp4';
    File(mp4).writeAsBytesSync(List<int>.filled(64, 0));
    _picker.next = mp4;

    final spy = _RouteSpy();
    await _pump(t, spy);
    await _tapAdd(t);
    await t.tap(find.text('製作 GIF'));
    await _settle(t, 20);

    // 開的是影片選取器（pickVideoFiles）：不是相簿匯入的
    // FileType.image，也不是檔案匯入的 FileType.custom + gif
    expect(_picker.calls, 1);
    expect(_picker.lastType, FileType.video);
    expect(_picker.lastExtensions, isNull);
    expect(_picker.lastMultiple, isTrue);

    // 進的是 GIF 製作頁，而且是編輯頁路由（不收右滑返回）
    final pushed = spy.pushed.whereType<EditPageRoute<dynamic>>().toList();
    expect(pushed, hasLength(1), reason: '沒有推出 GIF 製作頁');
    final page = pushed.first.builder(t.element(find.byType(MaterialApp)));
    expect(page, isA<GifScreen>());
    // 路徑與檔名照挑到的那一支帶過去
    expect((page as GifScreen).path, mp4);
    expect(page.name, 'clip.mp4');

    // 什麼都沒收進「我的 GIF」：GIF 是製作頁匯出時才存的
    expect(await GifStore.list(), isEmpty);

    // 測試環境沒有播放器外掛，製作頁開不了片會自己提示＋退回來，
    // 那句提示的 2.4 秒計時器要跑完
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('匯入兩條路：相簿走相簿選取器、檔案走文件選取器', (t) async {
    await _pump(t);
    await _tapAdd(t);

    // 兩條路都在
    expect(find.text('從相簿選'), findsOneWidget);
    expect(find.text('從檔案選'), findsOneWidget);

    // 相簿：FileType.image（iOS 的 PHPicker／Android 的 ACTION_PICK）。
    // 這條路不能帶副檔名清單，帶了 file_picker 會丟 ArgumentError
    await t.tap(find.text('從相簿選'));
    await _settle(t, 10);
    expect(_picker.calls, 1);
    expect(_picker.lastType, FileType.image);
    expect(_picker.lastExtensions, isNull);

    // 檔案：FileType.custom + gif（iOS 轉成 com.compuserve.gif 這個
    // UTI 丟給 UIDocumentPickerViewController，Android 是
    // ACTION_OPEN_DOCUMENT 的 image/gif），清單裡只會出現 GIF
    await _tapAdd(t);
    await t.tap(find.text('從檔案選'));
    await _settle(t, 10);
    expect(_picker.calls, 2);
    expect(_picker.lastType, FileType.custom);
    expect(_picker.lastExtensions, ['gif']);

    expect(t.takeException(), isNull);
  });

  testWidgets('選單本身可以取消：不開選取器、也不收東西', (t) async {
    await _pump(t);
    await _tapAdd(t);
    // 點選單外面關掉
    await t.tapAt(const Offset(195, 60));
    await _settle(t, 10);

    expect(find.text('從相簿選'), findsNothing);
    expect(_picker.calls, 0);
    expect(Directory(_gifDir).listSync(), isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('挑到不是 GIF 的：照樣提示，什麼都不收', (t) async {
    final png = '${_docs.path}${Platform.pathSeparator}not_a.png';
    File(png).writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
    _picker.next = png;

    await _pump(t);
    await _tapAdd(t);
    await t.tap(find.text('從檔案選'));
    await _settle(t, 20);

    expect(find.text('這不是 GIF，請選會動的那種'), findsOneWidget);
    expect(Directory(_gifDir).listSync(), isEmpty);
    expect(await GifStore.list(), isEmpty);

    // showHint 的 2.4 秒計時器要跑完，不然測試框架會抱怨還有 timer
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('從檔案挑到真的 GIF：收進 GifStore，總覽頁跟著多一格', (t) async {
    _picker.next = _writeGif('from_files.gif');

    await _pump(t);
    // 空狀態那段話要講得出「檔案」這條路，不然只有相簿的人不知道；
    // 也要指向這一頁的＋（＋ 現在自己就能做 GIF）
    expect(find.textContaining('相簿、檔案裡現成的 GIF'), findsOneWidget);
    expect(find.textContaining('按右下角的＋做一個'), findsOneWidget);

    await _tapAdd(t);
    await t.tap(find.text('從檔案選'));
    await _settle(t, 40);

    final saved = await GifStore.list();
    expect(saved, hasLength(1), reason: '檔案挑出來的 GIF 沒有收進「我的 GIF」');
    expect(saved.first.toLowerCase().endsWith('.gif'), isTrue);
    // 收的是複本不是原檔：原檔在暫存區，系統隨時會清掉
    expect(saved.first, isNot(_picker.next));
    expect(File(saved.first).lengthSync(), File(_picker.next!).lengthSync());

    // 總覽頁重讀了，空狀態換成瀑布流
    expect(find.textContaining('還沒有 GIF'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('從相簿挑到真的 GIF：一樣收得進來', (t) async {
    _picker.next = _writeGif('from_gallery.gif');

    await _pump(t);
    await _tapAdd(t);
    await t.tap(find.text('從相簿選'));
    await _settle(t, 40);

    expect(_picker.lastType, FileType.image);
    expect(await GifStore.list(), hasLength(1));
    expect(t.takeException(), isNull);
  });
}
