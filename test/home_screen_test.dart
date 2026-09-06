// 首頁：整片留給 logo，功能全收在底部那顆「＋ 開始」（使用者指定
// 「首頁整個下方收掉，改成＋號叫出選單」，樣式挑了滿版膠囊）。
//
// 守的是：
//   1. 首頁本體只有 logo、右上角個人中心、底部那顆「＋ 開始」——沒有
//      任何入口文字（舊的四個方塊、更舊的「加入浮水印」「製作浮水印」
//      都不在）
//   2. ＋叫出來的第一層：四列 浮水印／照片拼圖／GIF／剪輯，順序、文案、
//      一行說明、圖示；右邊不畫箭頭（使用者指定）
//   3. 每一列走的路：
//        浮水印   → 第二層「照片／影片」→ 對應的選取器 → 多個問
//                   「接成一支／串成影片還是各自上浮水印」
//        照片拼圖 → 不開選取器、不進第二層，直接推拼圖頁
//        GIF      → 不進第二層，直接開影片選取器，挑一支進 GIF 製作頁
//                   （匯入現成的 GIF 是 個人中心「我的 GIF」的事，
//                   首頁這裡不問）
//        剪輯     → 不開選取器、不進第二層，直接開一條空的時間軸
//   4. 第二層左上角的返回：回到第一層（不是關掉整個選單），整條列
//      都按得到
//   5. 重入鎖：面板開著時連點＋不會疊出第二個；關掉之後鎖要放開
//
// 選取器換成假的（FilePicker.platform／ImagePickerPlatform.instance），
// 不然測試會去戳真的原生選取器。測試環境的 defaultTargetPlatform 是
// android：照片走 image_picker 的 pickMultiImage、影片先問 markcut/pick
// 通道（這裡回 null ＝「這台沒有系統相片選取器」）再退到 file_picker
// ——跟 lib 裡的順序一樣，見 services/video_picker.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/screens/gif_screen.dart';
import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/theme.dart';

/// 8×8 PNG（測試自己寫出來，不依賴任何外部檔案）
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';

/// ＋選單第一層，由上而下
const _labels = ['浮水印', '照片拼圖', 'GIF', '剪輯'];
const _subs = ['照片、影片，單支或整批快速加入浮水印', '多張照片拼成一張', '影片轉成 GIF', '開啟一個空專案自由編輯'];
const _icons = [
  Icons.branding_watermark_outlined,
  Icons.grid_view_rounded,
  Icons.gif_box_outlined,
  Icons.smart_display_outlined,
];

late Directory _dir;
String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

/// 假的檔案選取器（影片那條路）：記下被要求開的是哪一種、回 [next]
/// 這些檔案（空＝使用者按了取消）。[hold] 有值時先不回——模擬
/// 「選取器還開在畫面上」
class _FakeFilePicker extends FilePicker {
  int calls = 0;
  FileType? lastType;
  bool? lastMultiple;
  List<String> next = const [];
  Completer<List<String>>? hold;

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
    lastMultiple = allowMultiple;
    final paths = hold != null ? await hold!.future : next;
    if (paths.isEmpty) return null;
    return FilePickerResult([
      for (final p in paths)
        PlatformFile(
          path: p,
          name: p.split(Platform.pathSeparator).last,
          size: File(p).lengthSync(),
        ),
    ]);
  }
}

/// 假的相簿選取器（照片那條路）。[hold] 同上
class _FakeImagePicker extends ImagePickerPlatform {
  int calls = 0;
  List<XFile> next = const [];
  Completer<List<XFile>>? hold;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) {
    calls++;
    return hold?.future ?? Future.value(next);
  }

  @override
  Future<List<XFile>> getMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
  }) => getMultiImageWithOptions();

  @override
  Future<List<XFile>> getMedia({required MediaOptions options}) {
    calls++;
    return hold?.future ?? Future.value(next);
  }
}

late _FakeFilePicker _files;
late _FakeImagePicker _images;

