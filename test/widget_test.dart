import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/main.dart';

void main() {
  testWidgets('App 首頁：右下角一顆＋，點了才出現三個入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MarkCutApp());
    await tester.pump();

    // 收起來的首頁上沒有任何入口文字（使用者指定：下方整個收掉）
    for (final label in const ['浮水印', '照片拼圖', 'GIF', '剪輯', '加入浮水印', '製作浮水印']) {
      expect(find.text(label), findsNothing, reason: '「$label」不該在收起來的首頁上');
    }
    expect(find.byType(FloatingActionButton), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    for (final label in const ['浮水印', '照片拼圖', 'GIF']) {
      expect(find.text(label), findsOneWidget, reason: '＋選單少了「$label」');
    }
  });
}
