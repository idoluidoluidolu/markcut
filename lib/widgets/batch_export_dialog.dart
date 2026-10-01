import 'package:flutter/material.dart';

import '../services/video_processor.dart';

class BatchExportOptions {
  final bool jpeg;
  final int photoQuality;

  /// null＝按每個來源自動選擇。
  final ExportQuality? videoQuality;

  const BatchExportOptions({
    this.jpeg = true,
    this.photoQuality = 92,
    this.videoQuality,
  });
}

/// 格式、品質與確認集中在一個視窗；純影片也必須確認才開始匯出。
class BatchExportDialog extends StatefulWidget {
  final bool hasPhoto;
  final bool hasVideo;
  final BatchExportOptions initial;

  const BatchExportDialog({
    super.key,
    required this.hasPhoto,
    required this.hasVideo,
    required this.initial,
  });

  @override
  State<BatchExportDialog> createState() => _BatchExportDialogState();
}

class _BatchExportDialogState extends State<BatchExportDialog> {
  late bool _jpeg = widget.initial.jpeg;
  late int _photoQuality = widget.initial.photoQuality;
  late ExportQuality? _videoQuality = widget.initial.videoQuality;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('批次匯出設定'),
    scrollable: true,
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.hasVideo) ...[
            DropdownButtonFormField<int>(
              key: const ValueKey('batch-video-quality'),
              initialValue: _videoQuality?.index ?? -1,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '影片畫質'),
              items: [
                const DropdownMenuItem(value: -1, child: Text('自動（依來源）')),
                for (final q in qualityOrder)
                  DropdownMenuItem(value: q.index, child: Text(q.label)),
              ],
              onChanged: (value) => setState(() {
                _videoQuality = value == null || value < 0
                    ? null
                    : ExportQuality.values[value];
              }),
            ),
            const SizedBox(height: 8),
            Text(_videoQuality?.note ?? '依各影片來源選擇品質，保留原始解析度。'),
            if (widget.hasPhoto) const SizedBox(height: 24),
          ],
          if (widget.hasPhoto) ...[
            const Text('照片格式'),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('JPEG')),
                ButtonSegment(value: false, label: Text('PNG 無損')),
              ],
              selected: {_jpeg},
              onSelectionChanged: (values) =>
                  setState(() => _jpeg = values.single),
            ),
            if (_jpeg) ...[
              const SizedBox(height: 16),
              Text('照片品質 $_photoQuality%'),
              Slider(
                key: const ValueKey('batch-photo-quality'),
                value: _photoQuality.toDouble(),
                min: 60,
                max: 100,
                divisions: 40,
                label: '$_photoQuality%',
                onChanged: (v) => setState(() => _photoQuality = v.round()),
              ),
            ],
            const SizedBox(height: 8),
            const Text('HDR 照片會優先保留為 HDR HEIC；PNG 使用無損編碼。'),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          BatchExportOptions(
            jpeg: _jpeg,
            photoQuality: _photoQuality,
            videoQuality: _videoQuality,
          ),
        ),
        child: const Text('開始匯出'),
      ),
    ],
  );
}
