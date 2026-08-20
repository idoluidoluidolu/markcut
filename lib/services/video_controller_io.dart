import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import 'player_value.dart';

/// 裝置端播放控制器：平台分流。
/// - Android：media_kit（libmpv）。video_player 的 ExoPlayer 影格
///   傳遞在 Pixel 等機型上實測卡頓（裸播放器就卡）。
/// - iOS：video_player（AVPlayer）。原生路徑本來就順；
///   media_kit 的 iOS 函式庫實測黑畫面＋拿不到尺寸。
/// 介面模仿 VideoPlayerController，編輯器無感。
abstract class PlayerX {
  factory PlayerX(String path) =>
      Platform.isIOS ? _AvPlayerX(path) : _FallbackPlayerX(path);

  String get path;
  Future<void> initialize();
  PlayerValueX get value;

  /// 「現在」的播放位置，直接問引擎。
  /// value.position 是 video_player 的快取，約每 500ms 才更新一次，
  /// 拿它來判斷「影格開始滾動了沒」永遠等不到
  Future<Duration?> positionNow();
  Future<void> seekTo(Duration d);
  Future<void> play();
  Future<void> pause();
  Future<void> setVolume(double v);
  Future<void> setPlaybackSpeed(double s);
  Future<void> setLooping(bool loop);
  void dispose();

  /// 預覽畫面（等同 VideoPlayer widget）
  Widget view({Key? key});

  /// 診斷用：引擎回報的尺寸相關參數
  String get debugInfo;
}

/// mpv 有影像軌卻畫不出紋理（部分機型黑畫面）。
/// 用來通知 [_FallbackPlayerX] 換引擎，不會漏到更外層
class MpvBlackScreen implements Exception {
  const MpvBlackScreen();
}

/// Android：先試 media_kit（libmpv），開不起來或畫不出影像就換
/// ExoPlayer（video_player）。
///
/// libmpv 在部分機型上吃不下螢幕錄影那類檔案（奇數解析度、可變影格
/// 率）：硬解開不起來就黑畫面、退軟解則慢到像當掉。ExoPlayer 對系統
/// 自家錄的檔案幾乎都吃得下，但它在 Pixel 上的影格傳遞會卡——
/// 所以順序是 mpv 優先，只有撞牆的那一支換引擎
class _FallbackPlayerX implements PlayerX {
  _FallbackPlayerX(this.path);

  @override
  final String path;

  late PlayerX _inner = _MpvPlayerX(path);

  @override
  Future<void> initialize() async {
    try {
      await _inner.initialize();
    } catch (_) {
      // 黑畫面、逾時、開檔失敗都走這裡。ExoPlayer 再失敗才往外丟
      //（呼叫端本來就有「影片打不開」的處理）
      _inner.dispose();
      _inner = _AvPlayerX(path);
      await _inner.initialize();
    }
  }

  @override
  PlayerValueX get value => _inner.value;

  @override
  Future<Duration?> positionNow() => _inner.positionNow();

  @override
  Future<void> seekTo(Duration d) => _inner.seekTo(d);

  @override
  Future<void> play() => _inner.play();

  @override
  Future<void> pause() => _inner.pause();

  @override
  Future<void> setVolume(double v) => _inner.setVolume(v);

  @override
  Future<void> setPlaybackSpeed(double s) => _inner.setPlaybackSpeed(s);

  @override
  Future<void> setLooping(bool loop) => _inner.setLooping(loop);

  @override
  void dispose() => _inner.dispose();

  @override
  Widget view({Key? key}) => _inner.view(key: key);

  @override
  String get debugInfo =>
      '${_inner.debugInfo}\n(engine: ${_inner is _MpvPlayerX ? 'mpv' : 'exo'})';
}

/// iOS：AVPlayer（經 video_player）。
/// Android 的後備引擎也是這個類別（video_player 在安卓走 ExoPlayer）
class _AvPlayerX implements PlayerX {
  _AvPlayerX(this.path) : _c = VideoPlayerController.file(File(path));

  @override
  final String path;
  final VideoPlayerController _c;

  @override
  Future<void> initialize() => _c.initialize();

