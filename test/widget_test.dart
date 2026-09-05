import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/main.dart';

void main() {
  testWidgets('App 首頁顯示四個入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MarkCutApp());
    await tester.pump();
    for (final label in const ['浮水印', '照片拼圖', 'GIF', '剪輯']) {
      expect(find.text(label), findsOneWidget, reason: '首頁少了「$label」');
    }
    // 舊的兩顆不在了：「加入浮水印」拆成四顆直接進功能，
    // 「製作浮水印」走 個人中心 → 範本 → ＋
    expect(find.text('加入浮水印'), findsNothing);
    expect(find.text('製作浮水印'), findsNothing);
  });
}
