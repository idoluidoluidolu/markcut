import 'package:flutter/material.dart';

import '../theme.dart';

/// 進場的讀取畫面：素材備好之前整頁擋著。
///
/// 備素材本身省不掉（1080p SDR 的工作檔是拖曳跟匯出順的前提），但
/// 「什麼時候讓使用者看到編輯器」是可以選的。以前是進場就給畫面、
/// 背景邊轉邊換，結果是進去之後畫面閃、按播放會跳；現在一次等完，
/// 進去就是完成品。
///
/// 抽成獨立元件是為了能單獨渲染——不然它埋在編輯器的 State 裡，
/// 想看一眼就得開整個編輯畫面
class PrepGateView extends StatelessWidget {
  /// 這一批總共幾支素材、已經備好幾支
  final int done;
  final int total;

  /// 正在備的那一支做到哪（0~1）。
  ///
  /// 沒有它的話百分比只會跳 33、67、100——三支素材的畫面上，
  /// 那個大數字大半時間是停著的，看起來就像當掉
  final double current;

  /// 編輯器本身載好了沒。還沒載好時連「幾支」都還不知道
  final bool ready;

  const PrepGateView({
    super.key,
    required this.done,
    required this.total,
    this.current = 0,
    this.ready = true,
  });

  @override
  Widget build(BuildContext context) {
    final counting = ready && total > 0;
    final pct = counting
        ? ((done + current.clamp(0.0, 1.0)) / total).clamp(0.0, 1.0)
        : 0.0;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (counting)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${(pct * 100).floor()}',
                  style: const TextStyle(
                    fontSize: 46,
                    fontWeight: FontWeight.w300,
                    color: kText,
                    height: 1,
                    // 等寬數字：不然位數一變，整組數字會左右跳
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const Text(
                  '%',
                  style: TextStyle(fontSize: 17, color: kTextDim, height: 1.6),
                ),
              ],
            )
          else
            const Text(
              '載入中',
              style: TextStyle(fontSize: 15, color: kTextDim, letterSpacing: 2),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: 150,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                // 還不知道總數時走不定量（來回跑的那種）
                value: counting ? pct : null,
                minHeight: 3,
                backgroundColor: kPanelHi,
                color: kAmber,
              ),
            ),
          ),
          if (counting) ...[
            const SizedBox(height: 14),
            Text(
              '準備素材 $done／$total',
              style: const TextStyle(fontSize: 12, color: kTextDim),
            ),
          ],
        ],
      ),
    );
  }
}
