import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../theme.dart';

/// 錄旁白：按住不放錄音、放開結束，回傳錄好的檔案路徑（取消回 null）。
/// 顯示即時音量與計時，錄完可以重錄或直接加入時間軸。
class VoiceRecorderSheet extends StatefulWidget {
  const VoiceRecorderSheet({super.key});

  /// 開啟錄音面板；回傳 (路徑, 秒數) 或 null
  static Future<({String path, double seconds})?> show(
      BuildContext context) {
    return showModalBottomSheet<({String path, double seconds})>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => const VoiceRecorderSheet(),
    );
  }

  @override
  State<VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

class _VoiceRecorderSheetState extends State<VoiceRecorderSheet> {
  final _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _tick;

  bool _recording = false;
  String? _donePath;
  double _seconds = 0;
  double _level = 0; // 0~1 的音量條
  String? _error;

  @override
  void dispose() {
    _ampSub?.cancel();
    _tick?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = '需要麥克風權限才能錄音');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_'
          '${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
        path: path,
      );
      _seconds = 0;
      _donePath = null;
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() => _seconds += 0.1);
      });
      _ampSub = _rec
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen((a) {
        // dBFS（約 -60~0）換成 0~1
        final v = ((a.current + 60) / 60).clamp(0.0, 1.0);
        if (mounted) setState(() => _level = v);
      });
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = '無法開始錄音：$e');
    }
  }

  Future<void> _stop() async {
    _tick?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      final path = await _rec.stop();
      setState(() {
        _recording = false;
        _level = 0;
        _donePath = path;
      });
    } catch (e) {
      setState(() {
        _recording = false;
        _error = '錄音結束時出錯：$e';
      });
    }
  }

  String get _timeText {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).floor().toString().padLeft(2, '0');
    final d = ((_seconds * 10) % 10).floor();
    return '$m:$s.$d';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('錄旁白',
                style: TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              _recording
                  ? '錄音中…再按一次停止'
                  : (_donePath == null
                      ? '按下開始錄，錄好會加到播放位置'
                      : '錄好了，可以直接加入或重錄'),
              style: const TextStyle(fontSize: 11.5, color: kTextDim),
            ),
            const SizedBox(height: 22),
            // 計時
            Text(_timeText,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                )),
            const SizedBox(height: 16),
            // 音量條
            SizedBox(
              height: 34,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < 21; i++)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 2.5),
                      child: Container(
                        width: 3,
                        height: 6 +
                            28 *
                                _level *
                                // 中間高、兩側低的形狀
                                math.cos((i - 10) / 10 * 1.2).abs(),
                        decoration: BoxDecoration(
                          color: _recording
                              ? const Color(0xFFFF6B6B)
                              : kBorder,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF6B6B))),
            ],
            const SizedBox(height: 24),
            // 主按鈕：開始 / 停止
            InkWell(
              onTap: _recording ? _stop : _start,
              borderRadius: BorderRadius.circular(40),
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _recording
                      ? const Color(0xFFFF6B6B)
                      : kPanelHi,
                  border: Border.all(
                      color: _recording
                          ? const Color(0xFFFF6B6B)
                          : kClipBorder,
                      width: 2),
                ),
                child: Icon(
                  _recording ? Icons.stop_rounded : Icons.mic,
                  size: 32,
                  color: _recording ? Colors.white : kText,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _recording
                        ? null
                        : () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      foregroundColor: kTextDim,
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: (_donePath == null || _seconds < 0.3)
                        ? null
                        : () => Navigator.pop(context, (
                              path: _donePath!,
                              seconds: _seconds,
                            )),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: const Text('加入時間軸'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
