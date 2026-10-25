import 'package:flutter/material.dart';

import '../theme.dart';

/// 效果磚後面接的一格「動作」（不是效果，按了直接做事，例如筆刷馬賽克的
/// 「筆刷」＝關掉樣式表、接著塗）
typedef MosaicTileAction = ({IconData icon, String label, VoidCallback onTap});

/// 馬賽克效果的磚：像素化／模糊（＋純色、＋一格動作）。使用者在照片馬賽克
/// 模式定的長相——白色單色圖示＋字、選中白框亮底；純色預設不出現（使用者：
/// 純色不用，只有筆刷馬賽克要有）。照片馬賽克模式的面板、影片剪輯三種馬賽克
/// 的樣式表都用這一排，長得才一致
class MosaicEffectTiles extends StatelessWidget {
  /// 0＝像素化、1＝模糊、2＝純色
  final int type;
  final ValueChanged<int> onPick;

  /// 要不要有純色（只有筆刷馬賽克有）
  final bool withSolid;

  /// 最後一格動作（沒有就 null）
  final MosaicTileAction? action;

  const MosaicEffectTiles({
    super.key,
    required this.type,
    required this.onPick,
    this.withSolid = false,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final a = action;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tile('像素化', Icons.grid_on, type == 0, () => onPick(0)),
          const SizedBox(width: 8),
          _tile('模糊', Icons.blur_on, type == 1, () => onPick(1)),
          if (withSolid) ...[
            const SizedBox(width: 8),
            _tile('純色', Icons.format_color_fill, type == 2, () => onPick(2)),
          ],
          if (a != null) ...[
            const SizedBox(width: 8),
            _tile(a.label, a.icon, false, a.onTap),
          ],
        ],
      ),
    );
  }

  Widget _tile(String label, IconData icon, bool on, VoidCallback onTap) =>
      Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: on ? null : onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 62),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            // 設定面板裡的「選項」一律白框白字＋亮底（同樣式表的 chip）
            decoration: BoxDecoration(
              color: on ? kPanelHi : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: on ? kAmber : kClipBorder,
                width: on ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 24, color: on ? kText : kIcon),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                      color: kText,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
