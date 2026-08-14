import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 診斷工具箱。
///
/// 這支 App 最難查的三種問題，共同點都是「現場什麼都沒留下」：
///
/// 一、匯出閃退。被 iOS 的 jetsam 收掉不會有當機報告、不會有 log，
///     使用者只看到 App 消失。所以要有黑盒子：每個危險步驟開始前先把
///     「我正在做什麼、當下吃多少記憶體」寫進檔案，正常結束就擦掉。
///     下次開 App 如果檔案還在，就知道上次死在哪一步、死的時候多大。
///
/// 二、記憶體。手機上完全看不到，只能靠猜。這裡跟系統要真正的數字：
///     iOS 用 phys_footprint（jetsam 判定用的就是它）＋ 還剩多少額度，
///     Android 用 totalPss。
///
/// 三、「LAG」「不順」。描述沒辦法比較，要有數字：掉了幾格、最久一格
///     多久。
///
/// 全部都是本機的，不打網路、不自己上傳；使用者從診斷畫面複製給我
class Diag {
  Diag._();

  static const _ch = MethodChannel('markcut/diag');

  /// 這次執行看到過的最大記憶體（MB）
  static int peakMb = 0;

  /// 最近一次讀到的記憶體與剩餘額度（MB）
  static int lastMb = 0;
  static int lastFreeMb = 0;

  static final Map<String, int> _counts = {};
  static final List<String> _notes = [];
  static Timer? _sampler;

  /// 上次執行沒有正常結束時留下的現場（開 App 時讀一次）
  static String? crumbFromLastRun;

  // ===== 記憶體 =====

  /// 目前的記憶體用量（MB）。拿不到回 null（web、原生沒接上）
  static Future<int?> memoryMb() async {
    if (kIsWeb) return null;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('memory');
      if (m == null) return null;
      final used = (m['usedMb'] as num?)?.round() ?? 0;
      final free = (m['freeMb'] as num?)?.round() ?? 0;
      lastMb = used;
      lastFreeMb = free;
      if (used > peakMb) peakMb = used;
      return used;
    } catch (_) {
      return null;
    }
  }

  /// 開始定期取樣（匯出、播放這種會吃記憶體的時候開）
  static void startSampling({Duration every = const Duration(seconds: 2)}) {
    _sampler?.cancel();
    _sampler = Timer.periodic(every, (_) => memoryMb());
    unawaited(memoryMb());
  }

  static void stopSampling() {
    _sampler?.cancel();
    _sampler = null;
  }

  // ===== 黑盒子 =====

  static Future<File?> _crumbFile() async {
    if (kIsWeb) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}last_run.json');
    } catch (_) {
      return null;
    }
  }

  /// 記下「我正在做什麼」。危險步驟開始前呼叫，正常做完呼叫 [clearMark]
  static Future<void> mark(String stage, {Map<String, Object?>? data}) async {
    if (kIsWeb) return;
    final mb = await memoryMb();
    try {
      final f = await _crumbFile();
      await f?.writeAsString(
        jsonEncode({
          'stage': stage,
          'at': DateTime.now().toIso8601String(),
          'usedMb': mb ?? lastMb,
          'freeMb': lastFreeMb,
          'peakMb': peakMb,
          ...?data,
        }),
      );
    } catch (_) {}
  }

  /// 做完了，把現場擦掉——留著的話下次開 App 會被當成上次死在這裡
  static Future<void> clearMark() async {
    if (kIsWeb) return;
    try {
      final f = await _crumbFile();
      if (f != null && f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// 開 App 時讀一次：上次有沒有做到一半就消失
  static Future<void> loadLastRun() async {
    if (kIsWeb) return;
    try {
      final f = await _crumbFile();
      if (f == null || !f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final stage = j['stage'] ?? '?';
      final used = j['usedMb'] ?? 0;
      final free = j['freeMb'] ?? 0;
      final extra = <String>[];
      j.forEach((k, v) {
        if (!const {'stage', 'at', 'usedMb', 'freeMb', 'peakMb'}.contains(k)) {
          extra.add('$k=$v');
        }
      });
      crumbFromLastRun =
          '上次執行沒有正常結束\n'
          '  停在：$stage${extra.isEmpty ? '' : '（${extra.join('、')}）'}\n'
          '  當下記憶體：$used MB（系統還剩 $free MB）\n'
          '  時間：${j['at']}';
      await f.delete();
    } catch (_) {}
  }

  /// 上次是不是死在匯出（給編輯器進場時提醒用）
  static bool get lastRunDiedExporting =>
      crumbFromLastRun?.contains('匯出') ?? false;

  // ===== 計數與備註 =====

  static void count(String key, [int n = 1]) {
    _counts[key] = (_counts[key] ?? 0) + n;
  }

  /// 一句話的事實（工作檔轉好了、退到軟體編碼器了…）。最多留 40 條
  static void note(String msg) {
    _notes.add('${DateTime.now().toIso8601String().substring(11, 19)}  $msg');
    if (_notes.length > 40) _notes.removeAt(0);
  }

  static void reset() {
    _counts.clear();
    _notes.clear();
    peakMb = 0;
  }

  static String report() {
    final b = StringBuffer()..writeln('=== 診斷 ===');
    b.writeln('平台：${defaultTargetPlatform.name}${kIsWeb ? ' (web)' : ''}');
    if (lastMb > 0) {
      b.writeln('記憶體：現在 $lastMb MB／峰值 $peakMb MB／系統還剩 $lastFreeMb MB');
    } else {
      b.writeln('記憶體：讀不到（原生通道沒接上）');
    }
    if (crumbFromLastRun != null) {
      b.writeln('--- 上次執行 ---');
      b.writeln(crumbFromLastRun);
    }
    if (_counts.isNotEmpty) {
      b.writeln('--- 計數 ---');
      _counts.forEach((k, v) => b.writeln('  $k：$v'));
    }
    if (_notes.isNotEmpty) {
      b.writeln('--- 過程 ---');
      for (final n in _notes) {
        b.writeln('  $n');
      }
    }
    return b.toString();
  }
}
