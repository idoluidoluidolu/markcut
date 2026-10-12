import 'package:flutter/material.dart';

import '../theme.dart';
import 'kaomoji_sheet.dart';

/// 「時間」拿哪一個時鐘。測試換成固定時間，不然跨分鐘那一刻會對不上
@visibleForTesting
DateTime Function() insertTimeNow = DateTime.now;

/// 「時間」那顆加進去的寫法：2026/10/12 15:20
String timeStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}/${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 現在的時間戳記（「時間」那顆按下去加的就是這個）
String timeStampNow() => timeStamp(insertTimeNow());

/// 把 [line] 接成 [text] 的新的一行。空的就直接是它；最後已經是換行的
/// 不再多空一行
String appendLine(String text, String line) {
  if (text.isEmpty) return line;
  return text.endsWith('\n') ? '$text$line' : '$text\n$line';
}

/// 文字輸入框底下那排「時間｜顏文字」（10-12 使用者在提案畫布挑的乙案）。
///
/// 時間＝一按就把現在的時間加成文字的最後一行，不跳選單、不挑寫法；
/// 顏文字＝開顏文字表（點一個複製，回來貼上）。浮水印面板的文字卡跟
/// 文字素材的編輯視窗共用這一排
class TextInsertBar extends StatelessWidget {
  final VoidCallback onTime;

  const TextInsertBar({super.key, required this.onTime});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        _InsertPill(
          key: const ValueKey('text-insert-time'),
          icon: Icons.schedule,
          label: '時間',
          onTap: onTime,
        ),
        _InsertPill(
          key: const ValueKey('text-insert-kaomoji'),
          icon: Icons.emoji_emotions_outlined,
          label: '顏文字',
          onTap: () => showKaomojiSheet(context),
        ),
      ],
    );
  }
}

class _InsertPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _InsertPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const shape = StadiumBorder(side: BorderSide(color: kClipBorder));
    return Material(
      color: const Color(0xFF141416),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: kIcon),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: kTextDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
