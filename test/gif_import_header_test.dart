// 匯入 GIF 不只看副檔名，還看檔頭（稽核 #22）：改過名的 PNG 以前照收
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/gif_store.dart';

class _FakePicker extends FilePicker {
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

late Directory _dir;

String _gif(String name) {
  final enc = img.GifEncoder(numColors: 8);
  for (var f = 0; f < 2; f++) {
    final im = img.Image(width: 8, height: 8);
    im.setPixelRgb(f, f, 255, 0, 0);
    enc.addFrame(im, duration: 8);
  }
  final p = '${_dir.path}${Platform.pathSeparator}$name';
  File(p).writeAsBytesSync(enc.finish()!);
  return p;
}

Future<String> _pngNamedGif(String name) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(
    rec,
  ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.red);
  final im = await rec.endRecording().toImage(8, 8);
  final d = await im.toByteData(format: ui.ImageByteFormat.png);
  im.dispose();
  final p = '${_dir.path}${Platform.pathSeparator}$name';
  File(p).writeAsBytesSync(d!.buffer.asUint8List());
  return p;
}

void main() {
  setUpAll(() {
    // 通道處理器讀的是全域的 _dir，每支測試換一個新的它就跟著換
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => _dir.path,
        );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 「我的 GIF」每支測試各自一份：上一支收進去的不能算到下一支頭上
    _dir = Directory.systemTemp.createTempSync('gif_header_');
  });

  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('looksLikeGif：真的 GIF 是、PNG 改名不是、不存在也不是', () async {
    expect(await GifStore.looksLikeGif(_gif('real.gif')), isTrue);
    expect(
      await GifStore.looksLikeGif(await _pngNamedGif('fake.gif')),
      isFalse,
    );
    expect(
      await GifStore.looksLikeGif(
        '${_dir.path}${Platform.pathSeparator}nope.gif',
      ),
      isFalse,
    );
    final short = '${_dir.path}${Platform.pathSeparator}short.gif';
    File(short).writeAsBytesSync(Uint8List.fromList([71, 73, 70]));
    expect(await GifStore.looksLikeGif(short), isFalse);
  });

  test('同一毫秒連收兩份 GIF：兩份都在，不會後面那份蓋掉前面（稽核 #22）', () async {
    final a = _gif('one.gif');
    final b = _gif('two.gif');
    // 中間不等，逼它們落在同一毫秒；就算沒撞上，兩筆本來就該各自成立
    final f = await Future.wait([GifStore.add(a), GifStore.add(b)]);
    expect(f[0], isNotNull);
    expect(f[1], isNotNull);
    expect(f[0], isNot(f[1]), reason: '兩份不能是同一個檔名');
    expect(await GifStore.list(), hasLength(2));
  });

  testWidgets('importGif：副檔名是 .gif 但內容不是：提示、什麼都不收；真的 GIF 收進來', (t) async {
    final picker = _FakePicker();
    FilePicker.platform = picker;
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    String? got;
    List<String>? stored;
    // 畫圖（Picture.toImage）與檔案動作都是真的、由引擎那頭回來：
    // 一定要在 runAsync 裡跑，在假時鐘底下 await 會等到測試逾時
    await t.runAsync(() async {
      picker.next = await _pngNamedGif('fake2.gif');
      got = await importGif(ctx, fromFiles: true);
      stored = await GifStore.list();
    });
    await t.pump();
    expect(got, isNull);
    expect(find.text('這不是 GIF，請選會動的那種'), findsOneWidget);
    expect(stored, isEmpty, reason: '假的不能收進來');
    await t.pump(const Duration(seconds: 4));

    picker.next = _gif('real2.gif');
    await t.runAsync(() async {
      got = await importGif(ctx, fromFiles: true);
      stored = await GifStore.list();
    });
    await t.pump();
    expect(got, isNotNull);
    expect(stored, hasLength(1));
    expect(t.takeException(), isNull);
  });
}
