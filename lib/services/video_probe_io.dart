import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import 'frame_check.dart';
import 'native_frames.dart';
import 'work_files.dart';

/// 播放偵測：對同一支影片把每一層解碼路徑各跑一遍，量化成一份
/// 可以複製回傳的報告——遠端使用者的「沒畫面」一份報告就能定位。
///
/// 量的是「亮度」：抽幀或截圖出來算平均亮度（0~255）。
/// 正常影片幾十以上；全黑就是個位數。哪一層黑、哪一層亮，
/// 對照起來就知道壞在哪：
/// - 系統抽幀亮、mpv 截圖黑 → mpv 的硬解吃不下這支檔
/// - 全部黑 → 檔案或系統解碼本身的問題
/// - 系統播放器位置不前進 → 連 ExoPlayer 都播不動
Future<void> runVideoProbe(String path, void Function(String) log) async {
  log('=== 播放偵測報告 ===');
  log('檔案：${path.split('/').last.split('\\').last}');
  try {
    log('大小：${(File(path).lengthSync() / 1048576).toStringAsFixed(1)} MB');
  } catch (_) {}
  log('平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  log('');

  // ---- 1. 系統怎麼看這支檔（軌道格式＋會挑哪顆解碼器，Android 限定）
  if (Platform.isAndroid) {
    log('— 系統軌道資訊 —');
    try {
      final m = await const MethodChannel(
        'markcut/diag',
      ).invokeMethod<Map>('videoProbe', {'path': path});
      if (m == null) {
        log('（拿不到）');
      } else {
        m.forEach((k, v) => log('$k：$v'));
      }
    } catch (e) {
      log('查失敗：$e');
    }
    log('');
  }

  // ---- 2. FFmpeg 怎麼看（編碼、像素格式、影格率、色彩資訊）
  log('— FFprobe —');
  try {
    final session = await FFprobeKit.getMediaInformation(path);
    final streams = session.getMediaInformation()?.getStreams() ?? [];
    if (streams.isEmpty) log('（讀不到串流）');
    for (final s in streams) {
      final p = s.getAllProperties() ?? {};
      log([
        for (final k in [
          'codec_type',
          'codec_name',
          'profile',
          'width',
          'height',
          'pix_fmt',
          'avg_frame_rate',
          'r_frame_rate',
          'color_space',
          'color_transfer',
          'nb_frames',
        ])
          if (p[k] != null) '$k=${p[k]}',
      ].join(' '));
    }
  } catch (e) {
    log('FFprobe 失敗：$e');
  }
  log('');

  // ---- 3. 系統抽幀（MediaMetadataRetriever）：亮度
  log('— 系統抽幀亮度（0~255，全黑＝個位數）—');
  for (final t in const [0.2, 1.0, 3.0, 6.0]) {
    final b = await nativeFrameAt(path, t, maxH: 240);
    if (b == null) {
      log('${t}s：抽不到');
      continue;
    }
    final lum = await meanLuminance(b);
    log('${t}s：${lum?.toStringAsFixed(1) ?? '解不開'}');
  }
  log('');

  // ---- 4. 系統播放器實測（Android=ExoPlayer / iOS=AVPlayer）
  log('— 系統播放器（${Platform.isAndroid ? 'ExoPlayer' : 'AVPlayer'}）—');
  final vp = VideoPlayerController.file(File(path));
  try {
    await vp.initialize().timeout(const Duration(seconds: 8));
    log(
      '初始化 OK：${vp.value.size.width.round()}x${vp.value.size.height.round()}'
      '，${(vp.value.duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    await vp.setVolume(0);
    await vp.play();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final pos = await vp.position;
    await vp.pause();
    final ms = pos?.inMilliseconds ?? 0;
    log('播 1.2 秒後位置：$ms ms（${ms > 200 ? '有前進' : '沒前進！'}）');
  } catch (e) {
    log('失敗：$e');
  } finally {
    unawaited(vp.dispose());
  }
  log('');

  // ---- 5. mpv 實測：開檔、第一格、播起來之後的畫面亮度
  log('— mpv（media_kit）—');
  final p = mk.Player();
  final vc = mkv.VideoController(p);
  try {
    await p.open(mk.Media(path), play: false);
    await p.stream.duration
        .firstWhere((d) => d > Duration.zero)
        .timeout(const Duration(seconds: 8));
    log(
      '開檔 OK：mpv 時長 '
      '${(p.state.duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    try {
      await vc.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 5));
      log('第一格：有渲染');
    } catch (_) {
      log('第一格：逾時（沒渲染出來）');
    }
    await p.setVolume(0);
    await p.play();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final s1 = await p.screenshot();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final s2 = await p.screenshot();
    await p.pause();
    for (final (i, s) in [(1, s1), (2, s2)]) {
      if (s == null) {
        log('截圖$i：拿不到（硬解影格可能不給讀，這本身也是線索）');
        continue;
      }
      final lum = await meanLuminance(s);
      log('截圖$i 亮度：${lum?.toStringAsFixed(1) ?? '解不開'}');
    }
  } catch (e) {
    log('失敗：$e');
  } finally {
    p.dispose();
  }
  log('');

  // ---- 6. 工作檔：轉一份出來，看它畫不畫得出東西
  //（黑畫面最後一個嫌疑：轉檔「成功」卻吐出壞檔）
  log('— 工作檔 —');
  try {
    final work = await WorkFiles.ensure(path);
    if (work == null) {
      log('沒有工作檔（轉檔失敗或驗不過 → App 會用原檔，這是安全的）');
    } else {
      final b = await nativeFrameAt(work, 1.0, maxH: 240);
      final lum = b == null ? null : await meanLuminance(b);
      log('工作檔 OK：亮度 ${lum?.toStringAsFixed(1) ?? '解不開'}');
    }
  } catch (e) {
    log('失敗：$e');
  }

  log('');
  log('— 判讀 —');
  log('系統抽幀亮、mpv 黑 → mpv 硬解吃不下這支檔');
  log('全部黑 → 檔案或系統解碼本身的問題');
  log('把整份報告複製傳回來即可');
  log('=== 報告結束 ===');
}
