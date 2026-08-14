import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics.dart';
import 'media_prep.dart';

/// 素材的工作檔管理：一份素材轉一次，之後整支 App 都用轉好的那份。
///
/// 索引存在 SharedPreferences（原檔路徑 → 工作檔路徑＋原檔的大小與時間）。
/// 比對大小與修改時間是為了「同一個路徑換了內容」的情況——相簿的暫存檔
/// 路徑會重複使用，只看路徑會拿到別支影片的工作檔。
///
/// 工作檔放在 Application Support 底下而不是暫存目錄：暫存目錄系統隨時
/// 可以清，清在專案編輯到一半就等於素材憑空消失。這裡自己管清理
class WorkFiles {
  static const _key = 'workFiles.v1';

  /// 總量上限：超過就從最舊的開始清。1080p H.264 大約 5MB/分鐘，
  /// 1.5GB 夠放五個小時的素材
  static const _maxTotalBytes = 1500 * 1024 * 1024;

  static Map<String, dynamic>? _index;

  static Future<Map<String, dynamic>> _load() async {
    if (_index != null) return _index!;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      _index = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _index = <String, dynamic>{};
    }
    return _index!;
  }

  static Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode(_index ?? {}));
    } catch (_) {}
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}workfiles');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 原檔現在的「身分證」：大小＋修改時間。換了內容就對不上
  static String? _stamp(String src) {
    try {
      final f = File(src);
      final st = f.statSync();
      return '${st.size}_${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return null;
    }
  }

  /// 這支素材已經轉好的工作檔（沒有就回 null，不會去轉）
  static Future<String?> lookup(String src) async {
    if (kIsWeb) return null;
    final idx = await _load();
    final e = idx[src];
    if (e is! Map) return null;
    final work = e['work'] as String?;
    if (work == null || !File(work).existsSync()) return null;
    // 原檔換過內容就不能再用舊的工作檔
    final stamp = _stamp(src);
    if (stamp != null && e['stamp'] != null && e['stamp'] != stamp) return null;
    return work;
  }

  /// 確保這支素材有工作檔：已經有就直接回，沒有就轉一份。
  /// 轉不出來（平台不支援、格式怪、使用者取消）回 null，呼叫端用原檔
  static Future<String?> ensure(
    String src, {
    int maxShortSide = 1080,
    void Function(double progress)? onProgress,
  }) async {
    if (kIsWeb) return null;
    final have = await lookup(src);
    if (have != null) return have;
    if (!await MediaPrep.available) return null;

    final dir = await _dir();
    final name = 'w${DateTime.now().microsecondsSinceEpoch}.mp4';
    final dest = '${dir.path}${Platform.pathSeparator}$name';
    final sw = Stopwatch()..start();
    await Diag.mark('工作檔：轉檔中', data: {'檔案': src.split('/').last});
    final made = await MediaPrep.toWorkFile(
      src,
      dest,
      maxShortSide: maxShortSide,
      onProgress: onProgress,
    );
    await Diag.clearMark();
    Diag.note(
      made == null
          ? '工作檔失敗（用原檔）：${src.split('/').last}'
          : '工作檔完成 ${sw.elapsed.inSeconds}秒 '
                '${(File(made).lengthSync() / 1048576).round()}MB',
    );
    Diag.count(made == null ? '工作檔失敗' : '工作檔完成');
    if (made == null || !File(made).existsSync()) {
      try {
        File(dest).deleteSync();
      } catch (_) {}
      return null;
    }
    final idx = await _load();
    idx[src] = {
      'work': made,
      'stamp': _stamp(src),
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    await _save();
    unawaited(sweep());
    return made;
  }

  /// 清掉用不到的工作檔：原檔已經不見的、索引對不上的、超過總量的。
  /// 每次轉完一支就順手跑一次，不用另外找時機
  static Future<void> sweep() async {
    if (kIsWeb) return;
    try {
      final idx = await _load();
      final dir = await _dir();
      final alive = <String>{};
      final dead = <String>[];
      idx.forEach((src, e) {
        if (e is! Map) {
          dead.add(src);
          return;
        }
        final work = e['work'] as String?;
        if (work == null ||
            !File(work).existsSync() ||
            !File(src).existsSync()) {
          dead.add(src);
          if (work != null) {
            try {
              File(work).deleteSync();
            } catch (_) {}
          }
          return;
        }
        alive.add(work);
      });
      for (final k in dead) {
        idx.remove(k);
      }

      // 目錄裡沒被索引指到的檔案＝上次轉到一半就被關掉的，直接清
      for (final f in dir.listSync().whereType<File>()) {
        if (!alive.contains(f.path)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }

      // 總量超標：從最舊的開始丟
      var total = 0;
      final entries = <({String src, String work, int at, int size})>[];
      idx.forEach((src, e) {
        final work = (e as Map)['work'] as String;
        var size = 0;
        try {
          size = File(work).lengthSync();
        } catch (_) {}
        total += size;
        entries.add((
          src: src,
          work: work,
          at: (e['at'] ?? 0) as int,
          size: size,
        ));
      });
      if (total > _maxTotalBytes) {
        entries.sort((a, b) => a.at.compareTo(b.at));
        for (final e in entries) {
          if (total <= _maxTotalBytes) break;
          try {
            File(e.work).deleteSync();
          } catch (_) {}
          idx.remove(e.src);
          total -= e.size;
        }
      }
      await _save();
    } catch (_) {}
  }

  /// 這支素材的工作檔不要了（例如使用者把素材從專案移除）
  static Future<void> forget(String src) async {
    final idx = await _load();
    final e = idx.remove(src);
    if (e is Map && e['work'] is String) {
      try {
        File(e['work'] as String).deleteSync();
      } catch (_) {}
    }
    await _save();
  }
}
