import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/video_probe.dart';
import '../services/video_picker.dart';
import '../theme.dart';
import '../widgets/swipe_back.dart';

/// 播放偵測：選一支「在這台手機上播不出來」的影片，把每一層解碼
/// 路徑各跑一遍（系統抽幀、ExoPlayer、mpv、FFprobe），
/// 產出一份可複製的報告。遠端使用者回報「沒畫面」時，
/// 一份報告就能定位壞在哪一層，不用一來一回猜
class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  final List<String> _lines = [];
  bool _running = false;

  Future<void> _pick() async {
    if (_running) return;
    final files = await pickVideoFiles();
    if (files.isEmpty || !mounted) return;
    setState(() {
      _lines.clear();
      _running = true;
    });
    try {
      await runVideoProbe(files.first.path, (s) {
        if (mounted) setState(() => _lines.add(s));
      });
    } catch (e) {
      if (mounted) setState(() => _lines.add('偵測中斷：$e'));
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (mounted) showHint(context, '已複製整份報告');
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg, title: const Text('播放偵測')),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text(
                  '選一支「播不出來」的影片，跑完把報告複製給開發者',
                  style: TextStyle(fontSize: 12.5, color: kTextDim),
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101014),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder),
                  ),
                  child: _lines.isEmpty
                      ? const Center(
                          child: Text(
                            '還沒有報告',
                            style: TextStyle(fontSize: 12, color: kTextDim),
                          ),
                        )
                      : SingleChildScrollView(
                          child: SelectableText(
                            _lines.join('\n'),
                            style: const TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              color: kText,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: primaryAction(
                        label: _running ? '偵測中…' : '選影片開始偵測',
                        icon: Icons.troubleshoot,
                        onPressed: _running ? null : _pick,
                      ),
                    ),
                    if (_lines.isNotEmpty && !_running) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: primaryAction(
                          label: '複製報告',
                          icon: Icons.copy,
                          onPressed: _copy,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
