import 'package:flutter/material.dart';

import '../theme.dart';

/// 去背背景色的一顆圓點（照片去背頁、剪輯的去背表共用）。
/// [color] 是 null＝自訂（彩虹圈，按了開挑色器）。
///
/// 選中＝外面再一圈白環、中間隔一道底色：白色、淺色的點只換邊框顏色
/// 根本看不出選了誰
class CutoutSwatch extends StatelessWidget {
  const CutoutSwatch({
    super.key,
    required this.color,
    required this.on,
    required this.onTap,
  });

  final Color? color;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 34,
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: on ? kAmber : Colors.transparent, width: 2),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          gradient: color == null
              ? const SweepGradient(
                  colors: [
                    Colors.red,
                    Colors.yellow,
                    Colors.green,
                    Colors.cyan,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ],
                )
              : null,
          border: Border.all(color: kClipBorder),
        ),
      ),
    ),
  );
}
