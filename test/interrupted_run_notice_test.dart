import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/interrupted_run_notice.dart';

void main() {
  testWidgets('啟動後才讀到報告也自動出現，並能查看和複製', (tester) async {
    Diag.recoveredReport.value = null;
    addTearDown(() => Diag.recoveredReport.value = null);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: InterruptedRunNotice())),
    );
    expect(find.text('查看報告'), findsNothing);
    const report = '上次檢查點：多軌道預覽，5 軌，1800 MB';
    Diag.recoveredReport.value = report;
    await tester.pump();
    await tester.tap(find.text('查看報告'));
    await tester.pumpAndSettle();
    expect(find.text(report), findsOneWidget);
    await tester.tap(find.text('複製報告'));
    await tester.pumpAndSettle();
    expect(clipboard, report);
    expect(find.text('報告已複製'), findsOneWidget);
    expect(Diag.recoveredReport.value, report, reason: '查看和複製不能吃掉報告，下次重開仍需保留');
    expect(tester.takeException(), isNull);
  });
}
