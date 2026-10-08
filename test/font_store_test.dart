import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/font_files_io.dart' as files;
import 'package:markcut/services/font_store.dart';
import 'package:markcut/services/text_mark_painter.dart';
import 'package:markcut/widgets/font_picker.dart';
import 'package:markcut/widgets/watermark_layer.dart';

/// 假字型：內容隨便（載入換成假的），大小、雜湊對得上就好
Uint8List _bytes(int n, [int seed = 7]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

DownloadFont _spec(Uint8List b, String family) => DownloadFont(
  file: 'fonts/$family.ttf',
  bytes: b.length,
  sha256: sha256.convert(b).toString(),
  previewFamily: '${family}Label',
);

String _fileName(String family, DownloadFont f) =>
    '$family-${f.sha256.substring(0, 12)}.ttf';

const _cdn = 'cdn.jsdelivr.net';
const _raw = 'raw.githubusercontent.com';

void main() {
  final store = FontStore.instance;
  late List<String> loads;
  late List<Uri> requests;

  Future<void> fakeLoad(String family, Uint8List bytes) async =>
      loads.add(family);

  /// 照「主機／檔名」回檔；沒有就 404。檔案分 [chunk] 一段送
  http.Client Function() serve(
    Map<String, Uint8List> files, {
    int chunk = 1000,
    Future<void>? gate,
  }) => () => MockClient.streaming((req, _) async {
    requests.add(req.url);
    if (gate != null) await gate;
    final b =
        files['${req.url.host}/${req.url.pathSegments.last}'] ??
        files[req.url.pathSegments.last];
    if (b == null) return http.StreamedResponse(const Stream.empty(), 404);
    return http.StreamedResponse(
      Stream.fromIterable([
        for (var i = 0; i < b.length; i += chunk)
          b.sublist(i, math.min(i + chunk, b.length)),
      ]),
      200,
    );
  });

  setUp(() {
    loads = [];
    requests = [];
  });
  tearDown(() => store.debugReset());

  group('FontStore', () {
    test('內建字型一律可用，不連網', () async {
      store.debugReset(client: serve({}), load: fakeLoad);
      expect(store.isReady('NotoSansTC'), isTrue);
      expect(await store.ensure('NotoSansTC'), isTrue);
      expect(requests, isEmpty);
      expect(loads, isEmpty);
    });

    test('下載：分段收、回報進度、存檔、載入、版本號加一', () async {
      final dir = await Directory.systemTemp.createTemp('fonts');
      addTearDown(() => dir.delete(recursive: true));
      final b = _bytes(5000);
      final spec = _spec(b, 'PopGothic');
      store.debugReset(
        dir: dir.path,
        client: serve({'PopGothic.ttf': b}),
        load: fakeLoad,
        catalog: {'PopGothic': spec},
      );
      final seen = <double>[];
      void onProgress() {
        final p = store.downloading.value['PopGothic'];
        if (p != null) seen.add(p);
      }

      store.downloading.addListener(onProgress);
      addTearDown(() => store.downloading.removeListener(onProgress));
      final before = store.epoch;
      expect(store.isReady('PopGothic'), isFalse);

      expect(await store.ensure('PopGothic'), isTrue);

      expect(loads, ['PopGothic']);
      expect(store.isReady('PopGothic'), isTrue);
      expect(store.epoch, before + 1);
      expect(store.downloading.value, isEmpty);
      expect(seen.where((p) => p > 0 && p < 1), isNotEmpty);
      expect(requests.single.host, _cdn);
      final saved = File('${dir.path}/${_fileName('PopGothic', spec)}');
      expect(saved.readAsBytesSync(), b);
      // 已載入：再要一次什麼都不做
      expect(await store.ensure('PopGothic'), isTrue);
      expect(requests, hasLength(1));
      expect(loads, hasLength(1));
    });

    test('第一個網址給的檔不對（雜湊不合）→ 換第二個', () async {
      final good = _bytes(3000);
      final bad = _bytes(3000, 99);
      store.debugReset(
        client: serve({
          '$_cdn/PopGothic.ttf': bad,
          '$_raw/PopGothic.ttf': good,
        }),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(good, 'PopGothic')},
      );
      expect(await store.ensure('PopGothic'), isTrue);
      expect(requests.map((u) => u.host), [_cdn, _raw]);
      expect(loads, ['PopGothic']);
    });

    test('收到一半就斷（長度不對）不算', () async {
      final good = _bytes(3000);
      store.debugReset(
        client: serve({'PopGothic.ttf': good.sublist(0, 2000)}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(good, 'PopGothic')},
      );
      expect(await store.ensure('PopGothic'), isFalse);
      expect(loads, isEmpty);
      expect(store.isReady('PopGothic'), isFalse);
    });

    test('兩個網址都失敗：30 秒內自動要的不再連網，使用者點的照樣連', () async {
      final good = _bytes(3000);
      store.debugReset(
        client: serve({}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(good, 'PopGothic')},
      );
      expect(await store.ensure('PopGothic'), isFalse);
      expect(requests, hasLength(2));
      expect(store.downloading.value, isEmpty);
      expect(await store.ensure('PopGothic'), isFalse);
      expect(requests, hasLength(2), reason: '自動重試要等一陣子');
      expect(await store.ensure('PopGothic', force: true), isFalse);
      expect(requests, hasLength(4));
    });

    test('手機裡有檔：直接讀，不連網', () async {
      final dir = await Directory.systemTemp.createTemp('fonts');
      addTearDown(() => dir.delete(recursive: true));
      final b = _bytes(4000);
      final spec = _spec(b, 'Bakudai');
      await files.writeFontFile(dir.path, _fileName('Bakudai', spec), b);
      store.debugReset(
        dir: dir.path,
        client: serve({}),
        load: fakeLoad,
        catalog: {'Bakudai': spec},
      );
      expect(await store.ensure('Bakudai', download: false), isTrue);
      expect(loads, ['Bakudai']);
      expect(requests, isEmpty);
    });

    test('同時要同一款：只下載一次、只載一次', () async {
      final b = _bytes(3000);
      store.debugReset(
        client: serve({'PopGothic.ttf': b}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final r = await Future.wait([
        store.ensure('PopGothic'),
        store.ensure('PopGothic'),
        store.ensure('PopGothic', force: true),
      ]);
      expect(r, [true, true, true]);
      expect(requests, hasLength(1));
      expect(loads, ['PopGothic']);
    });

    test('只讀本機的呼叫（畫圖前）不等正在下載的那一趟', () async {
      final b = _bytes(3000);
      final gate = Completer<void>();
      store.debugReset(
        client: serve({'PopGothic.ttf': b}, gate: gate.future),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final download = store.ensure('PopGothic');
      await Future<void>.delayed(Duration.zero);
      expect(await store.ensure('PopGothic', download: false), isFalse);
      gate.complete();
      expect(await download, isTrue);
      expect(store.isReady('PopGothic'), isTrue);
    });

    test('那一趟還在讀手機裡的檔：只讀本機的呼叫等它讀完，不誤判成沒有', () async {
      final dir = await Directory.systemTemp.createTemp('fonts');
      addTearDown(() => dir.delete(recursive: true));
      final b = _bytes(4000);
      final spec = _spec(b, 'Bakudai');
      await files.writeFontFile(dir.path, _fileName('Bakudai', spec), b);
      store.debugReset(
        dir: dir.path,
        client: serve({}),
        load: fakeLoad,
        catalog: {'Bakudai': spec},
      );
      final both = await Future.wait([
        store.ensure('Bakudai'),
        store.ensure('Bakudai', download: false),
      ]);
      expect(both, [true, true]);
      expect(loads, ['Bakudai']);
      expect(requests, isEmpty);
    });

    test('ensureAll 回傳畫不出來的那幾款', () async {
      final a = _bytes(2000, 1);
      final c = _bytes(2000, 2);
      store.debugReset(
        client: serve({'PopGothic.ttf': a}),
        load: fakeLoad,
        catalog: {
          'PopGothic': _spec(a, 'PopGothic'),
          'Bakudai': _spec(c, 'Bakudai'),
        },
      );
      final missing = await store.ensureAll([
        'NotoSansTC',
        'PopGothic',
        'Bakudai',
      ]);
      expect(missing, {'Bakudai'});
      expect(loads, ['PopGothic']);
    });

    test('清掉清單以外的檔（舊版、寫到一半的）', () async {
      final dir = await Directory.systemTemp.createTemp('fonts');
      addTearDown(() => dir.delete(recursive: true));
      for (final n in ['keep.ttf', 'old.ttf', 'keep.ttf.part']) {
        File('${dir.path}/$n').writeAsStringSync('x');
      }
      await files.pruneFontFiles(dir.path, {'keep.ttf'});
      expect(
        dir.listSync().map((e) => e.uri.pathSegments.last).toList(),
        ['keep.ttf'],
      );
    });
  });

  group('畫面', () {
    testWidgets('字型選單：還沒下載的有下載圖示；點了下載完才換過去', (t) async {
      final b = _bytes(3000);
      store.debugReset(
        client: serve({'PopGothic.ttf': b}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final picked = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: FontDropdown(value: 'NotoSansTC', onChanged: picked.add),
            ),
          ),
        ),
      );
      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();
      // 清單裡只有這一款要下載（其他下載字型在這個測試裡當內建）
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      await t.tap(find.text('大波浪圓體').last);
      await t.pumpAndSettle();
      expect(picked, ['PopGothic']);
      expect(loads, ['PopGothic']);
      expect(t.takeException(), isNull);
    });

    testWidgets('字型選單：下載不了就留在原本的字型、跳提示', (t) async {
      final b = _bytes(3000);
      store.debugReset(
        client: serve({}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final picked = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: FontDropdown(value: 'NotoSansTC', onChanged: picked.add),
            ),
          ),
        ),
      );
      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('大波浪圓體').last);
      await t.pumpAndSettle();
      expect(picked, isEmpty);
      expect(find.textContaining('下載不了'), findsOneWidget);
      // 按鈕上回到原本的字型
      expect(
        t.widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'NotoSansTC',
      );
      await t.pump(const Duration(seconds: 5)); // 提示收掉
    });

    testWidgets('字型選單：下載中字型被別處換掉（套範本、上一步）：下載完不蓋掉', (t) async {
      final b = _bytes(3000);
      final gate = Completer<void>();
      store.debugReset(
        client: serve({'PopGothic.ttf': b}, gate: gate.future),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      var value = 'NotoSansTC';
      final picked = <String>[];
      late StateSetter setOuter;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuter = setState;
                  return FontDropdown(
                    value: value,
                    onChanged: (v) {
                      picked.add(v);
                      setState(() => value = v);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('大波浪圓體').last);
      await t.pump();
      // 下載還卡著，字型被套範本換成思源宋體
      setOuter(() => value = 'NotoSerifTC');
      await t.pump();
      gate.complete();
      await t.pumpAndSettle();
      expect(loads, ['PopGothic'], reason: '字型照樣下載好（下次點就快）');
      expect(picked, isEmpty, reason: '不能蓋掉別處剛換的字型');
      expect(
        t.widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'NotoSerifTC',
      );
    });

    testWidgets('範本縮圖（downloadFonts: false）：不偷偷下載', (t) async {
      final b = _bytes(3000);
      store.debugReset(
        client: serve({'PopGothic.ttf': b}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final s = WatermarkSettings();
      s.text
        ..text = '阿明'
        ..fontFamily = 'PopGothic';
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 200,
            height: 120,
            child: WatermarkLayer(
              settings: s,
              onChanged: () {},
              downloadFonts: false,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(requests, isEmpty);
      expect(loads, isEmpty);
    });

    testWidgets('預覽圖層：用到還沒下載的字型會自己去拿，到了就重畫', (t) async {
      final b = _bytes(3000);
      store.debugReset(
        client: serve({'PopGothic.ttf': b}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final s = WatermarkSettings();
      s.text
        ..text = '阿明'
        ..fontFamily = 'PopGothic';
      MarkGlyphPainter glyphPainter() => t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<MarkGlyphPainter>()
          .single;
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: WatermarkLayer(settings: s, onChanged: () {}),
          ),
        ),
      );
      final first = glyphPainter();
      await t.pumpAndSettle();
      expect(loads, ['PopGothic']);
      expect(requests, hasLength(1));
      final second = glyphPainter();
      expect(second.shouldRepaint(first), isTrue, reason: '字型到了要重畫');
      // 字型已經在了：之後重建不會再去拿
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: WatermarkLayer(settings: s, onChanged: () {}),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(requests, hasLength(1));
    });

    testWidgets('匯出前：下載不了就擋下來、說是哪一款', (t) async {
      final b = _bytes(3000);
      store.debugReset(
        client: serve({}),
        load: fakeLoad,
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      bool? result;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await ensureExportFonts(
                  context,
                  const {'NotoSansTC', 'PopGothic'},
                ),
                child: const Text('匯出'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('匯出'));
      await t.pumpAndSettle();
      expect(result, isFalse);
      expect(find.textContaining('大波浪圓體'), findsOneWidget);
      expect(find.textContaining('連上網路再匯出'), findsOneWidget);
      await t.pump(const Duration(seconds: 5)); // 提示收掉
    });

    testWidgets('匯出前：都是內建字型就不擋、不連網', (t) async {
      store.debugReset(client: serve({}), load: fakeLoad);
      bool? result;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await ensureExportFonts(
                  context,
                  const {'NotoSansTC', 'Cinzel', 'GreatVibes'},
                ),
                child: const Text('匯出'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('匯出'));
      await t.pumpAndSettle();
      expect(result, isTrue);
      expect(requests, isEmpty);
    });

    testWidgets('真的載進字型引擎：同一段字量出來換成新字型的寬度', (t) async {
      // 拿內建的 Great Vibes 當「下載來的檔」，掛在大波浪圓體的家族名上
      final b = File('assets/fonts/GreatVibes.ttf').readAsBytesSync();
      store.debugReset(
        client: serve({'PopGothic.ttf': b}),
        catalog: {'PopGothic': _spec(b, 'PopGothic')},
      );
      final mark = TextMark(text: 'Ming Photography', fontFamily: 'PopGothic');
      final before = measureMark(mark, 40).width;
      final ok = await t.runAsync(() => store.ensure('PopGothic'));
      expect(ok, isTrue);
      await t.pump();
      // 排版快取要在字型載好時清掉，不然還是後備字的寬度
      final after = measureMark(mark, 40).width;
      expect(after, isNot(closeTo(before, 0.5)));
    });
  });
}
