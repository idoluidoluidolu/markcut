import 'dart:async';

import '../models/timeline.dart';

/// 播放中，背景轉檔（預覽工作檔／代理）要不要讓路。
///
/// iOS 要：那邊的讓路只是放慢（原生 MCInteractivePrepGate 每格等 30ms），
/// 進度留著；原檔本來就由系統播放器順順地播。
///
/// Android 不要。那邊的轉檔器（media3 Transformer）停不下也放不慢，讓路＝
/// 整支作廢、閒置後從頭重轉；而 Android 的原檔是 ExoPlayer 經 Flutter
/// 貼圖播的（4K 解碼，貼圖又不照影格時間戳送格），要順只能靠 1080p
/// 工作檔換 mpv 播。播放中把轉檔丟掉＝這一輪、下一輪都只能播原檔
///（實機 1.1.0+2232：轉到一半按播放，整輪都在播 4K 原檔、佇列卡在 1）。
/// 手指碰畫面（拖曳、滑桿、捏合）跟匯出照舊讓路
bool previewPrepYieldsToPlayback({required bool android}) => !android;

/// 相機錄的標準尺寸（直式橫式都算）：短邊 480～4320、長邊 640～7680 的
/// 常見規格，例如 2160x3840、1080x1920、720x1280。
///
/// Android 的原檔只有這種才交給 mpv 播（第一次播放就順，不用等工作檔）。
/// 螢幕錄影那類怪尺寸（1080x2410、1440x3200…）mpv 硬解會解成破圖然後
/// 全黑，而且有畫面出來、第一格檢查驗不到（23602ff 的實機回報），照舊
/// 給系統解碼器
bool isCameraVideoSize(int w, int h) {
  final short = w < h ? w : h;
  final long = w < h ? h : w;
  const shorts = {480, 540, 720, 1080, 1440, 2160, 2880, 4320};
  const longs = {640, 854, 960, 1280, 1920, 2560, 3840, 5120, 7680};
  return shorts.contains(short) && longs.contains(long);
}

/// Reorder preparation jobs, never the user's clips or source list. The video
/// at the playhead gets the first decoder turn; other visible short jobs then
/// complete before a long background clip can monopolize the encoder.
List<int> prioritizePreviewPreparation({
  required TimelineModel timeline,
  required Iterable<int> pending,
  required double position,
  Set<int> hiddenTracks = const {},
}) {
  final jobs = pending
      .where((i) => i >= 0 && i < timeline.sources.length)
      .where((i) => timeline.sources[i].isVideo)
      .toSet()
      .toList();
  final top = timeline.videoAt(position, skipTracks: hiddenTracks);
  final scores = <int, ({int tier, double distance, double cost})>{};
  for (final i in jobs) {
    var tier = 3;
    var distance = double.infinity;
    for (final clip in timeline.clips) {
      if (clip.sourceIndex != i || hiddenTracks.contains(clip.track)) continue;
      if (clip.coversForDisplay(position)) {
        tier = top?.sourceIndex == i ? 0 : 1;
        distance = 0;
        break;
      }
      tier = 2;
      final gap = position < clip.offset
          ? clip.offset - position
          : position - clip.end;
      if (gap < distance) distance = gap;
    }
    final duration = timeline.sources[i].duration;
    scores[i] = (
      tier: tier,
      distance: distance,
      cost: duration.isFinite && duration > 0 ? duration : double.infinity,
    );
  }
  jobs.sort((a, b) {
    final x = scores[a]!, y = scores[b]!;
    final tier = x.tier.compareTo(y.tier);
    if (tier != 0) return tier;
    final distance = x.distance.compareTo(y.distance);
    if (distance != 0) return distance;
    final cost = x.cost.compareTo(y.cost);
    return cost != 0 ? cost : a.compareTo(b);
  });
  return jobs;
}

/// Yield immediately to interaction, but resume only after a stable idle
/// interval. Repeated idle notifications do not postpone the same timer.
class PreviewPreparationActivity {
  PreviewPreparationActivity({
    required this.onChanged,
    this.idleDelay = const Duration(milliseconds: 600),
  });

  final void Function(bool interactive) onChanged;
  final Duration idleDelay;
  Timer? _resume;
  bool _interactive = false;
  bool _disposed = false;

  bool get interactive => _interactive;

  void update(bool interactive) {
    if (_disposed) return;
    if (interactive) {
      _resume?.cancel();
      _resume = null;
      if (!_interactive) {
        _interactive = true;
        onChanged(true);
      }
    } else if (_interactive && _resume == null) {
      _resume = Timer(idleDelay, () {
        _resume = null;
        _interactive = false;
        onChanged(false);
      });
    }
  }

  void dispose() {
    _disposed = true;
    _resume?.cancel();
    _resume = null;
    if (_interactive) {
      _interactive = false;
      onChanged(false);
    }
  }
}
