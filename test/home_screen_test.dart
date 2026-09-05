// 首頁：四個入口方塊（浮水印／照片拼圖／GIF／剪輯），每一個直接進功能。
//
// 守的是：
//   1. 四個的順序、文案、圖示、主次（第一個反白，使用者挑的樣子）——
//      舊的「加入浮水印」「製作浮水印」不再出現，方塊上也沒有說明文字
//   2. 版面：方塊是正方形、四個等寬、間距 12、整排滿版；名稱在方塊
//      正下方置中；系統字級放大到 1.2 倍照舊
//   3. iPhone SE（375×667）放得下：不溢出、logo 完整、方塊貼底；
//      更矮的畫面 logo 縮小、方塊不動；連方塊都放不下就不畫 logo、
//      自己捲
//   4. 每一個點下去走的是對的選取器／對的頁：
//        浮水印   → 先問「照片還是影片」→ 開對應的選取器 → 多個問
//                   「接成一支／串成影片還是各自上浮水印」
//        照片拼圖 → 不開選取器，直接推拼圖頁
//        GIF      → 影片選取器（只列影片、可多選）→ 拿第一支進 GIF 製作頁
//        剪輯     → 不開選取器，直接開一條空的時間軸
//   5. 重入鎖：選取器開著時連點不會再開第二個，關掉之後鎖要放開
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

/// 首頁四個，由左到右
const _labels = ['浮水印', '照片拼圖', 'GIF', '剪輯'];
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

/// 某一個方塊本體（圖示往上找最近的 Material；名稱是它的兄弟不是後代）
Finder _sq(int i) => find
    .ancestor(of: find.byIcon(_icons[i]), matching: find.byType(Material))
    .first;

