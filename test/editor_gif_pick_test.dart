// 編輯器裡從相簿挑 GIF（加素材 → GIF、GIF 片段的「換一個」）。
//
// 以前這條直接開 file_picker 的「所有照片」，使用者得在一整片靜態照片
// 裡自己認哪張會動。個人中心「從相簿匯入 GIF」早就改成先問系統相片
// 選取器（markcut/pick 的 gifs，相簿裡只列得出會動的圖），編輯器這條
// 漏了。這支盯四件事：
//   1. 拿到路徑就用它、不再開 file_picker；片段指到「我的 GIF」裡收好
//      的那一份（選取器給的是暫存檔，iOS 下次開選取器就掃掉）
//   2. 在系統選取器按取消：不會再跳一個 file_picker，時間軸不變
//   3. 這台沒有那個選取器（回 null）：退回 file_picker 的 FileType.image；
//      挑到改過名的 PNG 照樣擋下來、什麼都不收
//   4. 「換一個」從相簿挑的也收進「我的 GIF」，片段不會指著暫存檔
//
// 測試主機的 defaultTargetPlatform 是 android；iOS 走的是同一段 Dart，
// 只有原生端的 gifs 各自實作
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/gif_store.dart';

import 'editor_harness.dart';

late Directory _dir;
String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

/// 「我的 GIF」收在這裡（GifStore 的文件目錄換成 [_dir]）
String get _gifDir => _p('gifs');

