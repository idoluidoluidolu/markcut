// 用到才下載的模型（ModelStore）：
//   1. 下載、逐檔驗 SHA-256、搬到正式位置、寫 ok 記號；下次直接回路徑
//   2. 雜湊不對：不留壞檔、丟例外
//   3. 中斷後續傳：帶 Range 從斷的地方接，雜湊照樣對
//   4. 取消：丟 ModelCancelled，收一半的留著
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:markcut/services/model_store.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.files, {this.cutAfter, this.hang = false});

  final Map<String, Uint8List> files;

  /// 只送前幾個位元組就斷（模擬斷線）
  final int? cutAfter;
  final bool hang;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final name = request.url.pathSegments.last;
    final data = files[name]!;
    var start = 0;
    var code = 200;
    final range = request.headers['Range'];
    if (range != null) {
      start = int.parse(range.substring(6, range.length - 1));
      code = 206;
    }
    final body = data.sublist(start);
    final ctrl = StreamController<List<int>>();
    if (hang) {
      ctrl.add(body.sublist(0, 4));
      // 不送完、不關
    } else if (cutAfter != null) {
      ctrl.add(body.sublist(0, cutAfter!));
      unawaited(ctrl.close().then((_) {}));
    } else {
      for (var i = 0; i < body.length; i += 7) {
        ctrl.add(body.sublist(i, i + 7 > body.length ? body.length : i + 7));
      }
      unawaited(ctrl.close());
    }
    return http.StreamedResponse(ctrl.stream, code);
  }
}

class _Fake416 extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream<List<int>>.fromIterable(const []), 416);
}

String _sha(List<int> b) => crypto.sha256.convert(b).toString();

void main() {
  late Directory dir;
  final a = Uint8List.fromList(utf8.encode('第一個模型檔的內容' * 5));
  final b = Uint8List.fromList(List.generate(100, (i) => i * 7 % 256));
  late ModelPack pack;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('markcut_models_');
    ModelStore.instance.baseDir = () async => dir;
    pack = ModelPack(
      id: 'p1',
      tag: 't1',
      entry: 'pkg',
      files: [
        ModelFile(asset: 'a.bin', rel: 'pkg/Data/a.bin', bytes: a.length, sha256: _sha(a)),
        ModelFile(asset: 'b.bin', rel: 'pkg/b.bin', bytes: b.length, sha256: _sha(b)),
      ],
    );
  });
  tearDown(() async {
    ModelStore.instance.client = http.Client.new;
    await dir.delete(recursive: true);
  });

  test('下載、驗證、搬好、寫記號；再要一次直接回路徑', () async {
    final fake = _FakeClient({'a.bin': a, 'b.bin': b});
    ModelStore.instance.client = () => fake;
    final progress = <double>[];
    final p = await ModelStore.instance.ensure(pack, onProgress: progress.add);
    expect(p, '${dir.path}/p1/pkg');
    expect(File('${dir.path}/p1/pkg/Data/a.bin').readAsBytesSync(), a);
    expect(File('${dir.path}/p1/pkg/b.bin').readAsBytesSync(), b);
    expect(progress.last, 1.0);
    expect(fake.requests.map((r) => r.url.toString()), [
      'https://github.com/idoluidoluidolu/markcut-models/releases/download/t1/a.bin',
      'https://github.com/idoluidoluidolu/markcut-models/releases/download/t1/b.bin',
    ]);
    expect(await ModelStore.instance.readyPath(pack), p);
    fake.requests.clear();
    expect(await ModelStore.instance.ensure(pack), p);
    expect(fake.requests, isEmpty, reason: '已經有了不再連網');
  });

  test('雜湊不對：不留壞檔、丟例外、不算下載好', () async {
    final bad = Uint8List.fromList(List.of(b)..[3] ^= 1);
    ModelStore.instance.client = () => _FakeClient({'a.bin': a, 'b.bin': bad});
    await expectLater(ModelStore.instance.ensure(pack), throwsA(isA<HttpException>()));
    expect(File('${dir.path}/p1/.part/b.bin').existsSync(), isFalse);
    expect(await ModelStore.instance.readyPath(pack), isNull);
  });

  test('中斷後續傳：帶 Range 接著下，雜湊照樣對', () async {
    // 第一趟：a 下完、b 只收到 30 個位元組就斷（長度不對 → 驗證失敗，但留著）
    ModelStore.instance.client = () => _FakeClient({'a.bin': a, 'b.bin': b}, cutAfter: 30);
    await expectLater(ModelStore.instance.ensure(pack), throwsA(anything));
    // 長度不對的那一份會被當壞檔刪掉；這裡改成模擬「收到一半 App 被關」：手動放半個檔
    final part = File('${dir.path}/p1/.part/b.bin')..createSync(recursive: true);
    part.writeAsBytesSync(b.sublist(0, 40));
    final fake = _FakeClient({'a.bin': a, 'b.bin': b});
    ModelStore.instance.client = () => fake;
    final p = await ModelStore.instance.ensure(pack);
    expect(File('$p/b.bin').readAsBytesSync(), b);
    final rangeReq = fake.requests.where((r) => r.url.pathSegments.last == 'b.bin').single;
    expect(rangeReq.headers['Range'], 'bytes=40-');
  });

  test('上一趟收滿了還沒搬：本機驗過就好，不再連網；壞的刪掉重下', () async {
    final part = File('${dir.path}/p1/.part/b.bin')..createSync(recursive: true);
    part.writeAsBytesSync(b);
    final fake = _FakeClient({'a.bin': a, 'b.bin': b});
    ModelStore.instance.client = () => fake;
    final p = await ModelStore.instance.ensure(pack);
    expect(File('$p/b.bin').readAsBytesSync(), b);
    expect(fake.requests.map((r) => r.url.pathSegments.last), ['a.bin']);
  });

  test('伺服器回 416：暫存檔刪掉（下次從頭），不會每次都卡在 416', () async {
    final part = File('${dir.path}/p1/.part/a.bin')..createSync(recursive: true);
    part.writeAsBytesSync(a.sublist(0, 5));
    ModelStore.instance.client = () => _Fake416();
    await expectLater(ModelStore.instance.ensure(pack), throwsA(isA<HttpException>()));
    expect(part.existsSync(), isFalse);
  });

  test('取消：丟 ModelCancelled，收一半的留著', () async {
    ModelStore.instance.client = () => _FakeClient({'a.bin': a, 'b.bin': b}, hang: true);
    final f = ModelStore.instance.ensure(pack);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    ModelStore.instance.cancel();
    await expectLater(f, throwsA(isA<ModelCancelled>()));
    expect(File('${dir.path}/p1/.part/a.bin').existsSync(), isTrue);
    expect(await ModelStore.instance.readyPath(pack), isNull);
  });
}
