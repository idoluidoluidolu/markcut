import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import 'player_value.dart';

/// 手機版播放控制器＝media_kit（libmpv）。
/// video_player 在 Pixel 等機型上影格傳遞卡頓（裸播放器實測也卡），
/// media_kit 實測順，所以裝置端整個換掉；介面模仿 video_player，
/// 編輯器程式碼不用改邏輯。
class PlayerX {
  PlayerX(this.path);

  final String path;
  final mk.Player _p = mk.Player();
  late final mkv.VideoController _vc = mkv.VideoController(_p);

  bool _inited = false;
  Size _size = Size.zero;
  Duration _duration = Duration.zero;

  Future<void> initialize() async {
    await _p.open(mk.Media(path), play: false);

    // 重要：先看 state 快照、再等串流。
    // 值可能在訂閱前就到了，只等串流會逾時 → 尺寸變 0 →
    // 比例退回 16:9 預設，直式影片就會被拉成橫的
    Future<int?> waitInt(Stream<int?> st, int? cur) async {
      if ((cur ?? 0) > 0) return cur;
      try {
        return await st
            .where((v) => (v ?? 0) > 0)
            .first
            .timeout(const Duration(milliseconds: 3000));
      } catch (_) {
        return null;
      }
    }

    // 時長就緒才算初始化完成（音訊檔也有時長）
    if (_p.state.duration > Duration.zero) {
      _duration = _p.state.duration;
    } else {
      _duration = await _p.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10));
    }
    // 尺寸真相來源＝渲染紋理的實際大小（VideoController.rect）。
    // 紋理一定是「轉正後」的樣子——裸播放器看起來正確就是因為它
    // 用這個；metadata（videoParams 的 w/h/rotate）在不同影片上
    // 語意不一，猜測會踩雷
    Size? texSize;
    try {
      final r0 = _vc.rect.value;
      if (r0 != null && r0.width > 0 && r0.height > 0) {
        texSize = r0.size;
      } else {
        final done = Completer<Size>();
        void onRect() {
          final r = _vc.rect.value;
          if (r != null &&
              r.width > 0 &&
              r.height > 0 &&
              !done.isCompleted) {
            done.complete(r.size);
          }
        }

        _vc.rect.addListener(onRect);
        try {
          texSize =
              await done.future.timeout(const Duration(seconds: 4));
        } finally {
          _vc.rect.removeListener(onRect);
        }
      }
    } catch (_) {
      texSize = null; // 純音訊或紋理還沒起來 → 走後備
    }

    if (texSize != null) {
      _size = texSize;
      _dbgSizeFrom = 'texture';
    } else {
      // 後備：影片參數（dw/dh ＋ rotate 對調）
      mk.VideoParams? vp = _p.state.videoParams;
      if ((vp.w ?? 0) <= 0) {
        try {
          vp = await _p.stream.videoParams
              .firstWhere((v) => (v.w ?? 0) > 0)
              .timeout(const Duration(milliseconds: 3000));
        } catch (_) {
          vp = null;
        }
      }
      if (vp != null && (vp.w ?? 0) > 0 && (vp.h ?? 0) > 0) {
        var w = (vp.dw ?? vp.w)!;
        var h = (vp.dh ?? vp.h)!;
        final rot = vp.rotate ?? 0;
        if (rot % 180 != 0) {
          final t = w;
          w = h;
          h = t;
        }
        _size = Size(w.toDouble(), h.toDouble());
        _dbgSizeFrom = 'videoParams';
      } else {
        final w = await waitInt(_p.stream.width, _p.state.width);
        final h = await waitInt(_p.stream.height, _p.state.height);
        if ((w ?? 0) > 0 && (h ?? 0) > 0) {
          _size = Size(w!.toDouble(), h!.toDouble());
          _dbgSizeFrom = 'w/h streams';
        }
      }
    }
    _inited = true;
  }

  String _dbgSizeFrom = 'none';

  /// 診斷用：引擎回報的所有尺寸相關參數
  String get debugInfo {
    final vp = _p.state.videoParams;
    final r = _vc.rect.value;
    return 'size=${_size.width.round()}x${_size.height.round()} '
        '(from $_dbgSizeFrom)\n'
        'rect=${r == null ? 'null' : '${r.width.round()}x${r.height.round()}'}  '
        'w/h=${_p.state.width}x${_p.state.height}\n'
        'params w/h=${vp.w}x${vp.h} dw/dh=${vp.dw}x${vp.dh} '
        'rotate=${vp.rotate} aspect=${vp.aspect}';
  }

  PlayerValueX get value => PlayerValueX(
        isInitialized: _inited,
        isPlaying: _p.state.playing,
        duration: _duration,
        // media_kit 的 position 連續更新（比 video_player 的
        // 500ms 輪詢即時得多），對時邏輯直接受惠
        position: _p.state.position,
        size: _size,
      );

  Future<void> seekTo(Duration d) => _p.seek(d);

  Future<void> play() => _p.play();

  Future<void> pause() => _p.pause();

  Future<void> setVolume(double v) =>
      _p.setVolume((v * 100).clamp(0.0, 100.0));

  Future<void> setPlaybackSpeed(double s) => _p.setRate(s);

  Future<void> setLooping(bool loop) => _p.setPlaylistMode(
      loop ? mk.PlaylistMode.loop : mk.PlaylistMode.none);

  void dispose() => _p.dispose();

  /// 預覽畫面（等同 VideoPlayer widget；外層已依比例算好框，直接填滿）
  Widget view({Key? key}) => mkv.Video(
        key: key,
        controller: _vc,
        controls: mkv.NoVideoControls,
        fit: BoxFit.fill,
        fill: Colors.transparent,
      );
}

PlayerX makeVideoController(String path) => PlayerX(path);