/// 假的 file_picker：記下被要求開的是哪一種，回 [next]（null＝取消）
class _FakePicker extends FilePicker {
  int calls = 0;
  FileType? lastType;
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

/// 選取器交回來的暫存檔：一個真的會動的小 GIF（兩格），放在「我的
/// GIF」外面。[tint] 讓兩個檔案的內容不一樣
String _pickedGif(String name, {int tint = 0}) {
  final enc = img.GifEncoder(numColors: 8);
  for (var f = 0; f < 2; f++) {
    final im = img.Image(width: 40, height: 24);
    img.fill(im, color: img.ColorRgb8(tint, f * 200, 80));
    enc.addFrame(im, duration: 8);
  }
  final path = _p(name);
  File(path).writeAsBytesSync(enc.finish()!);
  return path;
}

void main() {
  late _FakePicker picker;
  // 系統相片選取器的回覆：null＝這台沒有、空清單＝按了取消
  List<String>? pickReply;
  final pickCalls = <String>[];

  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_editor_gif_pick_');
    GifStore.documentsDirOverride = _dir;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b, tempDir: _dir);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/pick'),
      (call) async {
        pickCalls.add(call.method);
        return call.method == 'gifs' ? pickReply : null;
      },
    );
  });

  tearDownAll(() {
    GifStore.documentsDirOverride = null;
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final d = Directory(_gifDir);
    if (d.existsSync()) d.deleteSync(recursive: true);
    pickReply = null;
    pickCalls.clear();
    picker = _FakePicker();
    FilePicker.platform = picker;
  });

  Future<void> openEditor(WidgetTester t) async {
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(blank: true, thumbnailNow: t.binding.clock.now),
      ),
    );
    await settle(t, 10);
  }

  /// 工具列「加素材」→「GIF」。我的 GIF 是空的，直接進相簿那一步
  Future<void> addGif(WidgetTester t) async {
    await t.tap(find.text('加素材'));
    await settle(t, 10);
    await t.tap(find.text('GIF'));
    await settle(t, 10);
  }

  /// 讓草稿存檔、提示計時器那些收尾跑完，別留計時器
  Future<void> finish(WidgetTester t) async {
    await settle(t, 40);
    await t.pump(const Duration(seconds: 5));
  }

  testWidgets('加素材 → GIF：先問系統相片選取器，挑到就用、不再開 file_picker', (t) async {
    final picked = _pickedGif('picked_a.gif');
    pickReply = [picked];

    await openEditor(t);
    await addGif(t);
    await waitUntil(
      t,
      () => modelOf(t).clips.isNotEmpty,
      reason: 'GIF 沒有加上時間軸',
    );

    expect(pickCalls, ['gifs'], reason: '沒問系統相片選取器（或問錯方法）');
    expect(picker.calls, 0, reason: '已經挑到了還開 file_picker 的「所有照片」');
    final tl = modelOf(t);
    final src = tl.sourceOf(tl.clips.single);
    expect(src.isGif, isTrue);
    expect(
      src.path.startsWith(_gifDir),
      isTrue,
      reason: '片段指著暫存檔（${src.path}），下次開選取器就被掃掉',
    );
    expect(File(src.path).readAsBytesSync(), File(picked).readAsBytesSync());
    expect(await GifStore.list(), [src.path], reason: '只收一份，加片段時不該再收第二份');
    await finish(t);
  });

  testWidgets('在系統選取器按取消：不會再跳 file_picker，時間軸不變', (t) async {
    pickReply = const [];

    await openEditor(t);
    await addGif(t);
    await settle(t, 20);

    expect(pickCalls, ['gifs']);
    expect(picker.calls, 0, reason: '取消之後又跳了 file_picker');
    expect(modelOf(t).clips, isEmpty);
    expect(await GifStore.list(), isEmpty);
    await finish(t);
  });

  testWidgets('這台沒有系統選取器：退回 file_picker 的「所有照片」；改過名的 PNG 照樣擋下', (t) async {
    pickReply = null;
    final renamed = _p('renamed.gif');
    final png = img.encodePng(img.Image(width: 8, height: 8));
    File(renamed).writeAsBytesSync(png);
    picker.next = renamed;

    await openEditor(t);
    await addGif(t);
    await settle(t, 20);

    expect(picker.calls, 1, reason: '這台沒有系統選取器，要退回 file_picker');
    expect(picker.lastType, FileType.image);
    expect(find.text('這不是 GIF，請選會動的那種'), findsOneWidget);
    expect(modelOf(t).clips, isEmpty);
    expect(await GifStore.list(), isEmpty, reason: '不是 GIF 也被收進「我的 GIF」');
    // showHint 的計時器要跑完
    await t.pump(const Duration(seconds: 3));
    await finish(t);
  });

  testWidgets('「換一個」從相簿挑：一樣收進我的 GIF，片段不會指著暫存檔', (t) async {
    pickReply = [_pickedGif('picked_a.gif')];
    await openEditor(t);
    await addGif(t);
    await waitUntil(t, () => modelOf(t).clips.isNotEmpty);
    final id = modelOf(t).clips.single.id;
    final before = modelOf(t).sourceOf(modelOf(t).clips.single).path;

    // 選取中的片段再點一下＝調整視窗（GIF 的才有「換一個」）。剛加進來
    // 就是選取中的；沒開起來就再點一次
    await t.tapAt(t.getCenter(clipBlock(id)));
    await settle(t, 10);
    if (find.text('換一個').evaluate().isEmpty) {
      await t.tapAt(t.getCenter(clipBlock(id)));
      await settle(t, 10);
    }
    expect(find.text('換一個'), findsOneWidget, reason: 'GIF 的調整視窗要有「換一個」');

    final second = _pickedGif('picked_b.gif', tint: 220);
    pickReply = [second];
    await t.tap(find.text('換一個'));
    await settle(t, 10);
    // 我的 GIF 已經有剛才那一個：先出「我的 GIF」面板，相簿在右上角
    await t.tap(find.text('從相簿選'));
    await waitUntil(
      t,
      () => modelOf(t).sourceOf(modelOf(t).clips.single).path != before,
      reason: '換一個沒有換成',
    );

    final after = modelOf(t).sourceOf(modelOf(t).clips.single).path;
    expect(
      after.startsWith(_gifDir),
      isTrue,
      reason: '換上的指著暫存檔（$after），下次開選取器就被掃掉',
    );
    expect(File(after).readAsBytesSync(), File(second).readAsBytesSync());
    expect(pickCalls, ['gifs', 'gifs'], reason: '換一個也要先問系統相片選取器');
    expect(picker.calls, 0);
    expect(await GifStore.list(), hasLength(2));
    await finish(t);
  });
}
