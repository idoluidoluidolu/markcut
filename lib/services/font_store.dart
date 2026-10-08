import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:http/http.dart' as http;

import '../models/watermark_settings.dart';
import 'font_files.dart';

/// markcut-fonts 的哪一個 commit。網址釘死在這一版：那邊之後換檔、
/// 加字型都不會動到已經發出去的 App
const kFontRepoCommit = '5234324a3d7cf282a15a70b90112b5bb60c7037c';

/// 依序試：jsDelivr（CDN）→ GitHub 原始檔。兩邊都有 CORS，Web 版也抓得到
List<String> fontUrls(DownloadFont f) => [
  'https://cdn.jsdelivr.net/gh/idoluidoluidolu/markcut-fonts@$kFontRepoCommit/${f.file}',
  'https://raw.githubusercontent.com/idoluidoluidolu/markcut-fonts/$kFontRepoCommit/${f.file}',
];

/// 點了才下載的字型（[kDownloadFonts]）：下載、存檔、執行中載入。
///
/// - 只在用到時才載入：選字型、打開用了那款字型的範本／草稿、匯出前。
///   字型載進去就一直佔著記憶體（Flutter 卸不掉），全部先載好最多四十幾 MB
/// - 載好一款 [loaded] 加一：畫字的快取、預覽烘圖、封面的指紋都帶著它，
///   原本用後備字（思源黑）畫的那幾張會重畫
/// - 沒叫過 [init]（widget 測試不跑 main）就不碰檔案也不連網：假時間裡
///   真的 I/O 永遠等不到回來，見 BlobStore 同一條規矩
class FontStore {
  FontStore._();

  static final FontStore instance = FontStore._();

  /// 每載好一款字型加一
  final ValueNotifier<int> loaded = ValueNotifier(0);
  int get epoch => loaded.value;

  /// 下載中的字型與進度（0～1）
  final ValueNotifier<Map<String, double>> downloading = ValueNotifier(
    const {},
  );

  final Set<String> _ready = {};
  final Map<String, Future<bool>> _inFlight = {};

  /// 每一趟 _inFlight 的「手機裡有沒有」那一段：讀到檔＝true、沒有＝false。
  /// 只讀本機的呼叫等這一段就好，不跟著等網路
  final Map<String, Future<bool>> _localPhase = {};

  /// 上次下載失敗的時間（沒網路、檔案壞掉）
  final Map<String, DateTime> _failedAt = {};

  /// 上次確認「手機裡沒有這個檔」的時間
  final Map<String, DateTime> _localMissAt = {};
  Future<String?>? _dir;
  bool _network = false;
  Map<String, DownloadFont> _catalog = kDownloadFonts;
  http.Client Function() _client = http.Client.new;
  Future<void> Function(String family, Uint8List bytes) _load = _loadIntoEngine;

  /// 自動重試的間隔：預覽每重畫一次就問一次，沒網路時不能每次都去連。
  /// 使用者自己點（[ensure] 的 force）不受這個限制
  static const _retryAfter = Duration(seconds: 30);

  /// 「手機裡沒有」記多久：只讀本機的呼叫（畫圖前）不用每次都翻檔案
  static const _localRecheck = Duration(seconds: 5);
  static const _connectTimeout = Duration(seconds: 15);

  /// 收資料中途停住多久算斷線
  static const _stallTimeout = Duration(seconds: 20);

  /// 開 App 時叫一次（main.dart）：定下存檔目錄、清掉舊版的字型檔
  static Future<void> init() async {
    final s = instance;
    s._network = true;
    s._dir ??= () async {
      try {
        return await fontDirPath();
      } catch (_) {
        return null;
      }
    }();
    final dir = await s._dir;
    if (dir != null) {
      await pruneFontFiles(dir, {
        for (final e in kDownloadFonts.entries) _fileName(e.key, e.value),
      });
    }
  }

  static String _fileName(String family, DownloadFont f) =>
      '$family-${f.sha256.substring(0, 12)}.ttf';

  bool isDownloadable(String family) => _catalog.containsKey(family);

  /// 現在畫得出來（內建的一律是）
  bool isReady(String family) =>
      !isDownloadable(family) || _ready.contains(family);

  /// 下載進度（0～1）；沒在下載回 null
  double? progressOf(String family) => downloading.value[family];

  /// 確保這款字型能畫：已載入就好；手機裡有檔就讀進來；都沒有而且
  /// [download] 就下載。[force]＝使用者點的：不管上次失敗是多久前。
  /// 回 false＝現在畫不出來（沒網路、下載壞掉），會用後備字畫。
  /// 只讀本機的呼叫（[download] false，畫圖前）不等正在下載的那一趟：
  /// 預覽烘圖不能卡在網路上，字型到了 [loaded] 會讓它重烘
  Future<bool> ensure(
    String family, {
    bool download = true,
    bool force = false,
  }) async {
    if (isReady(family)) return true;
    final spec = _catalog[family];
    if (spec == null) return true;
    final running = _inFlight[family];
    if (running != null) {
      // 只讀本機：等那一趟看完手機裡有沒有就好（沒有就是沒有，它接著
      // 下載是它的事）
      if (!download) return _localPhase[family]!;
      final ok = await running;
      // 前一趟只看了手機裡有沒有：這一趟要下載的話接著做
      if (ok || isReady(family)) return isReady(family);
      final again = _inFlight[family];
      if (again != null) return again;
    }
    if (!force && _recentlyFailed(family, download: download)) return false;
    final local = Completer<bool>();
    final op = _ensure(family, spec, download: download, local: local);
    _inFlight[family] = op;
    _localPhase[family] = local.future;
    try {
      return await op;
    } finally {
      if (identical(_inFlight[family], op)) {
        _inFlight.remove(family);
        _localPhase.remove(family);
      }
    }
  }

