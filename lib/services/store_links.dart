import 'package:url_launcher/url_launcher.dart';

/// 作者的 Threads 帳號（意見回饋裡的「直接密我」用）
const kThreadsHandle = 'twconcertview';

/// 開作者的 Threads。裝了 Threads App 的話系統會直接接手開 App，
/// 沒裝就落到瀏覽器。
///
/// launchUrl 在沒有瀏覽器可開時是「丟例外」不是回 false，
/// 一律轉成 false 讓呼叫端統一顯示提示
Future<bool> openThreads() async {
  try {
    return await launchUrl(
      Uri.parse('https://www.threads.net/@$kThreadsHandle'),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
