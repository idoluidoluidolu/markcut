import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真的原生端在新合成的畫面上屏（翻面、舊播放器收掉）時回報 compVisible
///（AppDelegate 的 PlayerHosts.use，最慢 1.5 秒保底）。假的 markcut/comp
/// 通道組好之後也要回報：編輯器等換手收乾淨才開下一支轉檔
///（_settleCompBeforeNextPrep），沒有這一發只能等保底
void scheduleCompVisible([
  Duration after = const Duration(milliseconds: 120),
]) {
  Timer(after, () {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'markcut/comp',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('compVisible'),
          ),
          (_) {},
        );
  });
}
