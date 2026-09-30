import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/screens/feedback_screen.dart';

void main() {
  testWidgets('feedback closes when tapping outside, inside remains editable', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showFeedbackDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await t.tap(find.byType(TextField).first);
    await t.pump();
    expect(find.byType(Dialog), findsOneWidget);
    await t.tapAt(const Offset(3, 3));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });
}
