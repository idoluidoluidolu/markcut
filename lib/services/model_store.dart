import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 模型 Release 所在的 repo（公開；檔案放 Release，單檔可以超過 100MB）
const kModelRepo = 'idoluidoluidolu/markcut-models';

/// 一個要下載的檔：Release 上的檔名、存到 pack 資料夾底下的相對路徑、大小、
/// SHA-256（Release 的檔可以被換掉，所以一定驗）
class ModelFile {
  const ModelFile({
    required this.asset,
    required this.rel,
    required this.bytes,
    required this.sha256,
  });

  final String asset;
  final String rel;
  final int bytes;
  final String sha256;
}

/// 一組一起用的模型檔
class ModelPack {
  const ModelPack({
    required this.id,
    required this.tag,
    required this.entry,
    required this.files,
  });

  /// 本機資料夾名
  final String id;

  /// Release 的 tag
  final String tag;

  /// 交給原生端的路徑（相對 pack 資料夾）：iOS 是 .mlpackage 資料夾、
  /// Android 是 .onnx 檔
  final String entry;
  final List<ModelFile> files;

  int get totalBytes => files.fold(0, (n, f) => n + f.bytes);
}

String modelUrl(ModelPack p, ModelFile f) =>
    'https://github.com/$kModelRepo/releases/download/${p.tag}/${f.asset}';

/// 照片精修（BiRefNet-lite，MIT）：iOS 17+ 用 Core ML（三個檔還原成 mlpackage）
const kBiRefNetCoreML = ModelPack(
  id: 'birefnet-lite-v1-coreml',
  tag: 'birefnet-lite-v1',
  entry: 'BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage',
  files: [
    ModelFile(
      asset: 'birefnet_coreml_Manifest.json',
      rel: 'BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage/Manifest.json',
      bytes: 617,
      sha256:
          'c39212792a938d5cf424d40a3159b9dc18900ba03ae2d44f5f3791c172358c78',
    ),
    ModelFile(
      asset: 'birefnet_coreml_model.mlmodel',
      rel:
          'BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage/Data/com.apple.CoreML/model.mlmodel',
      bytes: 3287769,
      sha256:
          '7652ec19a5eb62217a2428be416c2bce5103a249afd203d397638e03f1b8a58c',
    ),
    ModelFile(
      asset: 'birefnet_coreml_weight.bin',
      rel:
          'BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage/Data/com.apple.CoreML/weights/weight.bin',
      bytes: 92087344,
      sha256:
          'db2e2a429f5b0f20d2d65f95bfd9517648a977aa73da71e4eaf0a95175312565',
    ),
  ],
);

/// 照片精修：Android 用 ONNX Runtime（fp16 權重、輸入輸出 fp32）
const kBiRefNetOnnx = ModelPack(
  id: 'birefnet-lite-v1-onnx',
  tag: 'birefnet-lite-v1',
  entry: 'birefnet_lite_1024_fp16.onnx',
  files: [
    ModelFile(
      asset: 'birefnet_lite_1024_fp16.onnx',
      rel: 'birefnet_lite_1024_fp16.onnx',
      bytes: 114538221,
      sha256:
          'd39b897ceb16ae654c1731f3dba0cf9b368d9cae74b5a57459b455cc8bfec402',
    ),
  ],
);

/// 使用者按了取消（不是失敗）
class ModelCancelled implements Exception {
  const ModelCancelled();
}

/// 用到才下載的大型模型：串流寫進 `.part` 檔、邊收邊算 SHA-256，中斷了下次
/// 從斷的地方接（Range）；全部驗過才搬到正式位置、寫一個 `ok` 記號（之後
/// 不用每次重算一百多 MB 的雜湊）。同時只下載一組
class ModelStore {
  ModelStore._();

  static final ModelStore instance = ModelStore._();

  @visibleForTesting
  http.Client Function() client = http.Client.new;

  @visibleForTesting
  Future<Directory> Function() baseDir = () async =>
      Directory('${(await getApplicationSupportDirectory()).path}/models');

  static const _stallTimeout = Duration(seconds: 30);

  http.Client? _active;
  bool _cancelled = false;
  Completer<void>? _abort;

  Future<Directory> _dirOf(ModelPack p) async =>
      Directory('${(await baseDir()).path}/${p.id}');

  /// 已經下載好就回原生端要的路徑，不然 null
  Future<String?> readyPath(ModelPack p) async {
    final dir = await _dirOf(p);
    final ok = File('${dir.path}/ok');
    if (!ok.existsSync()) return null;
    if (ok.readAsStringSync() != _signature(p)) return null;
    for (final f in p.files) {
      final file = File('${dir.path}/${f.rel}');
      if (!file.existsSync() || file.lengthSync() != f.bytes) return null;
    }
    return '${dir.path}/${p.entry}';
  }

