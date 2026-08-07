import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// TWCONCERTVIEW 後台的意見回饋端點（跟「留己看」打同一支，
/// 進後台的「📱 APP 意見回報」區）
const kFeedbackEndpoint = 'https://api.twconcertview.com/api/app-feedback/';

/// 後台沒有分辨 App 的欄位，所以在內容前面標記，
/// 這樣才不會跟留己看的回饋混在一起
const kFeedbackTag = '[浮水印]';

/// 送出意見回饋。成功回 null，失敗回錯誤訊息（要顯示給使用者看）
Future<String?> sendFeedback({
  required String message,
  required String contact,
  required String appVersion,
}) async {
  final content = message.trim();
  if (content.isEmpty) return '先寫點內容再送出唷';
  try {
    final res = await http
        .post(
          Uri.parse(kFeedbackEndpoint),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'feedback': '$kFeedbackTag $content',
            'contact': contact.trim(),
            'platform': _platform(),
            'version': appVersion,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 200 && res.statusCode < 300) return null;
    return '送出失敗（${res.statusCode}），請稍後再試';
  } catch (_) {
    return '送出失敗，請檢查網路再試一次';
  }
}

String _platform() {
  if (kIsWeb) return 'web';
  try {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
  } catch (_) {}
  return 'other';
}
