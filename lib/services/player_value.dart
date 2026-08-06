import 'dart:ui';

/// 播放器狀態快照：介面模仿 video_player 的 VideoPlayerValue，
/// 讓編輯器在兩顆引擎（手機 media_kit / Web video_player）之間無感切換
class PlayerValueX {
  final bool isInitialized;
  final bool isPlaying;
  final Duration duration;
  final Duration position;
  final Size size;

  const PlayerValueX({
    required this.isInitialized,
    required this.isPlaying,
    required this.duration,
    required this.position,
    required this.size,
  });

  double get aspectRatio =>
      (size.width <= 0 || size.height <= 0) ? 16 / 9 : size.width / size.height;
}
