import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/initial_preview_policy.dart';

void main() {
  test('Android prepares working media before first playback', () {
    expect(waitForInitialPreview(requested: false, android: true), isTrue);
    expect(waitForInitialPreview(requested: true, android: true), isTrue);
  });
  test('other platforms retain quick entry and explicit wait option', () {
    expect(waitForInitialPreview(requested: false, android: false), isFalse);
    expect(waitForInitialPreview(requested: true, android: false), isTrue);
  });
}