  /// [ensure] 一整組；回傳畫不出來的那幾款
  Future<Set<String>> ensureAll(
    Iterable<String> families, {
    bool download = true,
    bool force = false,
  }) async {
    final need = {
      for (final f in families)
        if (!isReady(f)) f,
    };
    if (need.isEmpty) return const {};
    final failed = await Future.wait([
      for (final f in need)
        ensure(
          f,
          download: download,
          force: force,
        ).then((ok) => ok ? null : f),
    ]);
    return {for (final f in failed) ?f};
  }

  bool _recentlyFailed(String family, {required bool download}) {
    final now = DateTime.now();
    final failed = _failedAt[family];
    if (download && failed != null && now.difference(failed) < _retryAfter) {
      return true;
    }
    final miss = _localMissAt[family];
    return !download && miss != null && now.difference(miss) < _localRecheck;
  }

  Future<bool> _ensure(
    String family,
    DownloadFont spec, {
    required bool download,
    required Completer<bool> local,
  }) async {
    try {
      final dir = await _dir;
      final name = _fileName(family, spec);
      if (dir != null) {
        final bytes = await readFontFile(dir, name, spec.bytes);
        if (bytes != null) {
          await _register(family, bytes);
          local.complete(true);
          return true;
        }
      }
      _localMissAt[family] = DateTime.now();
      local.complete(false);
      if (!download || !_network) return false;
      final bytes = await _fetch(family, spec);
      if (bytes == null) {
        _failedAt[family] = DateTime.now();
        return false;
      }
      _failedAt.remove(family);
      if (dir != null) {
        try {
          await writeFontFile(dir, name, bytes);
          _localMissAt.remove(family);
        } catch (_) {
          // 存不進去（空間滿了）：這次照樣用，下次開 App 再下載
        }
      }
      await _register(family, bytes);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!local.isCompleted) local.complete(isReady(family));
    }
  }

  Future<void> _register(String family, Uint8List bytes) async {
    await _load(family, bytes);
    _ready.add(family);
    loaded.value++;
  }

  static Future<void> _loadIntoEngine(String family, Uint8List bytes) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    return loader.load();
  }

  Future<Uint8List?> _fetch(String family, DownloadFont spec) async {
    _setProgress(family, 0);
    try {
      for (final url in fontUrls(spec)) {
        final client = _client();
        try {
          final res = await client
              .send(http.Request('GET', Uri.parse(url)))
              .timeout(_connectTimeout);
          if (res.statusCode != 200) continue;
          final out = BytesBuilder(copy: false);
          await _drain(res.stream, (chunk) {
            out.add(chunk);
            _setProgress(family, out.length / spec.bytes);
            return out.length <= spec.bytes; // 比清單上的大＝不是這個檔
          });
          final bytes = out.takeBytes();
          if (bytes.length != spec.bytes) continue;
          // 十幾 MB 算雜湊要一兩百毫秒，丟背景不卡畫面（小檔不值得開執行緒）
          final hash = bytes.length > (1 << 20)
              ? await compute(_sha256Hex, bytes)
              : _sha256Hex(bytes);
          if (hash != spec.sha256) continue;
          return bytes;
        } catch (_) {
          continue; // 換下一個網址
        } finally {
          client.close();
        }
      }
      return null;
    } finally {
      _clearProgress(family);
    }
  }

  /// 一段一段收；[_stallTimeout] 沒有新資料就算斷線（丟 TimeoutException）。
  /// [onChunk] 回 false＝不收了。不用 Stream.timeout：widget 測試的假時間
  /// 裡它送不出結尾，下載永遠停在 100%
  static Future<void> _drain(
    Stream<List<int>> stream,
    bool Function(List<int> chunk) onChunk,
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
        finish(TimeoutException('字型下載停住了', _stallTimeout));
      });
    }

    sub = stream.listen(
      (chunk) {
        arm();
        if (!onChunk(chunk)) {
          unawaited(sub.cancel());
          finish();
        }
      },
      onError: (Object e) => finish(e),
      onDone: finish,
      cancelOnError: true,
    );
    arm();
    return done.future;
  }

  void _setProgress(String family, double p) {
    final v = p.clamp(0.0, 1.0);
    final cur = downloading.value[family];
    // 每 1% 才通知一次：每個網路封包都重畫選單沒必要
    if (cur != null && v - cur < 0.01 && v < 1) return;
    downloading.value = {...downloading.value, family: v};
  }

  void _clearProgress(String family) {
    if (!downloading.value.containsKey(family)) return;
    downloading.value = {...downloading.value}..remove(family);
  }

  /// 測試用：換掉存檔目錄、網路、載入字型的方式、字型清單，清掉所有狀態
  @visibleForTesting
  void debugReset({
    String? dir,
    http.Client Function()? client,
    Future<void> Function(String family, Uint8List bytes)? load,
    Map<String, DownloadFont>? catalog,
  }) {
    _catalog = catalog ?? kDownloadFonts;
    _ready.clear();
    _inFlight.clear();
    _localPhase.clear();
    _failedAt.clear();
    _localMissAt.clear();
    _dir = dir == null ? null : Future.value(dir);
    _network = client != null;
    _client = client ?? http.Client.new;
    _load = load ?? _loadIntoEngine;
    downloading.value = const {};
  }
}

String _sha256Hex(Uint8List bytes) => crypto.sha256.convert(bytes).toString();
