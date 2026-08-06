import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/main.dart';

void main() {
  testWidgets('App 首頁顯示影片與照片入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MarkCutApp());
    await tester.pump();
    expect(find.text('加入浮水印'), findsOneWidget);
    expect(find.text('製作浮水印'), findsOneWidget);
  });
}
