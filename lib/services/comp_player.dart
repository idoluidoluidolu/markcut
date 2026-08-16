import 'package:flutter/services.dart';

import '../models/timeline.dart';

/// 合成播放器：整條時間軸交給系統的一顆播放器。
///
/// 原本是「一個片段一顆播放器」，由 App 自己的時鐘驅動、交界前預先開播
/// 下一顆再換手。實機量下來 Flutter 這條線完全乾淨（五千格只超時兩格）、
/// 散熱正常、對時成本 0.01ms，但影格就是會不定時落後——剩下唯一沒排除的
/// 變因是「同時養三顆 AVPlayer」，每顆都佔一組解碼與影格輸出資源。
///
/// AVComposition 正是為這件事存在的：一條時間軸、一顆播放器、一組解碼
/// 資源，片段交界由系統自己接（不會黑閃、不用預熱、不用對時校正）。
///
/// 目前只有 iOS 有原生實作；拿不到就回 null，呼叫端退回原本的多播放器路徑
class CompPlayer {
  CompPlayer._(this.textureId, this.duration, this.width, this.height);

  static const _ch = MethodChannel('markcut/comp');

  final int textureId;
  final double duration;
  final double width;
  final double height;

  double get aspect => (width <= 0 || height <= 0) ? 16 / 9 : width / height;

  static bool? _available;

