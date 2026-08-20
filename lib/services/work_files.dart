import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics.dart';
import 'frame_check.dart';
import 'media_prep.dart';
import 'native_frames.dart';

/// 素材的工作檔管理：一份素材轉一次，之後整支 App 都用轉好的那份。
///
/// 索引存在 SharedPreferences（原檔路徑 → 工作檔路徑＋原檔的大小與時間）。
/// 比對大小與修改時間是為了「同一個路徑換了內容」的情況——相簿的暫存檔
/// 路徑會重複使用，只看路徑會拿到別支影片的工作檔。
///
/// 工作檔放在 Application Support 底下而不是暫存目錄：暫存目錄系統隨時
/// 可以清，清在專案編輯到一半就等於素材憑空消失。這裡自己管清理
class WorkFiles {
  // 改版號＝舊工作檔全部重轉。不改的話舊快取一直被拿來用，測起來像是
  // 沒修好。v2 是加了「密關鍵幀」重編；v3 是那一道順便把方向燒進畫面
  //（保留旋轉旗標的檔會讓合成播放器被迫掛上合成器逐格重畫）；
  // v4 是亮度驗證上線後把舊快取裡可能轉壞的（螢幕錄影那批）全數作廢
  static const _key = 'workFiles.v4';

  /// 總量上限：超過就從最舊的開始清。1080p H.264 大約 5MB/分鐘，
  /// 1.5GB 夠放五個小時的素材
  static const _maxTotalBytes = 1500 * 1024 * 1024;

  static Map<String, dynamic>? _index;

  /// 正在寫的工作檔。清理時一定要跳過——同時轉兩支時，先做完的那支
  /// 會順手 sweep，而還在寫的那支還沒進索引，就被當成孤兒刪掉。
  /// 檔案被抽走的當下 writer 會回 -11819（CannotComplete），
  /// 或是留下一個沒有視訊軌的殘檔
  static final Set<String> _inFlight = {};

  /// 產生一個不會撞號的工作檔名。微秒時間戳在同一瞬間開兩支時會一樣
  static int _seq = 0;

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
    final name = 'w${DateTime.now().microsecondsSinceEpoch}_${_seq++}.mp4';
    final dest = '${dir.path}${Platform.pathSeparator}$name';
    final sw = Stopwatch()..start();
    await Diag.mark('工作檔：轉檔中', data: {'檔案': src.split('/').last});
    _inFlight.add(dest);
    String? made;
    try {
      made = await MediaPrep.toWorkFile(
        src,
        dest,
        maxShortSide: maxShortSide,
        onProgress: onProgress,
      );
    } finally {
      _inFlight.remove(dest);
    }
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
    // 轉出來的檔要先驗過才敢用。
    //
    // Pixel 上的螢幕錄影（1080x2410）踩到這個坑：短邊本來就是 1080，
    // 轉檔等於原尺寸重編一次，而 2410 不是 16 的倍數——硬體編碼器
    // 「成功」產出一個播起來全黑的檔。Transformer 回報成功、檔案也在，
    // 只有真的去解一格才看得出來。
    // 驗不過就當轉檔失敗，退回原檔（那條路本來就有）
    if (!await _looksUsable(src, made)) {
      Diag.note('工作檔畫面壞掉，退回原檔：${src.split('/').last}');
      Diag.count('工作檔壞掉');
      try {
        File(made).deleteSync();
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

  /// 這份工作檔畫得出東西嗎。
  ///
  /// 抽兩格算亮度，跟原檔同一個時間點比：原檔看得見、工作檔卻是全黑
  /// （或根本解不開）＝編碼器吐了壞檔。
  /// 只有在原檔本身夠亮的時候才判定——真的很暗的素材不能誤殺
  static Future<bool> _looksUsable(String src, String work) async {
    try {
      var srcMax = 0.0;
      var workMax = 0.0;
      var workReadable = false;
      for (final t in const [0.5, 2.0]) {
        final sb = await nativeFrameAt(src, t, maxH: 120);
        if (sb != null) {
          final v = await meanLuminance(sb);
          if (v != null && v > srcMax) srcMax = v;
        }
        final wb = await nativeFrameAt(work, t, maxH: 120);
        if (wb != null) {
          final v = await meanLuminance(wb);
          if (v != null) {
            workReadable = true;
            if (v > workMax) workMax = v;
          }
        }
      }
      // 原檔也抽不到（權限、格式怪）＝沒有基準可比，不要亂判，放行
      if (srcMax <= 0) return true;
      if (!workReadable) return false; // 工作檔連一格都解不開
      // 原檔看得見、工作檔幾乎全黑
      if (srcMax > 8 && workMax < 2) return false;
      return true;
    } catch (_) {
      return true; // 驗不動就放行，寧可維持原本的行為
    }
  }

  /// 清掉用不到的工作檔：原檔已經不見的、索引對不上的、超過總量的。
  /// 每次轉完一支就順手跑一次，不用另外找時機
  static Future<void> sweep() async {
    if (kIsWeb) return;
    // 還有人在轉就先不清。跳過 in-flight 已經夠安全，但轉檔期間本來就
    // 不缺這一次清理，等全部做完再一次清最單純
    if (_inFlight.isNotEmpty) return;
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

      // 目錄裡沒被索引指到的檔案＝上次轉到一半就被關掉的，直接清。
      // 但正在寫的那些不能碰——它們還沒進索引
      for (final f in dir.listSync().whereType<File>()) {
        if (_inFlight.contains(f.path)) continue;
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