  /// 確保下載好；回原生端要的路徑。取消丟 [ModelCancelled]，網路、檔案壞掉
  /// 丟一般例外（下次再試會從斷的地方接）。[onProgress]＝0~1
  Future<String> ensure(
    ModelPack p, {
    void Function(double progress)? onProgress,
  }) async {
    final ready = await readyPath(p);
    if (ready != null) return ready;
    _cancelled = false;
    _abort = Completer<void>();
    final dir = await _dirOf(p);
    final part = Directory('${dir.path}/.part');
    part.createSync(recursive: true);
    var done = 0;
    final total = p.totalBytes;
    try {
      for (final f in p.files) {
        final target = File('${dir.path}/${f.rel}');
        if (target.existsSync() && target.lengthSync() == f.bytes) {
          // 上一趟這個檔已經驗過、搬好了（只差別的檔沒下完）
          done += f.bytes;
          onProgress?.call(done / total);
          continue;
        }
        final tmp = File('${part.path}/${f.asset}');
        await _fetch(p, f, tmp, (got) => onProgress?.call((done + got) / total));
        target.parent.createSync(recursive: true);
        if (target.existsSync()) target.deleteSync();
        tmp.renameSync(target.path);
        done += f.bytes;
        onProgress?.call(done / total);
      }
      File('${dir.path}/ok').writeAsStringSync(_signature(p));
      try {
        part.deleteSync(recursive: true);
      } catch (_) {}
      return '${dir.path}/${p.entry}';
    } finally {
      _active = null;
    }
  }

  /// 取消正在下載的那一組（收到一半的 .part 留著，下次接著下）
  void cancel() {
    _cancelled = true;
    final a = _abort;
    if (a != null && !a.isCompleted) a.complete();
    _active?.close();
  }

  static String _signature(ModelPack p) =>
      [for (final f in p.files) '${f.rel}:${f.bytes}:${f.sha256}'].join('\n');

  Future<void> _fetch(
    ModelPack p,
    ModelFile f,
    File tmp,
    void Function(int got) progress,
  ) async {
    if (_cancelled) throw const ModelCancelled();
    var have = tmp.existsSync() ? tmp.lengthSync() : 0;
    if (have > f.bytes) {
      tmp.deleteSync();
      have = 0;
    }
    if (have == f.bytes) {
      // 上一趟收滿了、還沒搬（剛好那時候取消或 App 被關）：本機驗一次就好，
      // 不然再要 Range: bytes=全長- 伺服器只會回 416
      if (await _hashFile(tmp) == f.sha256) {
        progress(have);
        return;
      }
      tmp.deleteSync();
      have = 0;
    }
    final c = client();
    _active = c;
    try {
      final req = http.Request('GET', Uri.parse(modelUrl(p, f)));
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final res = await c.send(req);
      if (_cancelled) throw const ModelCancelled();
      if (res.statusCode == 416) {
        // 範圍不對（手上那段跟伺服器的檔對不上）：丟掉，下次從頭
        unawaited(res.stream.drain<void>().catchError((_) {}));
        try {
          tmp.deleteSync();
        } catch (_) {}
        throw HttpException('下載 ${f.asset} 要重來（HTTP 416）');
      }
      if (res.statusCode == 200) {
        have = 0; // 伺服器不給續傳：從頭來
      } else if (res.statusCode != 206) {
        throw HttpException('下載 ${f.asset} 失敗：HTTP ${res.statusCode}');
      }
      // 雜湊：續傳的話先把手上那一段讀進去
      final digest = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digest);
      if (have > 0) {
        await for (final chunk in tmp.openRead(0, have)) {
          hasher.add(chunk);
        }
      }
      final out = tmp.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      try {
        await _drain(res.stream, (chunk) {
          got += chunk.length;
          if (got > f.bytes) throw HttpException('${f.asset} 比預期大');
          out.writeFromSync(chunk);
          hasher.add(chunk);
          progress(got);
        });
      } on HttpException {
        out.closeSync();
        // 比預期大＝不是這個檔：不留
        try {
          tmp.deleteSync();
        } catch (_) {}
        rethrow;
      } finally {
        try {
          out.closeSync();
        } catch (_) {}
      }
      if (_cancelled) throw const ModelCancelled();
      hasher.close();
      if (got != f.bytes || digest.value.toString() != f.sha256) {
        // 壞掉的不留（下次從頭）
        try {
          tmp.deleteSync();
        } catch (_) {}
        throw HttpException('${f.asset} 驗證失敗');
      }
    } on http.ClientException {
      if (_cancelled) throw const ModelCancelled();
      rethrow;
    } finally {
      c.close();
    }
  }

  static Future<String> _hashFile(File f) async {
    final digest = _DigestSink();
    final hasher = crypto.sha256.startChunkedConversion(digest);
    await for (final chunk in f.openRead()) {
      hasher.add(chunk);
    }
    hasher.close();
    return digest.value.toString();
  }

  /// 一段一段收；[_stallTimeout] 沒有新資料算斷線；取消馬上停
  Future<void> _drain(
    Stream<List<int>> stream,
    void Function(List<int> chunk) onChunk,
  ) {
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    Timer? stall;
    void finish([Object? error]) {
      stall?.cancel();
      if (done.isCompleted) return;
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error);
      }
    }

    void arm() {
      stall?.cancel();
      stall = Timer(_stallTimeout, () {
        unawaited(sub.cancel());
        finish(TimeoutException('模型下載停住了', _stallTimeout));
      });
    }

    sub = stream.listen(
      (chunk) {
        arm();
        try {
          onChunk(chunk);
        } catch (e) {
          unawaited(sub.cancel());
          finish(e);
        }
      },
      onError: (Object e) => finish(e),
      onDone: finish,
      cancelOnError: true,
    );
    arm();
    unawaited(
      _abort?.future.then((_) {
        unawaited(sub.cancel());
        finish(const ModelCancelled());
      }),
    );
    return done.future;
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? _value;
  crypto.Digest get value => _value!;

  @override
  void add(crypto.Digest data) => _value = data;

  @override
  void close() {}
}
