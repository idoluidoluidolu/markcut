import 'dart:ui';

/// 播放器狀態快照：介面模仿 video_player 的 VideoPlayerValue，
/// 讓編輯器在兩顆引擎（手機 media_kit / Web video_player）之間無感切換
class PlayerValueX {
  final bool isInitialized;
  final bool isPlaying;

  /// 播放器自己說「我在等資料」。按下播放後的那段等待到底是不是
  /// 緩衝，只有它分得出來
  final bool isBuffering;
  final Duration duration;
  final Duration position;
  final Size size;

  const PlayerValueX({
    required this.isInitialized,
    required this.isPlaying,
    this.isBuffering = false,
    required this.duration,
    required this.position,
    required this.size,
  });

  double get aspectRatio =>
      (size.width <= 0 || size.height <= 0) ? 16 / 9 : size.width / size.height;
}
