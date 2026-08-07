import 'package:wakelock_plus/wakelock_plus.dart';

/// 匯出期間讓螢幕不要自動關閉。
///
/// 螢幕一關，Android／iOS 就可能凍結或直接回收 App，整批匯出會斷在中間；
/// 已完成的檔案雖然都存進相簿了，但剩下的要重跑一次。
///
/// 平台不支援就安靜略過（Web 上使用者沒授權、或不是安全連線時會丟例外），
/// 這只是保險措施，失敗不該讓匯出整個中斷。
Future<void> keepScreenAwake(bool on) async {
  try {
    await WakelockPlus.toggle(enable: on);
  } catch (_) {}
}
