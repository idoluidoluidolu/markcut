import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

/// 作者的 Threads 帳號（意見回饋裡的「直接密我」用）
const kThreadsHandle = 'twconcertview';

/// 開作者的 Threads。裝了 Threads App 的話系統會直接接手開 App，
/// 沒裝就落到瀏覽器
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

/// 「留己看」的 App Store ID
const kLiuJiKanIosId = '6787609932';

/// 「留己看」的 Google Play 套件名
const kLiuJiKanAndroidPackage = 'com.idoluidoluidolu.save';

/// 找不到對應商店時的落腳頁
const kLiuJiKanWebUrl = 'https://apps.apple.com/tw/app/id$kLiuJiKanIosId';

/// 按鈕文字要跟實際會開的商店對得上（Android 開的是 Play 不是 App Store）
String get liuJiKanStoreLabel {
  if (!kIsWeb) {
    try {
      if (Platform.isAndroid) return '留己看GOOGLE PLAY';
    } catch (_) {}
  }
  return '留己看APPSTORE';
}

/// 依平台開對應的商店頁。
///
/// 用 https 網址就好，不需要 market://、itms-apps:// 那種自訂 scheme，
/// 也就不必在 Info.plist 加 LSApplicationQueriesSchemes。
Future<bool> openLiuJiKan() async {
  var url = kLiuJiKanWebUrl;
  if (!kIsWeb) {
    try {
      if (Platform.isAndroid) {
        url =
            'https://play.google.com/store/apps/details'
            '?id=$kLiuJiKanAndroidPackage';
      }
    } catch (_) {}
  }
  // launchUrl 在沒有瀏覽器可開時是「丟例外」不是回 false，
  // 一律轉成 false 讓呼叫端統一顯示提示
  try {
    return await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
