import 'package:flutter/material.dart';

import '../services/storage_usage.dart';
import '../theme.dart';

/// 批次刪除時疊在磚上的標記：選到的整張壓暗、右上角一個選取圈，
/// 有給 [size] 的話左下角再標「刪掉能省多少」。
///
/// 不改磚的尺寸與點擊範圍（整層 IgnorePointer），只是疊上去。
/// 選取圈用黑底白勾（不是紅框）：紅色留給底下那顆刪除鈕，畫面上
/// 只有一個地方是紅的
class LibrarySelectionMark extends StatelessWidget {
  final bool selected;

  /// 左下角的大小標（例如「820 MB」）；null＝不標
  final String? size;

  const LibrarySelectionMark({super.key, required this.selected, this.size});

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            color: Colors.black.withValues(alpha: selected ? 0.35 : 0),
          ),
          Positioned(
            top: 7,
            right: 7,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? kLAccent
                    : Colors.black.withValues(alpha: 0.25),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
          if (size != null)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  size!,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 16 / 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 刪除鈕上的字：「刪除 2 份 · 省下 1.4 GB」。[bytes] 是 null（還在算）
/// 就只寫份數；「不到 1 MB」前面不空格（中文接中文）
String libraryDeleteLabel(int count, String unit, int? bytes) {
  final head = '刪除 $count $unit';
  if (bytes == null) return head;
  final size = formatBytes(bytes);
  return '$head · 省下${size.startsWith('不到') ? '' : ' '}$size';
}

/// 批次刪除的刪除鈕：選了至少一個才從底下浮上來。
///
/// 直接浮在內容上——後面不墊白底那一條（使用者指定「底部不要有白邊」），
/// 左右各離螢幕 12，比內容那一欄寬一點、不跟磚的邊切齊（使用者指定）。
/// 放在 body 的 Stack 最上層（它自己是 Positioned），不用
/// Scaffold.bottomNavigationBar：那裡一定會墊一塊底色
class LibraryDeleteDock extends StatelessWidget {
  final bool visible;

  /// 鈕上的字，例如「刪除 2 份 · 省下 1.4 GB」
  final String label;
  final bool busy;
  final VoidCallback onPressed;

  const LibraryDeleteDock({
    super.key,
    required this.visible,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final red = Theme.of(context).colorScheme.error;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 1.6),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x47000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: red,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: red.withValues(alpha: 0.6),
                    disabledForegroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'NotoSansTC',
                    ),
                  ),
                  onPressed: busy ? null : onPressed,
                  child: Text(busy ? '處理中…' : label),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
