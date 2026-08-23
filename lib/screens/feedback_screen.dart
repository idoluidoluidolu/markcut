import 'package:flutter/material.dart';

import '../services/feedback_api.dart';
import '../services/store_links.dart';
import '../theme.dart';
import 'about_screen.dart' show kAppVersion;

/// 意見回饋：置中談窗，寫完直接送到 TWCONCERTVIEW 後台
Future<void> showFeedbackDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    // 不給點背景關閉：送出中點到背景會讓結果無聲消失，
    // 使用者以為沒送成又送一次，後台就重複了。
    // 返回鍵同理，交給表單自己在沒在送的時候才放行
    barrierDismissible: false,
    builder: (context) => Dialog(
      backgroundColor: kLBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
        side: const BorderSide(color: kLBorder),
      ),
      child: ConstrainedBox(
        // 這個視窗有兩個輸入框，kDialogWidth（280）打字太擠——
        // 放寬到 340（使用者要求）
        constraints: const BoxConstraints(maxWidth: 340),
        child: const _FeedbackForm(),
      ),
    ),
  );
}

class _FeedbackForm extends StatefulWidget {
  const _FeedbackForm();

  @override
  State<_FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends State<_FeedbackForm> {
  final _msg = TextEditingController();
  final _contact = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _msg.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final err = await sendFeedback(
      message: _msg.text,
      contact: _contact.text,
      appVersion: kAppVersion,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      showHint(context, err, error: true);
      return;
    }
    Navigator.pop(context);
    showHint(context, '收到了，謝謝你的回饋！');
  }

  /// 不關對話框：使用者可能只是去看一眼，回來還想把表單填完
  Future<void> _openThreads() async {
    final ok = await openThreads();
    if (!mounted || ok) return;
    showHint(context, '開不了 Threads，我的帳號是 @$kThreadsHandle', error: true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 送出中不讓返回鍵關掉：關掉的話成功／失敗都不會顯示，
      // 使用者不知道送出去沒有，就會再送一次
      canPop: !_sending,
      child: _form(context),
    );
  }

  Widget _form(BuildContext context) {
    return SingleChildScrollView(
      // 鍵盤跳出來時內容還捲得動
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '聯絡我',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '發現 BUG、想要的功能，都可以跟我說',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: kLTextDim, height: 1.6),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _msg,
            maxLines: 6,
            minLines: 4,
            maxLength: 2000,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: '想說的話⋯',
              counterText: '',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _contact,
            maxLength: 120,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: '你的聯絡方式（選填）',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _sending ? null : _send,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    '送出',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
          ),
          // 分成兩條路：填表單、或直接私訊。
          // 用「或」的分隔線講清楚，不然兩顆按鈕擺一起會不知道該按哪個
          const SizedBox(height: 14),
          const Row(
            children: [
              Expanded(child: Divider(color: kLBorder, height: 1)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '或',
                  style: TextStyle(fontSize: 11, color: kLTextDim),
                ),
              ),
              Expanded(child: Divider(color: kLBorder, height: 1)),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _sending ? null : _openThreads,
            // 形狀與高度都對齊上面的「送出」（46）：
            // 形狀沿用佈景的 6px 圓角，不要自己覆寫
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              foregroundColor: kLText,
              side: const BorderSide(color: kLBorder),
            ),
            icon: const Icon(Icons.alternate_email, size: 16),
            label: const Text('直接密我 Threads', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _sending ? null : () => Navigator.pop(context),
            child: const Text(
              '關閉',
              style: TextStyle(fontSize: 13, color: kLTextDim),
            ),
          ),
        ],
      ),
    );
  }
}