  @override
  PlayerValueX get value => PlayerValueX(
        isInitialized: _c.value.isInitialized,
        isPlaying: _c.value.isPlaying,
        isBuffering: _c.value.isBuffering,
        duration: _c.value.duration,
        position: _c.value.position,
        size: _c.value.size,
      );

  @override
  Future<Duration?> positionNow() => _c.position;

  @override
  Future<void> seekTo(Duration d) => _c.seekTo(d);

  @override
  Future<void> play() => _c.play();

  @override
  Future<void> pause() => _c.pause();

  @override
  Future<void> setVolume(double v) => _c.setVolume(v);

  @override
  Future<void> setPlaybackSpeed(double s) => _c.setPlaybackSpeed(s);

  @override
  Future<void> setLooping(bool loop) => _c.setLooping(loop);

  @override
  void dispose() => _c.dispose();

  @override
  Widget view({Key? key}) => VideoPlayer(_c, key: key);

  @override
  String get debugInfo =>
      'size=${_c.value.size.width.round()}x${_c.value.size.height.round()} '
      '(AVPlayer)';
}

/// Android：media_kit（libmpv）
class _MpvPlayerX implements PlayerX {
  _MpvPlayerX(this.path);

  @override
  final String path;
  final mk.Player _p = mk.Player();
  late final mkv.VideoController _vc = mkv.VideoController(_p);

  bool _inited = false;
  Size _size = Size.zero;
  Duration _duration = Duration.zero;
  String _dbgSizeFrom = 'none';

  @override
  Future<Duration?> positionNow() async => _p.state.position;

  @override
  Future<void> initialize() async {
    await _p.open(mk.Media(path), play: false);

    // 時長就緒才算初始化完成（音訊檔也有時長）
    if (_p.state.duration > Duration.zero) {
      _duration = _p.state.duration;
    } else {
      _duration = await _p.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10));
    }
    // 尺寸真相來源＝渲染紋理的實際大小（已含旋轉）
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
      // 紋理沒起來。查清楚是「根本沒有影像軌」還是「有影像卻畫不出來」：
      // 音訊檔（配樂、旁白）本來就沒有紋理，繼續用 mpv 沒問題；
      // 但有影像軌卻沒紋理＝黑畫面——部分機型的解碼器吃不下螢幕錄影
      // 那類奇數解析度／可變影格率的檔案。丟出去讓外層換 ExoPlayer，
      // 系統自家錄的檔案它幾乎都吃得下
      mk.VideoParams? vp = _p.state.videoParams;
      if ((vp.w ?? 0) <= 0) {
        try {
          // 紋理那邊已經等了 4 秒，參數要到早就到了——短等收尾就好
          vp = await _p.stream.videoParams
              .firstWhere((v) => (v.w ?? 0) > 0)
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {
          vp = null;
        }
      }
      final hasVideo =
          (vp != null && (vp.w ?? 0) > 0) || (_p.state.width ?? 0) > 0;
      if (hasVideo) throw const MpvBlackScreen();
      _dbgSizeFrom = 'audio-only';
    }
    _inited = true;
  }

  @override
  PlayerValueX get value => PlayerValueX(
        isInitialized: _inited,
        isPlaying: _p.state.playing,
        duration: _duration,
        // media_kit 的 position 連續更新（比 video_player 的
        // 500ms 輪詢即時得多），對時邏輯直接受惠
        position: _p.state.position,
        size: _size,
      );

  @override
  Future<void> seekTo(Duration d) => _p.seek(d);

  @override
  Future<void> play() => _p.play();

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> setVolume(double v) =>
      _p.setVolume((v * 100).clamp(0.0, 100.0));

  @override
  Future<void> setPlaybackSpeed(double s) => _p.setRate(s);

  @override
  Future<void> setLooping(bool loop) => _p.setPlaylistMode(
      loop ? mk.PlaylistMode.loop : mk.PlaylistMode.none);

  @override
  void dispose() => _p.dispose();

  @override
  Widget view({Key? key}) => mkv.Video(
        key: key,
        controller: _vc,
        controls: mkv.NoVideoControls,
        fit: BoxFit.fill,
        fill: Colors.transparent,
      );

  @override
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
}

PlayerX makeVideoController(String path) => PlayerX(path);
