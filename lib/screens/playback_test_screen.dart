import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/diagnostics.dart';
import '../services/video_controller.dart';
import '../services/work_files.dart';
import '../theme.dart';

/// 純播放測試（除錯用）：用 App 目前的播放引擎裸播一支影片，
/// 沒有時間軸、沒有 ticker。編輯器卡但這裡順＝編輯器的問題；
/// 這裡也卡＝引擎/裝置的問題。
/// （2026-08-06 已把裝置端引擎換成 media_kit，video_player 在
/// Pixel 上裸播放實測就會卡）
///
/// 2026-08-15 加上「原檔／工作檔」切換與畫面時間統計：
/// 「播放卡頓」有三種來源（UI 執行緒、合成執行緒、影格沒送上來），
/// 一支一支排除比用猜的快得多——同一支影片切兩種檔案各播一次，
/// 三個數字直接把範圍縮到一種
class PlaybackTestScreen extends StatefulWidget {
  const PlaybackTestScreen({super.key});

  @override
  State<PlaybackTestScreen> createState() => _PlaybackTestScreenState();
}

class _PlaybackTestScreenState extends State<PlaybackTestScreen> {
  PlayerX? _c;

  /// 挑到的原檔，以及它的工作檔（1080p SDR）
  String? _srcPath;
  String? _workPath;

  /// 現在播的是工作檔還是原檔
  bool _useWork = false;
  bool _busy = false;

  /// 畫面統計的取樣起點（切檔案時歸零，兩種才比得起來）
  int _baseFrames = 0, _baseJankB = 0, _baseJankR = 0;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    Diag.watchFrames();
    // 統計是背景累積的，這裡每秒刷新畫面上的數字
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _resetStats() {
    _baseFrames = Diag.frames;
    _baseJankB = Diag.jankBuild;
    _baseJankR = Diag.jankRaster;
    Diag.worstBuildMs = 0;
    Diag.worstRasterMs = 0;
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _busy = true;
      _srcPath = picked.path;
      _workPath = null;
      _useWork = false;
    });
    await _load(picked.path);
    // 順手把工作檔備起來，切過去就能直接比
    final w = await WorkFiles.ensure(picked.path);
    if (mounted) setState(() => _workPath = w);
  }

  Future<void> _load(String path) async {
    final old = _c;
    _c = null;
    if (mounted) setState(() {});
    old?.dispose();
    final c = makeVideoController(path);
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.play();
    } catch (_) {
      c.dispose();
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) {
      c.dispose();
      return;
    }
    _resetStats();
    setState(() {
      _c = c;
      _busy = false;
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final frames = Diag.frames - _baseFrames;
    final jb = Diag.jankBuild - _baseJankB;
    final jr = Diag.jankRaster - _baseJankR;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('純播放測試'),
        actions: [
          IconButton(
            tooltip: '選影片',
            icon: const Icon(Icons.video_library_outlined),
            onPressed: _busy ? null : _pick,
          ),
        ],
      ),
      body: c == null || !c.value.isInitialized
          ? Center(
              child: _busy
                  ? const CircularProgressIndicator()
                  : FilledButton(
                      onPressed: _pick,
                      child: const Text('選一支影片開始'),
                    ),
            )
          : Column(
              children: [
                Expanded(
                  child: Stack(
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
                            horizontal: 10,
                            vertical: 6,
                          ),
                          color: Colors.black54,
                          child: Text(
                            '${c.value.size.width.round()}x'
                            '${c.value.size.height.round()}  '
                            '${c.value.duration.inSeconds}s\n'
                            '${c.debugInfo}\n'
                            '${_useWork ? '工作檔（1080p SDR）' : '原檔'}\n'
                            '這 $frames 格裡：UI 超時 $jb（最久 '
                            '${Diag.worstBuildMs}ms）、'
                            '合成超時 $jr（最久 ${Diag.worstRasterMs}ms）',
                            style: const TextStyle(
                              fontSize: 11,
                              color: kText,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 同一支影片、兩種檔案，各看一次數字：
                // 原檔卡、工作檔順＝解碼吃不消；兩個都卡＝跟檔案無關
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: secondaryAction(
                            label: '播原檔',
                            icon: Icons.hd_outlined,
                            onPressed: (_busy || !_useWork || _srcPath == null)
                                ? null
                                : () {
                                    setState(() => _useWork = false);
                                    _load(_srcPath!);
                                  },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: primaryAction(
                            label: _workPath == null ? '工作檔準備中' : '播工作檔',
                            icon: Icons.speed,
                            onPressed: (_busy || _useWork || _workPath == null)
                                ? null
                                : () {
                                    setState(() => _useWork = true);
                                    _load(_workPath!);
                                  },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
