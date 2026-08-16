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

  /// 編輯器本身載好了沒。還沒載好時連「幾支」都還不知道
  final bool ready;

  const PrepGateView({
    super.key,
    required this.done,
    required this.total,
    this.ready = true,
  });

  @override
  Widget build(BuildContext context) {
    final counting = ready && total > 0;
    final pct = counting ? (done / total).clamp(0.0, 1.0) : null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              // 還不知道總數時轉圈圈，知道了才走進度
              value: pct == null || pct <= 0 ? null : pct,
              color: kAmber,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            counting ? '準備素材 $done／$total' : '載入中',
            style: const TextStyle(fontSize: 13, color: kText),
          ),
          if (counting) ...[
            const SizedBox(height: 6),
            const Text(
              '轉成剪輯用的格式，之後拖曳與匯出都會順',
              style: TextStyle(fontSize: 11, color: kTextDim),
            ),
          ],
        ],
      ),
    );
  }
}
