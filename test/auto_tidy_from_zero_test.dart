// 「銜接」開著的時候，片頭的空白也要收掉——使用者指定：拖最前面那支
// 的左把手往右，前面空出來的要自動補回最開始。
//
// 這是行為規定，不是實作細節：自動銜接（_autoTidyIfOn）跟手動那顆
// 「銜接」（_closeGaps）都必須帶 fromZero: true。少了它，第一段被剪短
// 之後就停在原地、片頭留一段黑的——正是使用者回報的那個 bug。
//
// 為什麼用掃原始碼的方式守：這兩個都是 VideoEditorScreen 的私有方法，
// 要從外面驅動得整頁跑起來（原生播放器外掛在測試環境不存在）。
// closeGaps 本身的語意由 timeline_reverse_test 的「整理：片頭空白」
// 那一組守著，這裡守的是「螢幕有沒有真的用上」
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 抓 `void _autoTidyIfOn(...) { ... }` 這種一整個方法的內容（到下一個
/// 同縮排的 `}` 為止）
String _body(String src, String signature) {
  final i = src.indexOf(signature);
  expect(i, isNot(-1), reason: '找不到 $signature，改名了就要一起改這支測試');
  final end = src.indexOf('\n  }', i);
  expect(end, isNot(-1), reason: '$signature 的結尾找不到');
  return src.substring(i, end);
}

void main() {
  test('銜接（自動與手動）都連片頭空白一起收', () {
    final src = File('lib/screens/video_editor_screen.dart').readAsStringSync();

    for (final sig in const [
      'void _autoTidyIfOn({int? track})',
      'void _closeGaps()',
    ]) {
      final body = _body(src, sig);
      expect(
        body.contains('closeGaps('),
        isTrue,
        reason: '$sig 沒有呼叫 closeGaps',
      );
      expect(
        RegExp(r'fromZero:\s*true').hasMatch(body),
        isTrue,
        reason:
            '$sig 少了 fromZero: true——'
            '銜接開著時片頭的空白也要收（使用者指定：拖最前面的把手往右要補到最開始）',
      );
    }
  });
}
