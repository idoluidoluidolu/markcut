import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../theme.dart';
import 'slip_strip.dart';

/// 固定片段長度，以來源時間選段。大預覽只顯示所選段落的開頭，
/// 拖動時即時抽取；預覽與縮圖都取各自指定的時間，
/// 不沿用可能借過隔壁格、或只含關鍵幀的時間軸粗縮圖。
class SlipPicker extends StatefulWidget {
  const SlipPicker({
    super.key,
    required this.duration,
    required this.start,
    required this.length,
    required this.loadFrame,
    required this.onCommit,
    this.loadThumbnail,
  });

  final double duration;
  final double start;
  final double length;
  final Future<Uint8List?> Function(double seconds) loadFrame;
  final Future<Uint8List?> Function(double seconds)? loadThumbnail;
  final ValueChanged<double> onCommit;

  @override
  State<SlipPicker> createState() => _SlipPickerState();
}

class _SlipPickerState extends State<SlipPicker> {
  late double _start = widget.start;
  final _frames = <({int at, bool preview}), Uint8List?>{};
  List<({int at, bool preview})> _wanted = [];
  bool _loading = false;

  int _key(double seconds) => (seconds * 1000).round().clamp(
    0,
    math.max(0, (widget.duration * 1000).ceil() - 1),
  );

  /// 一次只解一張。手指移動時替換待抽清單，最新開頭排在縮圖前。
  /// 快取依實際要求的時間查找，晚到的舊畫面不會貼到新的時間標籤下。
  void _requestFrames(Iterable<double> thumbnails) {
    final wanted = {
      (at: _key(_start), preview: true),
      for (final t in thumbnails) (at: _key(t), preview: false),
    }.toList();
    if (listEquals(wanted, _wanted)) return;
    _wanted = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadFrames());
    });
  }

  Future<void> _loadFrames() async {
    if (_loading) return;
    _loading = true;
    try {
      while (mounted) {
        final pending = _wanted.where((t) => !_frames.containsKey(t));
        if (pending.isEmpty) break;
        final at = pending.first;
        Uint8List? frame;
        try {
          final load = at.preview
              ? widget.loadFrame
              : (widget.loadThumbnail ?? widget.loadFrame);
          frame = await load(at.at / 1000);
        } catch (_) {
          // 壞檔／離開畫面：顯示無法預覽，不以舊圖冒充。
        }
        if (!mounted) return;
        setState(() {
          _frames[at] = frame;
          // 大圖只保留最近幾個開頭；縮圖用另一組小圖，不隨手指累積大圖。
          while (_frames.keys.where((k) => k.preview).length > 8) {
            final old = _frames.keys.firstWhere(
              (k) => k.preview && !_wanted.contains(k),
            );
            _frames.remove(old);
          }
          while (_frames.length > 96) {
            final old = _frames.keys.firstWhere((t) => !_wanted.contains(t));
            _frames.remove(old);
          }
        });
      }
    } finally {
      _loading = false;
    }
  }

  static String _time(double seconds) {
    final cs = (seconds * 100).round();
    final minutes = (cs ~/ 6000).toString().padLeft(2, '0');
    final secs = (cs ~/ 100 % 60).toString().padLeft(2, '0');
    return '$minutes:$secs.${(cs % 100).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: LayoutBuilder(
        builder: (context, box) {
          final tiles = (box.maxWidth / SlipStrip.height).ceil().clamp(1, 64);
          _requestFrames([
            for (var i = 0; i < tiles; i++) (i + 0.5) / tiles * widget.duration,
          ]);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    '換段',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                ],
              ),
              Expanded(child: _preview()),
              const SizedBox(height: 12),
              Text(
                '開頭 ${_time(_start)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final at in [0.0, widget.duration])
                    Text(
                      _time(at),
                      style: const TextStyle(
                        fontSize: 10,
                        color: kTextDim,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SlipStrip(
                key: const ValueKey('slip-strip'),
                frames: const [],
                duration: widget.duration,
                start: _start,
                length: widget.length,
                frameAt: (t) => _frames[(at: _key(t), preview: false)],
                onChanged: (t) => setState(() => _start = t),
                onEnd: () => widget.onCommit(_start),
              ),
              const SizedBox(height: 10),
              const Text(
                '拖動選段，即時預覽開頭',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: kTextDim),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _preview() {
    final key = (at: _key(_start), preview: true);
    final bytes = _frames[key];
    final pending = !_frames.containsKey(key);
    return Semantics(
      label: '開頭畫面 ${_time(_start)}',
      child: Container(
        key: const ValueKey('slip-preview-start'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(kTagRadius),
        ),
        child: bytes != null
            ? Image.memory(bytes, key: ValueKey(key), fit: BoxFit.contain)
            : Center(
                child: Text(
                  pending ? '載入開頭畫面…' : '無法預覽',
                  style: const TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
      ),
    );
  }
}