  static Future<bool> get available async {
    if (_available != null) return _available!;
    try {
      _available = await _ch.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// 這條時間軸能不能交給合成播放器。
  ///
  /// 剩兩件做不到：
  /// - 倒轉：播放器沒辦法倒著播（那條路是先把片段做成「已經倒好的檔」）
  /// - 調色：畫面走系統的影片圖層，Flutter 的濾鏡疊不上去。舊路徑的
  ///   影格是畫在 Flutter 材質上的，濾鏡吃得到——所以有調色就退回去，
  ///   不然預覽看不到效果、匯出卻有，那比慢更糟
  ///
  /// 子母畫面本來也被擋掉，一上多軌就整組退回舊的「一片段一顆播放器」
  /// ——那正是「多軌之後變超 LAG」。AVFoundation 原生就支援多軌疊合，
  /// 一條時間軸軌道對一條合成軌，逐段的 layer instruction 決定每一刻
  /// 誰在上面。變速、淡入淡出、縮放位移也一樣烘進合成裡。
  ///
  /// 工作檔沒好也照組——用原檔組一樣播得動，而且是一顆播放器一組解碼
  /// 資源，比舊路徑輕得多
  static String? whyNot(TimelineModel tl) {
    final vids = [
      for (final c in tl.clips)
        if (tl.sourceOf(c).isVideo) c,
    ];
    if (vids.isEmpty) return '沒有影片片段';
    for (final c in vids) {
      if (c.reverse) return '有倒轉的片段';
      if (c.color.hasColor) return '有調色的片段';
    }
    return null;
  }

  /// 用時間軸組一份合成。組不起來（平台不支援、素材有問題）回 null
  /// [texture] 畫面要不要另外送一份到 Flutter 材質。用系統影片圖層
  /// 顯示時給 false：那份材質沒有人看，卻是每一格複製一張 4K 畫面
  /// 上一次組不起來的原因（原生端回報的）。呼叫端拿去寫進診斷
  static String? lastError;

  static Future<CompPlayer?> build(TimelineModel tl, {bool texture = true}) async {
    if (!await available) return null;
    final vids = [
      for (final c in tl.clips)
        if (tl.sourceOf(c).isVideo) c,
    ]..sort((a, b) {
      final t = a.offset.compareTo(b.offset);
      return t != 0 ? t : a.track.compareTo(b.track);
    });
    if (vids.isEmpty) return null;
    final clips = [
      for (final c in vids)
        {
          // 一律用工作檔：轉正過、SDR、H.264，一條軌接得起來
          'path': tl.sourceOf(c).previewPath,
          'start': c.trimStart,
          'end': c.trimEnd,
          // 絕對時間＋軌道編號：原生端一條軌道開一條合成軌，
          // 疊起來的順序就是使用者看到的上下層
          'offset': c.offset,
          'track': c.track,
          'volume': c.volume.clamp(0.0, 1.0),
          'speed': c.speed,
          'fadeIn': c.fadeIn,
          'fadeOut': c.fadeOut,
          'scale': c.scale,
          'px': c.px,
          'py': c.py,
        },
    ];
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('build', {
        'clips': clips,
        'texture': texture,
      });
      if (m == null) return null;
      // 原生端組不起來時會回原因，不要讓它只變成一句「組不起來」
      final err = m['error'];
      if (err is String) {
        lastError = err;
        return null;
      }
      lastError = null;
      return CompPlayer._(
        (m['textureId'] as num).toInt(),
        (m['duration'] as num).toDouble(),
        (m['width'] as num?)?.toDouble() ?? 0,
        (m['height'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 回「按下那一刻播放器在忙什麼」（診斷用；原生端拿不到就 null）
  Future<String?> play() async {
    try {
      return await _ch.invokeMethod<String>('play');
    } catch (_) {
      return null;
    }
  }
  Future<void> pause() => _quiet('pause');
  Future<void> setRate(double r) => _quiet('rate', r);
  /// [exact] 只有「停手要對準那一格」時才給 true。拖曳中與按下播放前
  /// 一律寬容——精準 seek 跑完之前播放器的 rate 會被壓在 0
  Future<void> seek(double seconds, {bool exact = false}) =>
      _quiet('seek', {'sec': seconds, 'exact': exact});
  Future<void> dispose() => _quiet('dispose');

  /// 目前位置（秒）。合成播放器是唯一的時鐘來源——App 不再自己算時間，
  /// 也就不會有「時鐘跟畫面對不上」這回事
  Future<double> position() async {
    try {
      final ms = await _ch.invokeMethod<int>('position');
      return (ms ?? 0) / 1000.0;
    } catch (_) {
      return 0;
    }
  }

  /// 材質實際更新的間隔統計。30fps 的素材理想是每 33ms 換一張；
  /// 出現 60、80、100 就是 judder——每一格都準時畫，但畫的是同一張。
  /// Flutter 端的所有指標都看不到這件事，眼睛卻很敏感
  Future<String> gaps() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('gaps');
      final n = (m?['count'] as num?)?.toInt() ?? 0;
      if (n == 0) return '沒有取樣到';
      final avg = (m!['avgMs'] as num).toDouble();
      final max = (m['maxMs'] as num).toInt();
      final over = (m['over2x'] as num).toInt();
      return '換圖 $n 次／平均 ${avg.toStringAsFixed(1)}ms'
          '／最久 ${max}ms／超過兩格 $over 次';
    } catch (_) {
      return '讀不到';
    }
  }

  /// 播放器自己回報的狀況：seek 成本、掉格、卡頓、在等什麼。
  /// 這幾個數字 Flutter 端一個都量不到
  Future<String> health() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('health');
      if (m == null || m.isEmpty) return '讀不到';
      final b = StringBuffer();
      // 有沒有掛合成器＝這條時間軸是「硬體解碼直送螢幕」還是
      // 「每一格都進合成管線重畫一張」。原檔一匯入順不順就看這裡
      b.write(
        m['usesVC'] == true
            ? '合成器 開（每格重畫 ${m['renderW']}x${m['renderH']}）'
            : '合成器 關（硬體直送，跟相簿同一條路）',
      );
      // 軌數、指令數、以及「這一刻抽得到畫面嗎」。畫面黑掉時這一行
      // 直接分得出是合成壞了還是圖層沒畫
      if (m['vTracks'] != null) {
        b.write(
          '／${m['vTracks']} 條畫面軌、${m['aTracks']} 條聲音軌'
          '、${m['instructions']} 段指令'
          '、長 ${(m['compDur'] as num?)?.toStringAsFixed(1)}s',
        );
      }
      if (m['frameProbe'] != null) {
        b.write('\n  抽格檢查：${m['frameProbe']}');
      }
      b.write('／狀態 ${m['timeControl'] ?? '?'}');
      if (m['waiting'] != null) b.write('（在等：${m['waiting']}）');
      if (m['bufferEmpty'] == true) b.write('／緩衝空的');
      if (m['likelyToKeepUp'] == false) b.write('／可能跟不上');
      final dropped = (m['dropped'] as num?)?.toInt();
      if (dropped != null) b.write('／系統記的掉格 $dropped');
      final stalls = (m['stalls'] as num?)?.toInt();
      if (stalls != null) b.write('／卡頓 $stalls 次');
      final n = (m['seekCount'] as num?)?.toInt();
      // 按下播放那兩百毫秒的內部拆解：播放器什麼時候真的開始跑、
      // 什麼時候畫面才動、中間在等什麼。三個時間點分開之後，
      // 「播放器沒開始」跟「開始了但畫面沒更新」一眼就分得出來
      final bd = m['playBreakdown'];
      if (bd is Map) {
        b.write(
          '\n  按下播放：${[
            if (bd['rateMs'] != null) 'rate 起來 ${bd['rateMs']}ms',
            if (bd['playingMs'] != null) '系統說在播 ${bd['playingMs']}ms',
            if (bd['movedMs'] != null)
              '時間真的前進 ${bd['movedMs']}ms'
            else
              '時間一直沒前進',
            if (bd['waiting'] != null) '等待理由 ${bd['waiting']}',
          ].join('／')}',
        );
      }
      if (n != null) {
        b.write(
          '\n  拖曳 seek：$n 發／平均 ${m['seekAvgMs']}ms'
          '／一半在 ${m['seekP50Ms']}ms 內／九成在 ${m['seekP90Ms']}ms 內'
          '／最久 ${m['seekMaxMs']}ms／被合併掉 ${m['seekCoalesced']} 發',
        );
      }
      return b.toString();
    } catch (_) {
      return '讀不到';
    }
  }

  Future<void> _quiet(String method, [Object? arg]) async {
    try {
      await _ch.invokeMethod(method, arg);
    } catch (_) {}
  }
}
