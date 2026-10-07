import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 新手教學的聚光燈：整個畫面壓暗，只留 [target]（一顆鈕）那一圈亮著、
/// 套一圈白框；下面一個白泡泡寫 [text]，右下一顆「知道了」。
///
/// 點哪裡都收起來（[onDismiss]）；點在亮著的那一圈上＝順手按下那顆鈕
/// （[onTargetTap]）——使用者看到亮的地方，第一個反應就是按它
class SpotlightHint extends StatelessWidget {
  const SpotlightHint({
    super.key,
    required this.target,
    required this.text,
    required this.onDismiss,
    this.onTargetTap,
  });

  /// 要亮著的那顆鈕（這個元件自己的座標）
  final Rect target;
  final String text;
  final VoidCallback onDismiss;
  final VoidCallback? onTargetTap;

  /// 亮著那一圈的半徑：比鈕的觸控範圍小一點，貼著圖示
  double get radius => math.max(20.0, target.shortestSide / 2 - 2);

  /// 泡泡離螢幕邊緣多遠
  static const double margin = 12;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      final center = target.center;
      // 泡泡靠在鈕那一側的邊上，箭頭對準鈕的中心
      final onRight = center.dx > size.width / 2;
      final arrowFromEdge = onRight
          ? size.width - margin - center.dx
          : center.dx - margin;
      // 蓋在整個頁面（連 Scaffold 一起）上面，底下沒有 Material：自己墊一層
      // 透明的，字才吃得到 App 的字型與預設樣式（不然是方塊＋黃底線）
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        builder: (context, t, child) => Opacity(opacity: t, child: child),
        child: Material(
          type: MaterialType.transparency,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final inside = (d.localPosition - center).distance <= radius + 4;
              if (inside && onTargetTap != null) {
                onTargetTap!();
              } else {
                onDismiss();
              }
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SpotlightPainter(center, radius),
                  ),
                ),
                Positioned(
                  top: center.dy + radius + 14,
                  right: onRight ? margin : null,
                  left: onRight ? null : margin,
                  child: _Bubble(
                    text: text,
                    arrowFromEdge: arrowFromEdge,
                    arrowOnRight: onRight,
                    maxWidth: size.width - margin * 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.arrowFromEdge,
    required this.arrowOnRight,
    required this.maxWidth,
  });

  final String text;

  /// 箭頭尖端離泡泡那一側邊緣多遠
  final double arrowFromEdge;
  final bool arrowOnRight;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    // 箭頭是轉 45° 的 12×12 小方塊；別貼進圓角裡
    final arrow = math.max(10.0, arrowFromEdge - 6);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: -5,
            right: arrowOnRight ? arrow : null,
            left: arrowOnRight ? null : arrow,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: kLCard,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
            decoration: BoxDecoration(
              color: kLCard,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x38000000),
                  blurRadius: 28,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 22 / 15,
                    color: kLText,
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  button: true,
                  // 只包住字（不撐滿泡泡寬）：Center 的 widthFactor 讓它貼著字
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: kLAccent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      widthFactor: 1,
                      child: Text(
                        '知道了',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 壓暗整個畫面、挖掉一個圓，圓外套一圈白框
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.62));
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.center != center || old.radius != radius;
}
