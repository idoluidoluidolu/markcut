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

  static Future<bool> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return await sp.setString(_key, jsonEncode(_index ?? {}));
    } catch (_) {
      return false;
    }
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
    // 色彩版本：v2 起 HDR 素材的工作檔改走 CI 色調映射（跟成品同一條
    // 曲線）。舊版轉出來的 HDR 工作檔顏色是另一套，繼續用等於預覽跟
    // 成品永遠對不上——淘汰重轉。SDR 素材兩版沒差，照用
    if ((e['cv'] as int? ?? 1) < 2) {
      final lite = await MediaPrep.probeLite(src);
      final sdr = lite == null || lite['error'] != null
          ? false // 判不出來當 HDR：重轉一次換正確顏色，成本可接受
          : lite['sdr709'] == true;
      if (!sdr) return null;
      // SDR：補記版本，下次不用再探測
      e['cv'] = 2;
      unawaited(_save());
    }
    return work;
  }

  /// HDR 代理（HLG 直通、密關鍵幀）。HDR 預覽模式播它——
  /// SDR 工作檔在那個模式下永遠比成品淡，原檔又是 4K 解起來重。
  /// 索引 key 用「原檔路徑#hdr3」，跟 SDR 工作檔各記各的。
  /// #hdr（v106）那一批像素是內建合成器轉壞的（標 HLG 裝 SDR），
  /// 換 key 整批作廢，舊檔變孤兒由 sweep 清掉
  static Future<String?> lookupHdr(String src) async {
    if (kIsWeb) return null;
    final idx = await _load();
    final e = idx['$src#hdr3'];
    if (e is! Map) return null;
    final work = e['work'] as String?;
    if (work == null || !File(work).existsSync()) return null;
    final stamp = _stamp(src);
    if (stamp != null && e['stamp'] != null && e['stamp'] != stamp) return null;
    return work;
  }

  /// 確保這支 HDR 素材有 HDR 代理。SDR 素材回 null（不需要）；
  /// 轉不出來也回 null，呼叫端照播原檔
  static Future<String?> ensureHdr(
    String src, {
    void Function(double progress)? onProgress,
  }) async {
    if (kIsWeb) return null;
    final have = await lookupHdr(src);
    if (have != null) return have;
    if (!await MediaPrep.available) return null;
    final lite = await MediaPrep.probeLite(src);
    if (lite == null || lite['error'] != null || lite['sdr709'] == true) {
      return null; // SDR（或判不出來）：不做 HDR 代理
    }
    final dir = await _dir();
    final name = 'wh${DateTime.now().microsecondsSinceEpoch}_${_seq++}.mp4';
    final dest = '${dir.path}${Platform.pathSeparator}$name';
    _inFlight.add(dest);
    String? made;
    try {
      made = await MediaPrep.toWorkFile(
        src,
        dest,
        hdr: true,
        onProgress: onProgress,
      );
    } finally {
      _inFlight.remove(dest);
    }
    if (made == null) return null;
    final idx = await _load();
    idx['$src#hdr3'] = {
      'work': made,
      'stamp': _stamp(src),
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    await _save();
    Diag.note(
      'HDR 代理完成 ${(File(made).lengthSync() / 1048576).round()}MB（HLG 直通）',
    );
    unawaited(sweep());
    return made;
  }

  /// 草稿裡記的工作檔還能不能用。
  ///
  /// 草稿存的是路徑本人，載入時若直接沿用，等於繞過 [lookup] 的
  /// 版本檢查——HDR 代理換了色調映射曲線（cv2）之後，舊專案就是
  /// 這樣一直播著舊曲線的代理、預覽跟成品對不上。
  /// 索引裡有這筆＝交給 lookup（含 stamp 與 cv 檢查）。
  /// 索引沒有＝作廢重轉。以前這裡有條「探測來源，SDR 就照用」的
  /// 後備，但它自打兩槍：版本跳號本來就是要作廢舊檔，後備把 SDR
  /// 的舊檔全放行、繞過作廢；而且放行的檔不在新索引裡，使用者一
  /// 匯入新素材（空索引保險絲失效），sweep 就把草稿還在用的檔
  /// 當孤兒刪掉——編輯到一半縮圖全掛。重轉一次是正確的代價
  static Future<bool> stillValid(String src, String work) async {
    if (kIsWeb) return true;
    return await lookup(src) == work;
  }

  /// 作廢一支壞掉的工作檔（索引移除＋檔案刪掉）。
  /// 硬體編碼器被打掛（mediaserverd 重置）的窗口裡會吐出「只有
  /// 聲音、沒有視訊軌」的殘廢檔，卻照樣回報成功——實測就是它
  /// 讓合成長度變 0、播放跳針卡死。呼叫端驗出來就送來這裡
  static Future<void> invalidate(String src) async {
    if (kIsWeb) return;
    try {
      final idx = await _load();
      final e = idx[src];
      final work = (e is Map) ? e['work'] as String? : null;
      if (idx.remove(src) != null) await _save();
      if (work != null) {
        final f = File(work);
        if (f.existsSync()) await f.delete();
      }
    } catch (_) {}
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

    // 快速通道：素材本來就符合工作檔規格（H.264 SDR、短邊 ≤1080、
    // 沒有旋轉旗標、關鍵幀夠密）就不重編碼，直接複製一份。
    // 複製只花磁碟 I/O 幾秒；重編碼要把整支影片跑一遍——「匯入素材
    // 太慢」大半是把已經合格的素材又原樣轉了一次。
    // 還是要複製、不能直接拿原檔當工作檔：原檔常是相簿給的暫存路徑
    //（一週左右會被系統回收），工作檔同時兼任素材的備份（見
    // _rescueFromWorkFile）
    if (await _qualifiesAsIs(src)) {
      try {
        _inFlight.add(dest);
        await File(src).copy(dest);
        onProgress?.call(1);
        final idx = await _load();
        idx[src] = {
          'work': dest,
          'stamp': _stamp(src),
          'cv': 2,
          'at': DateTime.now().millisecondsSinceEpoch,
        };
        // 索引寫成功才解除 in-flight 保護；沒寫成功就讓它掛著整個
        // 行程，sweep 才不會把這支當孤兒清掉（跟轉檔那條同一套）
        if (await _save()) {
          _inFlight.remove(dest);
        } else {
          Diag.note('工作檔索引寫入失敗（本次照用，先不給清掃碰）');
        }
        Diag.note(
          '工作檔免轉直用（規格已合，複製 '
          '${(File(dest).lengthSync() / 1048576).round()}MB）：'
          '${src.split('/').last}',
        );
        Diag.count('工作檔免轉');
        unawaited(sweep());
        return dest;
      } catch (_) {
        // 複製失敗（空間不足之類）就照舊走轉檔
        _inFlight.remove(dest);
        try {
          File(dest).deleteSync();
        } catch (_) {}
      }
    }
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
      'cv': 2,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    if (!await _save()) {
      // 索引沒寫成功：sweep 會把這支當孤兒刪掉。掛在 in-flight 名單
      // 讓它整個行程都不被清，檔案照用
      _inFlight.add(made);
      Diag.note('工作檔索引寫入失敗（本次照用，先不給清掃碰）');
    }
    unawaited(sweep());
    return made;
  }

  /// 素材本身是不是已經符合工作檔規格，可以免轉直接用。
  ///
  /// 條件全部要成立：
  /// - H.264（avc1）：HEVC 幾乎都伴隨 HDR/高解碼成本，照舊重轉。
  ///   這一條同時排掉了 iPhone 的 HDR 素材（HLG/PQ 都走 HEVC）
  /// - 短邊 ≤1088：跟工作檔的目標尺寸同級（1088 容忍編碼器取整）
  /// - 沒有旋轉旗標：帶旗標的檔會讓合成播放器被迫逐格重畫
  /// - SDR(709)：HDR 一定要轉，色調映射要交給系統做
  /// - 關鍵幀夠密（平均 ≤8 格、最疏 ≤16 格）：疏的話拖曳會鈍，
  ///   重轉的主要目的之一就是把關鍵幀補密
  ///
  /// probe 沒實作的平台（Android）回 false，照舊全部重轉
  static Future<bool> _qualifiesAsIs(String src) async {
    try {
      // 先用輕量探測快篩（只讀容器中繼資料）：編碼/尺寸/旋轉/HDR
      // 不合格的素材（4K、HEVC…）馬上出局，不用把整支檔掃一遍
      final lite = await MediaPrep.probeLite(src);
      if (lite == null || lite['error'] != null) return false;
      if (lite['codec'] != 'avc1') return false;
      final w = (lite['w'] as num?)?.toInt() ?? 0;
      final h = (lite['h'] as num?)?.toInt() ?? 0;
      if (w <= 0 || h <= 0 || (w < h ? w : h) > 1088) return false;
      if (lite['rotated'] == true) return false;
      if (lite['sdr709'] != true) return false;
      // 快篩過了才做貴的那一步：掃關鍵幀（要把整支檔讀過一遍）
      final m = await MediaPrep.probe(src);
      if (m == null || m['error'] != null) return false;
      final frames = (m['frames'] as num?)?.toInt() ?? 0;
      final keys = (m['keyframes'] as num?)?.toInt() ?? 0;
      final maxGop = (m['maxGopFrames'] as num?)?.toInt();
      if (keys <= 0 || frames <= 0) return false;
      if (frames / keys > 8) return false;
      if (maxGop == null || maxGop > 16) return false;
      return true;
    } catch (_) {
      return false;
    }
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

  /// 匯出期間整段暫停清掃：換進匯出來源的工作檔被背景清掉的話，
  /// 整場匯出用一段 FFmpeg log 收場。由匯出流程設／清
  static bool holdSweep = false;

  /// 清掉用不到的工作檔：原檔已經不見的、索引對不上的、超過總量的。
  /// 每次轉完一支就順手跑一次，不用另外找時機。
  /// 全程用 async 檔案操作——以前 listSync/deleteSync 對一目錄的
  /// 1080p 檔做同步 stat 與刪除，正好卡在匯入進度畫面在動的時候
  static Future<void> sweep() async {
    if (kIsWeb || holdSweep) return;
    // 還有人在轉就先不清。跳過 in-flight 已經夠安全，但轉檔期間本來就
    // 不缺這一次清理，等全部做完再一次清最單純
    if (_inFlight.isNotEmpty) return;
    try {
      final idx = await _load();
      // 保險絲：索引是空的（版本跳號、解析失敗）時什麼都不清。
      // 空索引＋照常清＝目錄裡所有工作檔被當孤兒整批刪光，
      // 其中包括「原檔已被系統回收、工作檔是唯一備份」的那些
      if (idx.isEmpty) return;
      final dir = await _dir();
      final alive = <String>{};
      final dead = <String>[];
      for (final entry in idx.entries) {
        final e = entry.value;
        if (e is! Map) {
          dead.add(entry.key);
          continue;
        }
        final work = e['work'] as String?;
        if (work == null || !await File(work).exists()) {
          dead.add(entry.key);
          continue;
        }
        // 原檔不見了（系統清掉相簿快取）：工作檔是唯一活著的備份，
        // 千萬不能連坐刪掉——草稿救回（_loadDraft 的升格）全靠它。
        // 索引留著，總量清理時它照樣排隊，但不會因為原檔死了就陪葬
        alive.add(work);
      }
      for (final k in dead) {
        idx.remove(k);
      }

      // 目錄裡沒被索引指到的檔案＝上次轉到一半就被關掉的，直接清。
      // 但正在寫的那些不能碰——它們還沒進索引
      await for (final f in dir.list()) {
        if (f is! File) continue;
        if (_inFlight.contains(f.path)) continue;
        if (!alive.contains(f.path)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }

      // 總量超標：從最舊的開始丟（正在寫的不碰）
      var total = 0;
      final entries = <({String src, String work, int at, int size})>[];
      for (final entry in idx.entries) {
        final e = entry.value as Map;
        final work = e['work'] as String;
        var size = 0;
        try {
          size = await File(work).length();
        } catch (_) {}
        total += size;
        entries.add((
          src: entry.key,
          work: work,
          at: (e['at'] ?? 0) as int,
          size: size,
        ));
      }
      if (total > _maxTotalBytes) {
        entries.sort((a, b) => a.at.compareTo(b.at));
        for (final e in entries) {
          if (total <= _maxTotalBytes) break;
          if (_inFlight.contains(e.work)) continue;
          try {
            await File(e.work).delete();
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
