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
  /// 只擋「合成真的做不到」的：倒轉（播放器沒辦法倒著播）、同一時刻
  /// 疊兩層畫面（子母畫面）、工作檔還沒好。變速、淡入淡出、縮放位移
  /// AVFoundation 原生就支援，都烘進合成裡
  static String? whyNot(TimelineModel tl) {
    final vids = [
      for (final c in tl.clips)
        if (tl.sourceOf(c).isVideo) c,
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    if (vids.isEmpty) return '沒有影片片段';
    // 不看軌道，只看「時間上有沒有重疊」（下面那個迴圈）：分在不同軌
    // 但前後接著播的話，畫面結果跟同一軌完全一樣——真正做不到的是
    // 「同一時刻要疊兩層畫面」
    for (final c in vids) {
      if (c.reverse) return '有倒轉的片段';
      if (tl.sourceOf(c).workPath == null) return '有素材還沒轉好工作檔';
    }
    for (var i = 1; i < vids.length; i++) {
      if (vids[i].offset < vids[i - 1].end - 0.001) {
        return '同一時刻有兩層畫面（子母畫面）';
      }
    }
    return null;
  }

  /// 用時間軸組一份合成。組不起來（平台不支援、素材有問題）回 null
  /// [texture] 畫面要不要另外送一份到 Flutter 材質。用系統影片圖層
  /// 顯示時給 false：那份材質沒有人看，卻是每一格複製一張 4K 畫面
  static Future<CompPlayer?> build(TimelineModel tl, {bool texture = true}) async {
    if (!await available) return null;
    final vids = [
      for (final c in tl.clips)
        if (tl.sourceOf(c).isVideo) c,
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    if (vids.isEmpty) return null;
    final clips = <Map<String, dynamic>>[];
    var cursor = 0.0;
    for (final c in vids) {
      clips.add({
        // 一律用工作檔：轉正過、SDR、H.264，一條軌接得起來
        'path': tl.sourceOf(c).previewPath,
        'start': c.trimStart,
        'end': c.trimEnd,
        'gap': (c.offset - cursor).clamp(0.0, 1e6),
        'volume': c.volume.clamp(0.0, 1.0),
        'speed': c.speed,
        'fadeIn': c.fadeIn,
        'fadeOut': c.fadeOut,
        'scale': c.scale,
        'px': c.px,
        'py': c.py,
      });
      cursor = c.end;
    }
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('build', {
        'clips': clips,
        'texture': texture,
      });
      if (m == null) return null;
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
      b.write('狀態 ${m['timeControl'] ?? '?'}');
      if (m['waiting'] != null) b.write('（在等：${m['waiting']}）');
      if (m['bufferEmpty'] == true) b.write('／緩衝空的');
      if (m['likelyToKeepUp'] == false) b.write('／可能跟不上');
      final dropped = (m['dropped'] as num?)?.toInt();
      if (dropped != null) b.write('／系統記的掉格 $dropped');
      final stalls = (m['stalls'] as num?)?.toInt();
      if (stalls != null) b.write('／卡頓 $stalls 次');
      final n = (m['seekCount'] as num?)?.toInt();
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
