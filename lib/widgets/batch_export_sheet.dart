import 'package:flutter/material.dart';

import '../services/video_processor.dart';
import '../theme.dart';

/// 批次匯出要用的設定
class BatchExportOptions {
  final bool jpeg;
  final int photoQuality;

  /// null＝每支影片照自己的來源挑
  final ExportQuality? videoQuality;

  const BatchExportOptions({
    this.jpeg = true,
    this.photoQuality = 92,
    this.videoQuality,
  });
}

/// 照片品質的四檔：名字跟影片的畫質同一套（省空間／標準／高畫質／
/// 最高畫質），由低到高排，跟影片的畫質彈窗同一個順序
const kPhotoQualityLevels = <(int, String, String)>[
  (75, '省空間', '檔案最小'),
  (85, '標準', '手機上不放大看不太出差別'),
  (92, '高畫質', '幾乎原畫質'),
  (100, '最高畫質', '檔案最大'),
];

/// 最接近 [q] 的那一檔
(int, String, String) photoQualityLevel(int q) => kPhotoQualityLevels.reduce(
  (a, b) => (a.$1 - q).abs() <= (b.$1 - q).abs() ? a : b,
);

/// 批次匯出的設定：跟影片編輯的匯出頁同一套（使用者指定「用我影片編輯
/// 那個模板」）——一列一列「標籤　值 ›」，點了開置中的選單彈窗，最下面
/// 一行摘要、一顆匯出鈕。按匯出才開始，關掉＝不匯出（回 null）
Future<BatchExportOptions?> showBatchExportSheet(
  BuildContext context, {
  required int photos,
  required int videos,
  BatchExportOptions initial = const BatchExportOptions(),
}) => showModalBottomSheet<BatchExportOptions>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) =>
      BatchExportSheet(photos: photos, videos: videos, initial: initial),
);

class BatchExportSheet extends StatefulWidget {
  final int photos;
  final int videos;
  final BatchExportOptions initial;

  const BatchExportSheet({
    super.key,
    required this.photos,
    required this.videos,
    required this.initial,
  });

  @override
  State<BatchExportSheet> createState() => _BatchExportSheetState();
}

class _BatchExportSheetState extends State<BatchExportSheet> {
  late bool _jpeg = widget.initial.jpeg;
  late int _photoQuality = photoQualityLevel(widget.initial.photoQuality).$1;
  late ExportQuality? _videoQuality = widget.initial.videoQuality;

  void _pickVideoQuality() => showOptionDialog<void>(
    context,
    title: '畫質',
    rows: (context) => [
      optionRow(
        context: context,
        title: '自動',
        subtitle: '每支影片照自己的來源挑，保留原始解析度',
        badge: '推薦',
        selected: _videoQuality == null,
        first: true,
        onTap: () {
          setState(() => _videoQuality = null);
          Navigator.pop(context);
        },
      ),
      for (final q in qualityOrder)
        optionRow(
          context: context,
          title: q.label,
          subtitle: q.note,
          selected: _videoQuality == q,
          onTap: () {
            setState(() => _videoQuality = q);
            Navigator.pop(context);
          },
        ),
    ],
  );

  void _pickFormat() => showOptionDialog<void>(
    context,
    title: '照片格式',
    rows: (context) => [
      for (final (i, (jpeg, title, note)) in const [
        (true, 'JPEG', '檔案小很多（約 1/8），肉眼看不出跟 PNG 差別'),
        (false, 'PNG 無損', '完全不壓縮'),
      ].indexed)
        optionRow(
          context: context,
          title: title,
          subtitle: note,
          selected: _jpeg == jpeg,
          first: i == 0,
          onTap: () {
            setState(() => _jpeg = jpeg);
            Navigator.pop(context);
          },
        ),
    ],
  );

  void _pickPhotoQuality() => showOptionDialog<void>(
    context,
    title: '照片品質',
    rows: (context) => [
      for (final (i, (q, title, note)) in kPhotoQualityLevels.indexed)
        optionRow(
          context: context,
          title: title,
          subtitle: note,
          badge: q == 92 ? '推薦' : null,
          selected: _photoQuality == q,
          first: i == 0,
          onTap: () {
            setState(() => _photoQuality = q);
            Navigator.pop(context);
          },
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final videos = widget.videos;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (videos > 0)
            exportSettingRow(
              '畫質',
              _videoQuality?.label ?? '自動·推薦',
              _pickVideoQuality,
              divider: photos > 0,
            ),
          if (photos > 0) ...[
            exportSettingRow(
              '照片格式',
              _jpeg ? 'JPEG' : 'PNG 無損',
              _pickFormat,
              divider: _jpeg,
            ),
            // PNG 是無損，沒有品質可以挑
            if (_jpeg)
              exportSettingRow(
                '照片品質',
                photoQualityLevel(_photoQuality).$2,
                _pickPhotoQuality,
                divider: false,
              ),
          ],
          const SizedBox(height: 22),
          // 摘要貼在匯出鈕正上方（跟影片編輯的預估同一個位置）
          Text(
            [
              if (videos > 0) '影片 $videos 支',
              if (photos > 0) '照片 $photos 張',
            ].join('·'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11.5,
              color: kTextDim,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          primaryAction(
            label: '匯出',
            onPressed: () => Navigator.pop(
              context,
              BatchExportOptions(
                jpeg: _jpeg,
                photoQuality: _photoQuality,
                videoQuality: _videoQuality,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
