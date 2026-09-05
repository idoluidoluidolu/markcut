// 首頁：四顆入口（浮水印／照片拼圖／GIF／影片編輯），每一顆直接進功能。
//
// 守的是：
//   1. 四顆的順序、文案、圖示、主次（第一顆反白，使用者挑的樣子）——
//      舊的「加入浮水印」「製作浮水印」不再出現，也沒有先問「影片還是
//      照片」的選單，按鈕上也沒有說明文字
//   2. 「下面整齊一點」（使用者的話）：四個圖示落在同一個 x、四段文字
//      也從同一個 x 起頭，整組在膠囊裡置中；系統字級放大到 1.2 倍照舊
//   3. iPhone SE（375×667）放得下：不溢出、logo 完整、按鈕貼底；
//      更矮的畫面 logo 縮小、按鈕不動；連按鈕都放不下就不畫 logo、
//      按鈕自己捲
//   4. 每一顆點下去走的是對的選取器／對的頁：
//        浮水印   → 相簿混選（影片、照片都行）→ 多個同類問「接成一支／串成
//                   影片還是各自上浮水印」，混著選就直接進批次
//        照片拼圖 → 不開選取器，直接推拼圖頁
//        GIF      → 影片選取器（只列影片、可多選）→ 拿第一支進 GIF 製作頁
//        影片編輯 → 不開選取器，直接開一條空的時間軸
//   5. 重入鎖：選取器開著時連點不會再開第二個，關掉之後鎖要放開
//
// 選取器換成假的（FilePicker.platform／ImagePickerPlatform.instance），
// 不然測試會去戳真的原生選取器。測試環境的 defaultTargetPlatform 是
// android：混選走 image_picker 的 pickMultipleMedia、影片先問 markcut/pick
// 通道（這裡回 null ＝「這台沒有系統相片選取器」）再退到 file_picker
// ——跟 lib 裡的順序一樣，見 services/video_picker.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

/// 首頁四顆，由上而下
const _labels = ['浮水印', '照片拼圖', 'GIF', '影片編輯'];
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

  /// 首頁「浮水印」走的是相簿混選（pickMultipleMedia）
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

/// 某一顆膠囊本體（文字往上找最近的 Material）
Finder _pill(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Material)).first;

