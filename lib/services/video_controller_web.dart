import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'player_value.dart';

/// Web 版播放控制器＝video_player（瀏覽器的 <video>，本來就順）。
/// 介面與手機版（media_kit）一致，編輯器無感切換。
class PlayerX {
  PlayerX(this.path)
      : _c = VideoPlayerController.networkUrl(Uri.parse(path));

  final String path;
  final VideoPlayerController _c;

  Future<void> initialize() => _c.initialize();

  PlayerValueX get value => PlayerValueX(
        isInitialized: _c.value.isInitialized,
        isPlaying: _c.value.isPlaying,
        duration: _c.value.duration,
        position: _c.value.position,
        size: _c.value.size,
      );

  Future<Duration?> positionNow() => _c.position;

  Future<void> seekTo(Duration d) => _c.seekTo(d);

  Future<void> play() => _c.play();

  Future<void> pause() => _c.pause();

  Future<void> setVolume(double v) => _c.setVolume(v);

  Future<void> setPlaybackSpeed(double s) => _c.setPlaybackSpeed(s);

  Future<void> setLooping(bool loop) => _c.setLooping(loop);

  void dispose() => _c.dispose();

  /// 診斷用
  String get debugInfo =>
      'size=${_c.value.size.width.round()}x${_c.value.size.height.round()} '
      '(video_player web)';

  /// 預覽畫面
  Widget view({Key? key}) => VideoPlayer(_c, key: key);
}

PlayerX makeVideoController(String path) => PlayerX(path);