/// 記下被推出去的頁
class _RouteSpy extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }

  /// 走 editRoute 推出去的頁（編輯頁一律不收右滑返回）
  List<EditPageRoute<dynamic>> get edits =>
      pushed.whereType<EditPageRoute<dynamic>>().toList();

  /// 最後一頁的 widget（用 builder 再建一份來看它的參數）
  Widget lastEdit(WidgetTester t) =>
      edits.last.builder(t.element(find.byType(MaterialApp)));
}

/// SharedPreferences、假選取器、讀檔都是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 推出去的頁（批次、GIF 製作）會掛提示條、重試計時器；測試結束前
/// 要讓它們走完，不然框架會抱怨還有 Timer
Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(seconds: 3));
  await t.pump(const Duration(seconds: 3));
}

/// 跟 main.dart 一樣：工作室佈景的 App、首頁包 LightPage
Future<void> _pump(WidgetTester t, {NavigatorObserver? spy}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      navigatorObservers: [?spy],
      home: const LightPage(child: HomeScreen()),
    ),
  );
  await _settle(t);
}

/// 按右下角那顆＋，等面板長出來
Future<void> _tapFab(WidgetTester t) async {
  await t.tap(find.byType(FloatingActionButton));
  await _settle(t);
}

/// 模擬手機：邏輯 [w]×[h]、dpr 2、狀態列 20（SE 沒有瀏海也沒有 home 條）
void _phone(WidgetTester t, double w, double h) {
  t.view.devicePixelRatio = 2.0;
  t.view.physicalSize = Size(w * 2, h * 2);
  t.view.padding = const FakeViewPadding(top: 40);
  t.view.viewPadding = const FakeViewPadding(top: 40);
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    _dir = Directory.systemTemp.createTempSync('markcut_home_');
    final png = base64Decode(_pngB64);
    for (final n in const ['a.png', 'b.png', 'c.png']) {
      File(_p(n)).writeAsBytesSync(png);
    }
    // 影片只要「檔案存在」就好：首頁是照副檔名認影片的，內容不會被讀
    for (final n in const ['a.mp4', 'b.mp4']) {
      File(_p(n)).writeAsBytesSync(List<int>.filled(64, 0));
    }

    // 測試環境沒有這些原生外掛，擋掉不然推出去的頁一開就丟例外
    for (final ch in const [
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
      'flutter.arthenica.com/ffmpeg_kit',
      // 安卓的系統相片選取器：回 null ＝ 這台沒有，退到 file_picker
      'markcut/pick',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _dir.path,
    );
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  tearDownAll(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _files = _FakeFilePicker();
    FilePicker.platform = _files;
    _images = _FakeImagePicker();
    final prev = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _images;
    addTearDown(() => ImagePickerPlatform.instance = prev);
  });

  group('首頁本體', () {
    testWidgets('只有 logo、個人中心、底部的「＋ 開始」，沒有任何入口文字', (t) async {
      await _pump(t);

      for (final x in const [
        '加入浮水印',
        '製作浮水印',
        '影片編輯',
        '剪輯',
        '浮水印',
        '照片拼圖',
        'GIF',
      ]) {
        expect(find.text(x), findsNothing, reason: '「$x」不該出現在收起來的首頁');
      }
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      // 按鈕上只有「開始」兩個字，不劇透底下有哪些功能
      expect(find.text('開始'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('「＋ 開始」貼底、左右各留 24、高 56、黑底白字；logo 原尺寸置中', (t) async {
      _phone(t, 390, 844);
      await _pump(t);

      final fab = t.getRect(find.byType(FloatingActionButton));
      expect(fab.width, 390 - kHomeStartPad * 2, reason: '左右各留 24');
      expect(fab.height, moreOrLessEquals(kHomeStartH, epsilon: 0.1));
      expect(fab.left, moreOrLessEquals(kHomeStartPad, epsilon: 0.5));
      expect(fab.center.dx, moreOrLessEquals(195, epsilon: 0.5), reason: '要置中');
      expect(fab.center.dy, greaterThan(844 * 0.8), reason: '要貼在最下面');
      expect(fab.bottom, lessThan(844), reason: '不能超出畫面');
      // 但也不能真的貼死在邊上：centerFloat 的 16 之外再抬 kHomeStartLift
      expect(
        844 - fab.bottom,
        moreOrLessEquals(16 + kHomeStartLift, epsilon: 0.5),
        reason: '離底邊的距離不對',
      );

      final f = t.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(f.backgroundColor, kLAccent);
      expect(f.foregroundColor, kLBg);
      expect(f.shape, isA<StadiumBorder>());
      expect(f.isExtended, isTrue, reason: '要帶字的那種');

      final logo = t.getRect(find.byType(Image));
      expect(logo.width, kHomeLogoSize.width);
      expect(logo.height, kHomeLogoSize.height);
      expect(logo.center.dx, moreOrLessEquals(195, epsilon: 0.5));
      expect(t.takeException(), isNull);
    });

    testWidgets('iPhone SE（375×667）也放得下、不溢出', (t) async {
      _phone(t, 375, 667);
      await _pump(t);
      expect(t.takeException(), isNull, reason: 'SE 上溢出了');
      expect(t.getRect(find.byType(Image)).height, kHomeLogoSize.height);
      final fab = t.getRect(find.byType(FloatingActionButton));
      expect(fab.bottom, lessThan(667));
      expect(fab.width, 375 - kHomeStartPad * 2, reason: '窄畫面也是左右各留 24');
    });

    testWidgets('很寬的畫面（平板橫向）：膠囊不跟著拉成長棒', (t) async {
      _phone(t, 1024, 768);
      await _pump(t);
      final fab = t.getRect(find.byType(FloatingActionButton));
      expect(fab.width, kHomeStartMaxW, reason: '寬度要封頂');
      expect(fab.center.dx, moreOrLessEquals(512, epsilon: 0.5), reason: '置中');
      expect(t.takeException(), isNull);
    });
  });

  group('＋叫出來的第一層', () {
    testWidgets('四列：順序、文案、說明、圖示；右邊不畫箭頭', (t) async {
      await _pump(t);
      await _tapFab(t);

      final ys = <double>[];
      for (var i = 0; i < _labels.length; i++) {
        expect(
          find.text(_labels[i]),
          findsOneWidget,
          reason: '少了「${_labels[i]}」',
        );
        expect(
          find.text(_subs[i]),
          findsOneWidget,
          reason: '「${_labels[i]}」的說明不對',
        );
        expect(
          find.byIcon(_icons[i]),
          findsOneWidget,
          reason: '「${_labels[i]}」的圖示不對',
        );
        ys.add(t.getCenter(find.text(_labels[i])).dy);
      }
      for (var i = 1; i < _labels.length; i++) {
        expect(ys[i] > ys[i - 1], isTrue, reason: '順序不對（由上而下量到 $ys）');
      }
      expect(
        find.byIcon(Icons.chevron_right),
        findsNothing,
        reason: '面板上不畫右箭頭（使用者指定）',
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('窄畫面（375）：四列的說明都放得下，不會被截成「…」', (t) async {
      // 說明文字是使用者自己給的句子，改了就可能變長；截斷是 ellipsis
      // 而不是溢出，眼睛不一定看得出來，所以直接問渲染器有沒有超行
      _phone(t, 375, 667);
      await _pump(t);
      await _tapFab(t);
      for (final x in [..._labels, ..._subs]) {
        final rp = t.renderObject<RenderParagraph>(find.text(x));
        expect(rp.didExceedMaxLines, isFalse, reason: '「$x」在 375 寬被截掉了');
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('照片拼圖：不開選取器、不進第二層，直接推拼圖頁', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await _tapFab(t);
      await t.tap(find.text('照片拼圖'));
      await _settle(t);

      expect(_images.calls + _files.calls, 0, reason: '拼圖不該先開選取器');
      final page = spy.lastEdit(t);
      expect(page, isA<CollageScreen>());
      expect((page as CollageScreen).photos, isEmpty);
      expect(find.byType(CollageScreen), findsOneWidget);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('浮水印 → 第二層「照片／影片」；選照片 → 照片選取器 → 兩張問怎麼處理', (t) async {
      _images.next = [
        XFile(_p('a.png'), name: 'a.png'),
        XFile(_p('b.png'), name: 'b.png'),
      ];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await _tapFab(t);
      await t.tap(find.text('浮水印'));
      await _settle(t);

      // 第二層：返回那一行寫著上一層的名字，兩列照片／影片
      expect(find.text('浮水印'), findsOneWidget, reason: '第二層要標上一層是誰');
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('影片'), findsOneWidget);
      expect(_images.calls + _files.calls, 0, reason: '還沒選就開了選取器');

      await t.tap(find.text('照片'));
      await _settle(t);
      expect(_images.calls, 1, reason: '沒有開照片選取器');
      expect(_files.calls, 0, reason: '開錯了（只列影片那個選取器）');
      expect(
        find.text('選了 2 張照片'),
        findsOneWidget,
        reason: '多張沒有問要串成影片還是各自上浮水印',
      );

      await t.tap(find.text('統一上浮水印'));
      await _settle(t, 20);
      final page = spy.lastEdit(t);
      expect(page, isA<BatchWatermarkScreen>());
      expect(
        [for (final f in (page as BatchWatermarkScreen).files) f.path],
        [_p('a.png'), _p('b.png')],
        reason: '順序＝點選順序',
      );
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('浮水印 → 影片：影片選取器，非影片檔濾掉，兩支問怎麼處理', (t) async {
      // 選取器照理只列影片，但 web／舊安卓那條路可能混進照片，首頁要自己濾
      _files.next = [_p('a.mp4'), _p('c.png'), _p('b.mp4')];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await _tapFab(t);
      await t.tap(find.text('浮水印'));
      await _settle(t);
      await t.tap(find.text('影片'));
      await _settle(t);

      expect(_files.calls, 1, reason: '沒有開影片選取器');
      expect(_files.lastType, FileType.video, reason: '相簿只能列影片');
      expect(_files.lastMultiple, isTrue);
      expect(_images.calls, 0, reason: '開錯了（照片那個選取器）');
      expect(find.text('選了 2 部影片'), findsOneWidget);

      await t.tap(find.text('統一上浮水印'));
      await _settle(t, 20);
      final page = spy.lastEdit(t);
      expect(page, isA<BatchWatermarkScreen>());
      expect(
        [for (final f in (page as BatchWatermarkScreen).files) f.path],
        [_p('a.mp4'), _p('b.mp4')],
        reason: '照片要被濾掉、影片照點選順序',
      );
      expect(page.initialHint, '已略過 1 個非影片檔案');
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('第二層的返回：回到第一層，不是把整個選單關掉', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await _tapFab(t);
      await t.tap(find.text('浮水印'));
      await _settle(t);
      expect(find.text('照片'), findsOneWidget);
      expect(find.text('照片拼圖'), findsNothing, reason: '第二層開著時第一層要收掉');

      await t.tap(find.byIcon(Icons.chevron_left));
      await _settle(t);
      expect(find.text('照片'), findsNothing, reason: '第二層沒收掉');
      for (final x in _labels) {
        expect(find.text(x), findsOneWidget, reason: '沒回到第一層（少了「$x」）');
      }
      expect(_images.calls + _files.calls, 0, reason: '返回不該開選取器');
      expect(spy.edits, isEmpty, reason: '返回不該推頁');

      // 回到第一層之後照樣走得下去。這次按返回列右邊的空白處：整條
      // 都是熱區，不是只有那個小箭頭
      await t.tap(find.text('浮水印'));
      await _settle(t);
      expect(find.text('影片'), findsOneWidget, reason: '返回之後第二層開不出來');
      final back = find
          .ancestor(
            of: find.byIcon(Icons.chevron_left),
            matching: find.byType(InkWell),
          )
          .first;
      final r = t.getRect(back);
      expect(r.height, kHomeSheetBackH, reason: '返回列的熱區高度不對');
      await t.tapAt(Offset(r.right - 8, r.center.dy));
      await _settle(t);
      expect(find.text('影片'), findsNothing, reason: '返回列只有箭頭按得到');
      expect(find.text('照片拼圖'), findsOneWidget, reason: '沒回到第一層');
      expect(t.takeException(), isNull);
    });

    testWidgets('GIF：不進第二層，直接開影片選取器，第一支進 GIF 製作頁', (t) async {
      // 使用者指定「GIF 不要有匯入現成的，就是製作就好」：那三選一的
      // 面板（製作／從相簿匯入／從檔案匯入）只留在 個人中心 →「我的 GIF」
      _files.next = [_p('a.mp4'), _p('b.mp4')];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await _tapFab(t);
      await t.tap(find.text('GIF'));
      await _settle(t, 20);

      expect(_files.calls, 1, reason: '沒有直接開選取器（中間又問了一輪？）');
      expect(_files.lastType, FileType.video, reason: '要挑的是影片');
      for (final x in const ['製作 GIF', '從相簿匯入 GIF', '從檔案匯入 GIF']) {
        expect(find.text(x), findsNothing, reason: '首頁不該再問「$x」');
      }
      final page = spy.lastEdit(t);
      expect(page, isA<GifScreen>());
      expect((page as GifScreen).path, _p('a.mp4'), reason: '多選了就拿第一支');
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('剪輯：不開選取器、不進第二層，直接開一條空的時間軸', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await _tapFab(t);
      await t.tap(find.text('剪輯'));
      await _settle(t, 20);

      expect(_images.calls + _files.calls, 0, reason: '剪輯不該先開選取器');
      final page = spy.lastEdit(t);
      expect(page, isA<VideoEditorScreen>());
      expect((page as VideoEditorScreen).blank, isTrue, reason: '要開的是空軌道');
      expect(page.videoPath, isNull);
      expect(page.videoPaths, isNull);
      expect(page.photoPaths, isNull);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('取消選取器：什麼都不推、鎖也要放開', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      // 浮水印 → 照片：回空清單＝取消
      await _tapFab(t);
      await t.tap(find.text('浮水印'));
      await _settle(t);
      await t.tap(find.text('照片'));
      await _settle(t);
      expect(_images.calls, 1);
      expect(spy.edits, isEmpty);

      // 鎖放開了才點得動第二次
      await _tapFab(t);
      expect(find.text('照片拼圖'), findsOneWidget, reason: '取消之後鎖沒放開');
      expect(t.takeException(), isNull);
    });
  });

  group('重入鎖', () {
    testWidgets('面板開著時連點＋：只開一個，關掉之後才能再開', (t) async {
      await _pump(t);
      for (var i = 0; i < 20; i++) {
        await t.tap(find.byType(FloatingActionButton), warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 5));
        expect(
          find.text('照片拼圖').evaluate().length <= 1,
          isTrue,
          reason: '第 $i 次連點之後疊出了不只一個面板',
        );
      }
      await _settle(t);
      // 收乾淨（點面板外面）再開一次
      if (find.text('照片拼圖').evaluate().isNotEmpty) {
        await t.tapAt(const Offset(10, 10));
        await _settle(t);
      }
      await _tapFab(t);
      expect(find.text('照片拼圖'), findsOneWidget, reason: '面板關掉之後鎖沒放開');
      expect(t.takeException(), isNull);
    });

    testWidgets('選取器開著時連點＋：不會再開一個面板', (t) async {
      _files.hold = Completer();
      await _pump(t);
      await _tapFab(t);
      await t.tap(find.text('浮水印'));
      await _settle(t);
      await t.tap(find.text('影片'));
      await _settle(t);
      expect(_files.calls, 1);

      for (var i = 0; i < 10; i++) {
        await t.tap(find.byType(FloatingActionButton), warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 5));
      }
      expect(_files.calls, 1, reason: '連點之後選取器被開了 ${_files.calls} 次');
      expect(find.text('照片拼圖'), findsNothing, reason: '選取器開著時又跳了面板');

      _files.hold!.complete(const []);
      _files.hold = null;
      await _settle(t);
      expect(t.takeException(), isNull);
    });
  });
}