/// 四顆按鈕加間距的總高
const _btnsH = 4 * kHomeBtnH + 3 * kHomeBtnGap;

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

  group('版面', () {
    testWidgets('四顆入口：順序、文案、圖示、主次', (t) async {
      await _pump(t);

      for (final x in const ['加入浮水印', '製作浮水印']) {
        expect(find.text(x), findsNothing, reason: '舊的「$x」不該再出現在首頁');
      }
      final ys = <double>[];
      for (var i = 0; i < 4; i++) {
        final label = find.text(_labels[i]);
        final icon = find.byIcon(_icons[i]);
        expect(label, findsOneWidget, reason: '少了「${_labels[i]}」');
        expect(icon, findsOneWidget, reason: '「${_labels[i]}」的圖示不對');
        // 圖示跟文字在同一列
        expect(
          t.getCenter(icon).dy,
          moreOrLessEquals(t.getCenter(label).dy, epsilon: 1),
        );
        ys.add(t.getCenter(label).dy);
      }
      for (var i = 1; i < 4; i++) {
        expect(ys[i] > ys[i - 1], isTrue, reason: '順序不對（由上而下量到 $ys）');
      }

      // 膠囊：56 高、間距 12、滿版（左右各 24）
      final w = t.getSize(find.byType(MaterialApp)).width;
      final pills = [for (final l in _labels) t.getRect(_pill(l))];
      for (final r in pills) {
        expect(r.height, kHomeBtnH);
        expect(r.left, 24);
        expect(r.right, w - 24);
      }
      for (var i = 1; i < 4; i++) {
        expect(
          pills[i].top - pills[i - 1].bottom,
          moreOrLessEquals(kHomeBtnGap, epsilon: 0.01),
        );
      }

      // 主次：第一顆反白填滿（近黑底、白圖示、白字），其他三顆描邊
      for (var i = 0; i < 4; i++) {
        final primary = i == 0;
        final m = t.widget<Material>(_pill(_labels[i]));
        expect(m.color, primary ? kLAccent : Colors.transparent);
        expect(m.shape, isA<RoundedRectangleBorder>());
        final shape = m.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(kHomeBtnRadius));
        expect(
          shape.side.style,
          primary ? BorderStyle.none : BorderStyle.solid,
          reason: primary ? '反白那顆不該再描邊' : '「${_labels[i]}」少了邊線',
        );
        if (!primary) expect(shape.side.color, kLBorder);
        final fg = primary ? kLBg : kLText;
        expect(t.widget<Icon>(find.byIcon(_icons[i])).color, fg);
        expect(t.widget<Text>(find.text(_labels[i])).style?.color, fg);
      }
      // 按鈕上只有名稱，沒有說明文字
      expect(
        find.descendant(of: _pill('浮水印'), matching: find.byType(Text)),
        findsOneWidget,
      );

      // 右上角的個人中心還在
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    /// 四個圖示同一個 x、四段文字同一個 x，整組在膠囊裡置中
    Future<void> expectAligned(WidgetTester t) async {
      final iconLefts = [
        for (final i in _icons) t.getRect(find.byIcon(i)).left,
      ];
      final labelLefts = [
        for (final l in _labels) t.getRect(find.text(l)).left,
      ];
      for (var i = 1; i < 4; i++) {
        expect(
          iconLefts[i],
          moreOrLessEquals(iconLefts[0], epsilon: 0.01),
          reason: '圖示沒對齊：$iconLefts',
        );
        expect(
          labelLefts[i],
          moreOrLessEquals(labelLefts[0], epsilon: 0.01),
          reason: '文字沒對齊：$labelLefts',
        );
      }
      // 文字緊接在圖示後面
      expect(
        labelLefts[0] - iconLefts[0],
        moreOrLessEquals(kHomeBtnIcon + kHomeBtnIconGap, epsilon: 0.01),
      );
      // 整組（固定寬 kHomeBtnGroupW）在膠囊裡置中：左邊留白＝右邊留白
      final pill = t.getRect(_pill(_labels[0]));
      final groupRight = iconLefts[0] + kHomeBtnGroupW;
      expect(
        iconLefts[0] - pill.left,
        moreOrLessEquals(pill.right - groupRight, epsilon: 0.01),
        reason: '那一組沒有在膠囊裡置中',
      );
      // 最寬的文字也放得進那一組——放不下的話文字會被推出去，四顆又不齊了
      for (final l in _labels) {
        expect(
          t.getRect(find.text(l)).right <= groupRight + 0.01,
          isTrue,
          reason: '「$l」超出固定寬度的那一組',
        );
      }
    }

    testWidgets('下面整齊一點：四個圖示同一個 x、四段文字同一個 x、整組置中', (t) async {
      await _pump(t);
      await expectAligned(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('系統字級放大到 1.2 倍（App 的上限）照樣整齊、不溢出', (t) async {
      t.platformDispatcher.textScaleFactorTestValue = 1.2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(t);
      await expectAligned(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('iPhone SE（375×667）放得下：不溢出、logo 完整、按鈕貼底', (t) async {
      _phone(t, 375, 667);
      await _pump(t);
      expect(t.takeException(), isNull, reason: 'SE 上溢出了');

      final logo = t.getRect(find.byType(Image));
      expect(logo.width, kHomeLogoSize.width);
      expect(logo.height, kHomeLogoSize.height);
      // logo 在標題列（狀態列 20＋56）底下、第一顆按鈕上面
      expect(logo.top, greaterThan(76));
      final first = t.getRect(_pill(_labels[0]));
      final last = t.getRect(_pill(_labels[3]));
      expect(logo.bottom, lessThan(first.top));
      // 按鈕群貼底（底部留白 20），四顆佔 4×56＋3×12
      expect(last.bottom, moreOrLessEquals(667 - 20, epsilon: 0.01));
      expect(last.bottom - first.top, moreOrLessEquals(_btnsH, epsilon: 0.01));
      await expectAligned(t);
    });

    testWidgets('更矮的畫面：logo 等比縮小、按鈕群不動、不溢出', (t) async {
      // 狀態列 20＋標題列 56＋底部留白 20，剩 324 給 logo＋按鈕（260）
      _phone(t, 375, 420);
      await _pump(t);
      expect(t.takeException(), isNull, reason: '矮畫面溢出了');

      final logo = t.getRect(find.byType(Image));
      expect(logo.height, lessThan(kHomeLogoSize.height));
      expect(logo.height, greaterThan(0));
      expect(
        logo.width / logo.height,
        moreOrLessEquals(
          kHomeLogoSize.width / kHomeLogoSize.height,
          epsilon: 0.01,
        ),
        reason: 'logo 縮了但沒有等比',
      );
      final first = t.getRect(_pill(_labels[0]));
      final last = t.getRect(_pill(_labels[3]));
      expect(logo.bottom <= first.top, isTrue);
      expect(last.bottom, moreOrLessEquals(420 - 20, epsilon: 0.01));
      expect(last.bottom - first.top, moreOrLessEquals(_btnsH, epsilon: 0.01));
    });

    testWidgets('連按鈕都放不下（330 高）：logo 不畫、按鈕自己捲、不溢出', (t) async {
      // 狀態列 20＋標題列 56＋底部留白 20，剩 234 < 260
      _phone(t, 844, 330);
      await _pump(t);
      expect(t.takeException(), isNull, reason: '矮畫面溢出了');
      expect(find.byType(Image), findsNothing, reason: '放不下就不該硬擠 logo');
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      for (final l in _labels) {
        expect(find.text(l), findsOneWidget);
      }
      // 最後一顆一開始在可視區外，捲到底就貼著底部留白
      expect(t.getRect(_pill(_labels[3])).bottom, greaterThan(330 - 20));
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
      await t.pumpAndSettle();
      expect(
        t.getRect(_pill(_labels[3])).bottom,
        moreOrLessEquals(330 - 20, epsilon: 0.01),
      );
      expect(t.takeException(), isNull);
    });
  });

  group('每一顆走的路', () {
    testWidgets('浮水印：相簿混選（不再問影片／照片），兩張照片問串成影片還是各自上浮水印', (t) async {
      _images.next = [
        XFile(_p('a.png'), name: 'a.png'),
        XFile(_p('b.png'), name: 'b.png'),
      ];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('浮水印'));
      await _settle(t);

      expect(_images.calls, 1, reason: '沒有開相簿混選');
      expect(_files.calls, 0, reason: '開錯了（只列影片那個選取器）');
      expect(find.text('加入浮水印'), findsNothing, reason: '不該再先問「影片還是照片」');
      expect(
        find.text('選了 2 張照片'),
        findsOneWidget,
        reason: '多張沒有問要串成影片還是各自上浮水印',
      );
      expect(find.text('串成一段影片'), findsOneWidget);
      expect(spy.edits, isEmpty, reason: '還沒問完就推了頁');

      await t.tap(find.text('統一上浮水印'));
      await _settle(t, 20);
      final page = spy.lastEdit(t);
      expect(page, isA<BatchWatermarkScreen>(), reason: '各自上浮水印要進批次頁');
      expect(
        [for (final f in (page as BatchWatermarkScreen).files) f.path],
        [_p('a.png'), _p('b.png')],
        reason: '順序＝點選順序',
      );
      expect(page.initialHint, isNull, reason: '兩張照片沒什麼好提醒的');
      expect(find.byType(BatchWatermarkScreen), findsOneWidget);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('照片拼圖：不開選取器，直接進拼圖頁（照片進去再挑）', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('照片拼圖'));
      await _settle(t);

      expect(_images.calls + _files.calls, 0, reason: '拼圖不該先開選取器');
      final page = spy.lastEdit(t);
      expect(page, isA<CollageScreen>());
      expect((page as CollageScreen).photos, isEmpty);
      expect(page.restore, isNull);
      expect(find.byType(CollageScreen), findsOneWidget);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('GIF：開影片選取器（只列影片、可多選），拿第一支進 GIF 製作頁', (t) async {
      _files.next = [_p('a.mp4'), _p('b.mp4')];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('GIF'));
      await _settle(t, 20);

      expect(_files.calls, 1, reason: '沒有開影片選取器');
      expect(_files.lastType, FileType.video, reason: '相簿只能列影片');
      expect(_files.lastMultiple, isTrue);
      expect(_images.calls, 0, reason: '開錯了（照片那個選取器）');
      final page = spy.lastEdit(t);
      expect(page, isA<GifScreen>());
      expect((page as GifScreen).path, _p('a.mp4'), reason: '多選了就拿第一支');
      expect(page.name, 'a.mp4');
      // 測試環境沒有播放器外掛，製作頁開不了片會自己提示＋退回來，
      // 那句提示的計時器要跑完
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('浮水印：兩支影片問接成一支還是各自上浮水印', (t) async {
      _images.next = [
        XFile(_p('a.mp4'), name: 'a.mp4'),
        XFile(_p('b.mp4'), name: 'b.mp4'),
      ];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('浮水印'));
      await _settle(t);

      expect(_images.calls, 1);
      expect(_files.calls, 0);
      expect(find.text('選了 2 部影片'), findsOneWidget, reason: '多支要先問');
      expect(find.text('剪成一支影片'), findsOneWidget);
      expect(spy.edits, isEmpty, reason: '還沒問完就推了頁');

      await t.tap(find.text('統一上浮水印'));
      await _settle(t, 20);
      final page = spy.lastEdit(t);
      expect(page, isA<BatchWatermarkScreen>());
      expect(
        [for (final f in (page as BatchWatermarkScreen).files) f.path],
        [_p('a.mp4'), _p('b.mp4')],
        reason: '影片照點選順序',
      );
      expect(page.initialHint, isNull, reason: '兩支影片沒什麼好提醒的');
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('浮水印：照片影片混著選，不問，直接進批次', (t) async {
      _images.next = [
        XFile(_p('a.mp4'), name: 'a.mp4'),
        XFile(_p('c.png'), name: 'c.png'),
      ];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('浮水印'));
      await _settle(t, 20);

      expect(find.byType(Dialog), findsNothing, reason: '混著選沒有「接成一支」可問');
      final page = spy.lastEdit(t);
      expect(page, isA<BatchWatermarkScreen>());
      expect(
        [for (final f in (page as BatchWatermarkScreen).files) f.path],
        [_p('a.mp4'), _p('c.png')],
        reason: '照點選順序、什麼都不濾',
      );
      expect(page.initialHint, isNull);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('影片編輯：不開選取器，直接開一條空的時間軸', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('影片編輯'));
      await _settle(t, 20);

      expect(_images.calls + _files.calls, 0, reason: '影片編輯不該先開選取器');
      final page = spy.lastEdit(t);
      expect(page, isA<VideoEditorScreen>());
      expect((page as VideoEditorScreen).blank, isTrue, reason: '要開的是空軌道');
      expect(page.videoPath, isNull);
      expect(page.videoPaths, isNull);
      expect(page.photoPaths, isNull);
      expect(find.byType(VideoEditorScreen), findsOneWidget);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('取消選取器：什麼都不推、鎖也要放開', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      // 混選：回空清單＝取消
      await t.tap(find.text('浮水印'));
      await _settle(t);
      // 影片：回 null＝取消
      await t.tap(find.text('GIF'));
      await _settle(t);
      expect(_images.calls, 1);
      expect(_files.calls, 1, reason: '取消之後鎖沒放開，後面的點不動');
      expect(spy.edits, isEmpty);
      expect(find.byType(Dialog), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('重入鎖', () {
    testWidgets('影片選取器開著時連點：只開一次，關掉之後才能再開', (t) async {
      _files.hold = Completer();
      await _pump(t);

      // 選取器「開著」（future 沒回）的時候狂點：只能開一次
      for (var i = 0; i < 30; i++) {
        await t.tap(find.text('GIF'), warnIfMissed: false);
        await t.tap(find.text('浮水印'), warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 5));
      }
      expect(_files.calls, 1, reason: '連點之後選取器被開了 ${_files.calls} 次');
      expect(_images.calls, 0, reason: '影片選取器開著時「浮水印」不該再開一個');

      // 取消（回空）→ 鎖放開，再點一下要能再開
      _files.hold!.complete(const []);
      _files.hold = null;
      await _settle(t);
      await t.tap(find.text('GIF'));
      await _settle(t);
      expect(_files.calls, 2, reason: '選取器關掉之後鎖沒放開');
      expect(t.takeException(), isNull);
    });
  });
}