/// 方塊那一排的高度：邊長＋間距＋一行 12px 的字
double _tilesH(WidgetTester t, double pageW) {
  final side = (pageW - 48 - kHomeTileGap * 3) / 4;
  return side + kHomeTileLabelGap + t.getSize(find.text(_labels[0])).height;
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

  group('版面', () {
    testWidgets('四個入口方塊：順序、文案、圖示、主次', (t) async {
      await _pump(t);

      for (final x in const ['加入浮水印', '製作浮水印', '影片編輯']) {
        expect(find.text(x), findsNothing, reason: '舊的「$x」不該再出現在首頁');
      }
      final xs = <double>[];
      for (var i = 0; i < 4; i++) {
        final label = find.text(_labels[i]);
        final icon = find.byIcon(_icons[i]);
        expect(label, findsOneWidget, reason: '少了「${_labels[i]}」');
        expect(icon, findsOneWidget, reason: '「${_labels[i]}」的圖示不對');
        // 名稱在方塊正下方、左右置中對齊
        final sq = t.getRect(_sq(i));
        expect(
          t.getCenter(label).dx,
          moreOrLessEquals(sq.center.dx, epsilon: 0.01),
          reason: '「${_labels[i]}」的名稱沒有對齊方塊中線',
        );
        expect(
          t.getRect(label).top - sq.bottom,
          moreOrLessEquals(kHomeTileLabelGap, epsilon: 0.01),
        );
        xs.add(sq.center.dx);
      }
      for (var i = 1; i < 4; i++) {
        expect(xs[i] > xs[i - 1], isTrue, reason: '順序不對（由左而右量到 $xs）');
      }

      // 方塊：正方形、四個等寬、間距 12、整排滿版（左右各 24）
      final w = t.getSize(find.byType(MaterialApp)).width;
      final sqs = [for (var i = 0; i < 4; i++) t.getRect(_sq(i))];
      for (final r in sqs) {
        expect(r.width, moreOrLessEquals(r.height, epsilon: 0.01));
        expect(
          r.width,
          moreOrLessEquals(sqs[0].width, epsilon: 0.01),
          reason: '四個方塊不一樣大',
        );
      }
      expect(sqs.first.left, moreOrLessEquals(24, epsilon: 0.01));
      expect(sqs.last.right, moreOrLessEquals(w - 24, epsilon: 0.01));
      for (var i = 1; i < 4; i++) {
        expect(
          sqs[i].left - sqs[i - 1].right,
          moreOrLessEquals(kHomeTileGap, epsilon: 0.01),
        );
        expect(
          sqs[i].top,
          moreOrLessEquals(sqs[0].top, epsilon: 0.01),
          reason: '四個方塊沒有對齊在同一條線上',
        );
      }

      // 主次：第一個反白（近黑底、白圖示），其他三個淺灰底、深圖示；
      // 名稱一律是正文色
      for (var i = 0; i < 4; i++) {
        final primary = i == 0;
        final m = t.widget<Material>(_sq(i));
        expect(m.color, primary ? kLAccent : kLTile);
        expect(m.borderRadius, BorderRadius.circular(kHomeTileRadius));
        final ic = t.widget<Icon>(find.byIcon(_icons[i]));
        expect(ic.color, primary ? kLBg : kLText);
        expect(ic.size, kHomeTileIcon);
        expect(t.widget<Text>(find.text(_labels[i])).style?.color, kLText);
      }
      // 方塊上只有名稱，沒有說明文字
      expect(find.byType(Text), findsNWidgets(4));

      // 右上角的個人中心還在
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('系統字級放大到 1.2 倍（App 的上限）照樣不溢出、名稱不折行', (t) async {
      t.platformDispatcher.textScaleFactorTestValue = 1.2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(t);
      expect(t.takeException(), isNull);
      for (var i = 0; i < 4; i++) {
        final label = find.text(_labels[i]);
        expect(t.widget<Text>(label).maxLines, 1);
        expect(
          t.getCenter(label).dx,
          moreOrLessEquals(t.getRect(_sq(i)).center.dx, epsilon: 0.01),
        );
      }
    });

    testWidgets('iPhone SE（375×667）放得下：不溢出、logo 完整、方塊貼底', (t) async {
      _phone(t, 375, 667);
      await _pump(t);
      expect(t.takeException(), isNull, reason: 'SE 上溢出了');

      final logo = t.getRect(find.byType(Image));
      expect(logo.width, kHomeLogoSize.width);
      expect(logo.height, kHomeLogoSize.height);
      // logo 在標題列（狀態列 20＋56）底下、方塊上面
      expect(logo.top, greaterThan(76));
      final sq = t.getRect(_sq(0));
      expect(logo.bottom, lessThan(sq.top));
      // 那一排貼底（底部留白 20）
      final last = t.getRect(find.text(_labels[3]));
      expect(last.bottom, moreOrLessEquals(667 - 20, epsilon: 1));
      expect(
        last.bottom - sq.top,
        moreOrLessEquals(_tilesH(t, 375), epsilon: 1),
      );
    });

    testWidgets('更矮的畫面：logo 等比縮小、方塊那一排不動、不溢出', (t) async {
      // 狀態列 20＋標題列 56＋底部留白 20，剩 184 給 logo＋方塊（約 97）
      _phone(t, 375, 280);
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
      final sq = t.getRect(_sq(0));
      expect(logo.bottom <= sq.top, isTrue);
      final last = t.getRect(find.text(_labels[3]));
      expect(last.bottom, moreOrLessEquals(280 - 20, epsilon: 1));
    });

    testWidgets('連方塊都放不下（150 高）：logo 不畫、自己捲、不溢出', (t) async {
      // 狀態列 20＋標題列 56＋底部留白 20，剩 54 < 方塊那一排
      _phone(t, 844, 150);
      await _pump(t);
      expect(t.takeException(), isNull, reason: '矮畫面溢出了');
      expect(find.byType(Image), findsNothing, reason: '放不下就不該硬擠 logo');
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      for (final l in _labels) {
        expect(find.text(l), findsOneWidget);
      }
      expect(t.takeException(), isNull);
    });
  });

  group('每一顆走的路', () {
    testWidgets('浮水印：先問照片還是影片；選照片 → 照片選取器 → 兩張問串成影片還是各自上浮水印', (t) async {
      _images.next = [
        XFile(_p('a.png'), name: 'a.png'),
        XFile(_p('b.png'), name: 'b.png'),
      ];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('浮水印'));
      await _settle(t);

      // 先問一句：照片還是影片
      expect(find.text('要上浮水印的是'), findsOneWidget);
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

    testWidgets('浮水印：選影片 → 影片選取器，非影片檔濾掉，兩支問接成一支還是各自上浮水印', (t) async {
      // 選取器照理只列影片，但 web／舊安卓那條路可能混進照片，首頁要自己濾
      _files.next = [_p('a.mp4'), _p('c.png'), _p('b.mp4')];
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('浮水印'));
      await _settle(t);
      await t.tap(find.text('影片'));
      await _settle(t);

      expect(_files.calls, 1, reason: '沒有開影片選取器');
      expect(_files.lastType, FileType.video, reason: '相簿只能列影片');
      expect(_files.lastMultiple, isTrue);
      expect(_images.calls, 0, reason: '開錯了（照片那個選取器）');
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
        reason: '照片要被濾掉、影片照點選順序',
      );
      // 選完才講的提醒：被略過的檔案交給批次頁進場後顯示
      expect(page.initialHint, '已略過 1 個非影片檔案');
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('剪輯：不開選取器，直接開一條空的時間軸', (t) async {
      final spy = _RouteSpy();
      await _pump(t, spy: spy);
      await t.tap(find.text('剪輯'));
      await _settle(t, 20);

      expect(_images.calls + _files.calls, 0, reason: '剪輯不該先開選取器');
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
      // 浮水印 → 照片：回空清單＝取消
      await t.tap(find.text('浮水印'));
      await _settle(t);
      await t.tap(find.text('照片'));
      await _settle(t);
      // GIF → 影片選取器：回 null＝取消
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
      expect(find.text('要上浮水印的是'), findsNothing, reason: '選取器開著時「浮水印」不該再跳問題');

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
