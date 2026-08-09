import 'package:flutter/material.dart';

import '../services/feedback_api.dart';
import '../theme.dart';
import 'about_screen.dart' show kAppVersion;

/// 意見回饋：置中談窗，寫完直接送到 TWCONCERTVIEW 後台
Future<void> showFeedbackDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    // 不給點背景關閉：送出中點到背景會讓結果無聲消失，
    // 使用者以為沒送成又送一次，後台就重複了
    barrierDismissible: false,
    builder: (context) => Dialog(
      backgroundColor: kBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: kBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
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

  @override
  Widget build(BuildContext context) {
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
            '歡迎留下任何你想說的話...',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: kTextDim, height: 1.6),
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
              filled: true,
              fillColor: Colors.black,
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
              filled: true,
              fillColor: Colors.black,
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
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _sending ? null : () => Navigator.pop(context),
            child: const Text(
              '關閉',
              style: TextStyle(fontSize: 13, color: kTextDim),
            ),
          ),
        ],
      ),
    );
  }
}
