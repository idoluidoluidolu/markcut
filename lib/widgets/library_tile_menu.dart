import 'package:flutter/material.dart';

import '../theme.dart';

/// 長按選單裡的一項
class LibraryMenuAction<T> {
  final T value;
  final String label;
  final IconData? icon;

  /// 刪除這種動作：字與圖示用紅色
  final bool destructive;

  const LibraryMenuAction(
    this.value,
    this.label, {
    this.icon,
    this.destructive = false,
  });
}

/// 長按一格：背景壓暗、那一格稍微浮起來，旁邊跳出一個小選單。
///
/// 不是整頁蓋住的確認對話框（使用者指定「直接在旁邊出現小選單」），
/// 但背景照樣壓暗（使用者指定），讓人看得出問的是哪一格。選單最後
/// 一列固定是「取消」；點選單外面也是取消。回傳選到的那一項，取消是 null。
///
/// [tileContext] 要是那一格自己的 context（拿它量位置）；[preview] 是
/// 浮起來那一格要畫的內容，通常就是磚裡的那張圖
Future<T?> showLibraryTileMenu<T>(
  BuildContext tileContext, {
  required Widget preview,
  required List<LibraryMenuAction<T>> actions,
  String? title,
  double radius = kTileRadius,
}) {
  final box = tileContext.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) {
    return Future<T?>.value();
  }
  final rect = box.localToGlobal(Offset.zero) & box.size;
  // 對話框掛在最上層的 Navigator，那裡的佈景是 App 預設的深色；
  // 長按的是淺色頁，照它的佈景畫
  final theme = Theme.of(tileContext);
  return showGeneralDialog<T>(
    context: tileContext,
    barrierDismissible: true,
    barrierLabel: '關閉',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, a1, a2) => Theme(
      data: theme,
      child: _TileMenuLayer<T>(
        rect: rect,
        preview: preview,
        actions: actions,
        title: title,
        radius: radius,
      ),
    ),
    transitionBuilder: (context, anim, a2, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: child,
    ),
  );
}

class _TileMenuLayer<T> extends StatefulWidget {
  final Rect rect;
  final Widget preview;
  final List<LibraryMenuAction<T>> actions;
  final String? title;
  final double radius;

  const _TileMenuLayer({
    required this.rect,
    required this.preview,
    required this.actions,
    required this.title,
    required this.radius,
  });

  @override
  State<_TileMenuLayer<T>> createState() => _TileMenuLayerState<T>();
}

class _TileMenuLayerState<T> extends State<_TileMenuLayer<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  Widget _row({
    required String label,
    required VoidCallback onTap,
    IconData? icon,
    Color? color,
    bool bold = false,
  }) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ),
            if (icon != null) Icon(icon, size: 19, color: color),
          ],
        ),
      ),
    ),
  );

  Widget _menu(BuildContext context) {
    final c = pageColors(context);
    final danger = Theme.of(context).colorScheme.error;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(14),
    );
    final rows = <Widget>[];
    for (final a in widget.actions) {
      if (rows.isNotEmpty) {
        rows.add(Divider(height: 1, thickness: 1, color: c.line));
      }
      rows.add(
        _row(
          label: a.label,
          icon: a.icon,
          color: a.destructive ? danger : c.text,
          bold: a.destructive,
          onTap: () => Navigator.pop(context, a.value),
        ),
      );
    }
    rows
      ..add(Divider(height: 1, thickness: 1, color: c.line))
      ..add(
        _row(
          label: '取消',
          color: c.text,
          onTap: () => Navigator.pop(context),
        ),
      );
    return SizedBox(
      width: 176,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: c.card,
          shape: shape,
          shadows: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 3),
                    child: Text(
                      widget.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 18 / 13,
                        color: c.dim,
                      ),
                    ),
                  ),
                ...rows,
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lift = CurvedAnimation(parent: _lift, curve: Curves.easeOutCubic);
    return Stack(
      children: [
        // 浮起來的那一格：畫在原本的位置，放大一點點加一道陰影。
        // 點它也是關掉（跟點外面一樣）
        Positioned.fromRect(
          rect: widget.rect,
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.04).animate(lift),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: tileShape(radius: widget.radius),
                  shadows: const [
                    BoxShadow(
                      color: Color(0x59000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRSuperellipse(
                  borderRadius: tileClip(widget.radius),
                  child: widget.preview,
                ),
              ),
            ),
          ),
        ),
        // 選單：擺在那一格旁邊（右邊放得下就右邊，不然左邊），
        // 垂直對齊那一格的中線，碰到螢幕上下緣就往內收
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _MenuPosition(
              anchor: widget.rect,
              padding: MediaQuery.paddingOf(context),
            ),
            child: _menu(context),
          ),
        ),
      ],
    );
  }
}

class _MenuPosition extends SingleChildLayoutDelegate {
  final Rect anchor;
  final EdgeInsets padding;

  const _MenuPosition({required this.anchor, required this.padding});

  static const _gap = 10.0;
  static const _edge = 12.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size child) {
    final double x;
    final bool beside;
    if (anchor.right + _gap + child.width <= size.width - _edge) {
      x = anchor.right + _gap;
      beside = true;
    } else if (anchor.left - _gap - child.width >= _edge) {
      x = anchor.left - _gap - child.width;
      beside = true;
    } else {
      // 兩邊都放不下（那一格幾乎滿版）：放在它的正下方
      x = (anchor.center.dx - child.width / 2).clamp(
        _edge,
        size.width - _edge - child.width,
      );
      beside = false;
    }
    final minY = padding.top + _edge;
    final maxY = size.height - padding.bottom - _edge - child.height;
    var y = beside
        ? anchor.center.dy - child.height / 2
        : anchor.bottom + _gap;
    if (!beside && y > maxY) y = anchor.top - _gap - child.height;
    y = maxY < minY ? minY : y.clamp(minY, maxY);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPosition oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.padding != padding;
}
