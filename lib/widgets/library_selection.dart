import 'package:flutter/material.dart';

/// 選取框不改變縮圖的尺寸與點擊範圍。
class LibrarySelectionMark extends StatelessWidget {
  final bool selected;
  const LibrarySelectionMark({super.key, required this.selected});

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: selected
              ? Border.all(color: Theme.of(context).colorScheme.error, width: 3)
              : null,
        ),
        child: Align(
          alignment: Alignment.topRight,
          child: Container(
            margin: const EdgeInsets.all(8),
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? Theme.of(context).colorScheme.error
                  : Colors.black54,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: selected
                ? const Icon(Icons.check, size: 17, color: Colors.white)
                : null,
          ),
        ),
      ),
    ),
  );
}

class LibrarySelectionBar extends StatelessWidget {
  final int count;
  final bool busy;
  final VoidCallback onDelete;
  const LibrarySelectionBar({
    super.key,
    required this.count,
    required this.busy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(child: Text('已選 $count 項')),
          FilledButton.icon(
            onPressed: busy || count == 0 ? null : onDelete,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.delete_outline),
            label: Text(busy ? '處理中…' : '刪除 ($count)'),
          ),
        ],
      ),
    ),
  );
}
