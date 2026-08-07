import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

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
Future<bool> openLiuJiKan() {
  var url = kLiuJiKanWebUrl;
  if (!kIsWeb) {
    try {
      if (Platform.isAndroid) {
        url = 'https://play.google.com/store/apps/details'
            '?id=$kLiuJiKanAndroidPackage';
      }
    } catch (_) {}
  }
  return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
