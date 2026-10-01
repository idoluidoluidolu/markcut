import 'package:flutter/material.dart';

import '../services/storage_usage.dart';
import '../theme.dart';
import '../widgets/swipe_back.dart';

/// 堆疊條與方塊上的色點：一套灰階，由深到淺（草稿通常最大，最深）
const _kDraftsInk = kLText;
const _kGifInk = Color(0xFF5A5A63);
const _kPresetsInk = Color(0xFF8E8E97);
const _kStickersInk = Color(0xFFB9B9C1);
const _kCacheInk = Color(0xFFDEDEE4);

/// 方塊右上角的 ›、清理鈕停用時的字色
const _kFaint = Color(0xFF8C8C95);

/// 方塊的圓角（比磚大一號：方塊本身比較大）
const _kBoxRadius = 16.0;

const _kLabelStyle = TextStyle(
  fontSize: 14,
  height: 20 / 14,
  fontWeight: FontWeight.w600,
  color: kLTextDim,
);

const _kValueStyle = TextStyle(
  fontSize: 26,
  height: 32 / 26,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.3,
  color: kLText,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// 容量與清理（乙案「方塊」，使用者定案）：最上面總容量＋一條灰階
/// 堆疊條，下面每一類一個方塊。草稿／GIF／範本點進去就是那一類的
/// 「查看全部」，直接在批次刪除（共用同一頁，不另做管理頁）；
/// 暫存那一塊旁邊一顆「清理」
class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.openDrafts,
    required this.openGifs,
    required this.openPresets,
  });

  final Future<void> Function() openDrafts;
  final Future<void> Function() openGifs;
  final Future<void> Function() openPresets;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  StorageReport? _report;
  String? _error;
  bool _busy = false;
  int _scanGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final generation = ++_scanGeneration;
    try {
      final report = await StorageUsage.scan();
      if (mounted && generation == _scanGeneration) {
        setState(() {
          _report = report;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && generation == _scanGeneration) {
        setState(() => _error = '容量讀取失敗，請重試');
      }
    }
  }

  /// 點進去刪了東西回來，數字要跟著變
  Future<void> _manage(Future<void> Function() open) async {
    await open();
    if (mounted) await _scan();
  }

  Future<void> _clear() async {
    if (_busy) return;
    _scanGeneration++;
    setState(() => _busy = true);
    try {
      final freed = await StorageUsage.clearCaches();
      if (mounted) {
        showHint(
          context,
          freed > 0 ? '已清出 ${formatBytes(freed)}' : '目前沒有可清理的暫存',
        );
      }
      await _scan();
    } catch (_) {
      if (mounted) showHint(context, '部分暫存無法清理，請稍後重試', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return SwipeBack(
      child: Scaffold(
        // 上面只有返回鍵：頁名就是底下那一行「容量」
        appBar: AppBar(),
        body: _error != null
            ? Center(
                child: TextButton(onPressed: _scan, child: Text(_error!)),
              )
            : r == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  22,
                  6,
                  22,
                  MediaQuery.paddingOf(context).bottom + 24,
                ),
                children: [
                  const Text(
                    '容量',
                    style: TextStyle(
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w600,
                      color: kLTextDim,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatBytes(r.total),
                    style: const TextStyle(
                      fontSize: 44,
                      height: 52 / 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: kLText,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StackBar(
                    parts: [
                      (r.projectBytes, _kDraftsInk),
                      (r.gifBytes, _kGifInk),
                      (r.presetBytes, _kPresetsInk),
                      (r.stickerBytes, _kStickersInk),
                      (r.thumbnailBytes + r.filesUnused, _kCacheInk),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _box(
                          '草稿',
                          r.projectBytes,
                          _kDraftsInk,
                          () => _manage(widget.openDrafts),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _box(
                          'GIF',
                          r.gifBytes,
                          _kGifInk,
                          () => _manage(widget.openGifs),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _box(
                          '範本',
                          r.presetBytes,
                          _kPresetsInk,
                          () => _manage(widget.openPresets),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 貼圖沒有自己的清單頁：只標多大
                      Expanded(
                        child: _box('貼圖', r.stickerBytes, _kStickersInk, null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _cacheBox(r),
                ],
              ),
      ),
    );
  }

  static Widget _dot(Color ink) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
  );

  /// 數字放不下（字放大到兩倍）就縮，不換行：兩個並排的方塊才一樣高
  static Widget _value(int bytes) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text(formatBytes(bytes), maxLines: 1, style: _kValueStyle),
  );

  /// 一類一個方塊：色點＋名字（點得進去的右上角一個 ›），底下大大的容量
  Widget _box(String label, int bytes, Color ink, VoidCallback? open) {
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 104),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                _dot(ink),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: _kLabelStyle)),
                if (open != null)
                  const Icon(Icons.chevron_right, size: 18, color: _kFaint),
              ],
            ),
            const SizedBox(height: 8),
            _value(bytes),
          ],
        ),
      ),
    );
    return Material(
      color: kLTile,
      shape: tileShape(radius: _kBoxRadius),
      clipBehavior: Clip.antiAlias,
      child: open == null
          ? body
          : InkWell(onTap: _busy ? null : open, child: body),
    );
  }

  /// 暫存：預覽縮圖＋沒有草稿在用的轉檔檔案，清掉之後要用時會再做。
  /// 有草稿讀不到、算不出它用了哪些轉檔檔案時，轉檔那一份先不給清
  ///（說不定就是那幾份在用，見 StorageReport.pending）
  Widget _cacheBox(StorageReport r) {
    final canClear = r.clearableBytes > 0;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: kLTile,
        shape: tileShape(radius: _kBoxRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _dot(_kCacheInk),
                      const SizedBox(width: 8),
                      const Text('暫存', style: _kLabelStyle),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _value(r.thumbnailBytes + r.filesUnused),
                  const SizedBox(height: 4),
                  Text(
                    '縮圖 ${formatBytes(r.thumbnailBytes)} · '
                    '轉檔 ${formatBytes(r.filesUnused)}'
                    '${r.pending > 0 && r.filesUnused > 0 ? ' 暫不清理' : ''}',
                    style: const TextStyle(
                      fontSize: 13,
                      height: 18 / 13,
                      color: kLTextDim,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const ValueKey('clear-storage-cache'),
              onPressed: _busy || !canClear ? null : _clear,
              style: FilledButton.styleFrom(
                backgroundColor: kLText,
                foregroundColor: Colors.white,
                disabledBackgroundColor: kLBorder,
                disabledForegroundColor: _kFaint,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 22),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'NotoSansTC',
                ),
              ),
              child: Text(
                _busy
                    ? '清理中…'
                    : canClear
                    ? '清理'
                    : '已清理',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 總容量底下那一條：每一類一段，長度照比例，段與段之間空 2。
/// 太小的類別至少 3 寬（不然根本看不到）；是 0 的不畫
class _StackBar extends StatelessWidget {
  final List<(int, Color)> parts;

  const _StackBar({required this.parts});

  static const _gap = 2.0;
  static const _min = 3.0;

  @override
  Widget build(BuildContext context) {
    final shown = [for (final p in parts) if (p.$1 > 0) p];
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 10,
        child: shown.isEmpty
            ? const ColoredBox(color: kLTile)
            : LayoutBuilder(
                builder: (context, box) {
                  final room = box.maxWidth - _gap * (shown.length - 1);
                  final sum = shown.fold(0, (a, p) => a + p.$1);
                  // 先照比例分，太窄的補到 3；補出來的那一點從夠寬的
                  // 那幾段照比例扣回去，總長才剛好是整條
                  final raw = [for (final p in shown) room * p.$1 / sum];
                  final small = raw.where((w) => w < _min).length;
                  final bigSum = raw
                      .where((w) => w >= _min)
                      .fold(0.0, (a, w) => a + w);
                  final scale = bigSum <= 0
                      ? 1.0
                      : (room - small * _min) / bigSum;
                  final widths = [
                    for (final w in raw) w < _min ? _min : w * scale,
                  ];
                  // stretch：沒有子元件的 ColoredBox 會縮成最小的尺寸，
                  // 不撐滿的話每一段都是 0 高、整條看不見
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < shown.length; i++) ...[
                        if (i > 0) const SizedBox(width: _gap),
                        SizedBox(
                          width: widths[i],
                          child: ColoredBox(color: shown[i].$2),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}
