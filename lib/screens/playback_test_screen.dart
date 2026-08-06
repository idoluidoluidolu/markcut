import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/video_controller.dart';
import '../theme.dart';

/// 純播放測試（除錯用）：用 App 目前的播放引擎裸播一支影片，
/// 沒有時間軸、沒有 ticker。編輯器卡但這裡順＝編輯器的問題；
/// 這裡也卡＝引擎/裝置的問題。
/// （2026-08-06 已把裝置端引擎換成 media_kit，video_player 在
/// Pixel 上裸播放實測就會卡）
class PlaybackTestScreen extends StatefulWidget {
  const PlaybackTestScreen({super.key});

  @override
  State<PlaybackTestScreen> createState() => _PlaybackTestScreenState();
}

class _PlaybackTestScreenState extends State<PlaybackTestScreen> {
  PlayerX? _c;

  Future<void> _pick() async {
    final picked =
        await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    final old = _c;
    _c = null;
    if (mounted) setState(() {});
    old?.dispose();
    final c = makeVideoController(picked.path);
    await c.initialize();
    await c.setLooping(true);
    await c.play();
    if (!mounted) {
      c.dispose();
      return;
    }
    setState(() => _c = c);
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('純播放測試'),
        actions: [
          IconButton(
            tooltip: '選影片',
            icon: const Icon(Icons.video_library_outlined),
            onPressed: _pick,
          ),
        ],
      ),
      body: c == null || !c.value.isInitialized
          ? Center(
              child: FilledButton(
                onPressed: _pick,
                child: const Text('選一支影片開始'),
              ),
            )
          : Stack(
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio,
                    child: c.view(),
                  ),
                ),
                // 影片規格：回報問題時一起截進來
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    color: Colors.black54,
                    child: Text(
                      '${c.value.size.width.round()}x'
                      '${c.value.size.height.round()}  '
                      '${c.value.duration.inSeconds}s',
                      style:
                          const TextStyle(fontSize: 12, color: kText),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
