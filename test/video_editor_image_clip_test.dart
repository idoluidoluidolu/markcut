import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';

/// 用草稿啟動真實的影片編輯頁（不需要影片播放器），
/// 重現「時間軸上新加入的圖片素材點不到」的回報
const _png =
    r'C:\Users\lesuc\AppData\Local\Temp\claude\C--Users-lesuc-OneDrive----III\01db0a8f-07f1-41b0-84dd-6a3034e24616\scratchpad\t.png';

Map<String, dynamic> _draft() => {
  'savedAt': '2026-08-12T00:00:00.000',
  'sources': [
    MediaSource(
      path: _png,
      name: 't.png',
      kind: ClipKind.image,
      w: 400,
      h: 400,
      duration: 3600,
    ).toJson(),
  ],
  'clips': [
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 4,
      offset: 0,
      track: 0,
    ).toJson(),
  ],
  'speed': 1.0,
  'ratio': 0,
  'res': 0,
  'quality': 0,
  'wmStart': 0.0,
  'extraTracks': 0,
};

Future<void> _settle(WidgetTester t, [int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
    // 測試環境沒有這些原生外掛，擋掉不然頁面一開就丟例外
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
  });

  testWidgets('影片編輯頁：時間軸上的圖片素材點得到、預覽也畫得出來', (t) async {
    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(draft: _draft())));
    await _settle(t);

    // 素材有留在時間軸上（沒有被當成失效素材剔除）
    final block = find.byKey(const ValueKey('clip1'));
    expect(block, findsOneWidget, reason: '圖片素材要出現在時間軸上');

    // 預覽畫面上也要看得到這張圖（Image.memory 圖層）
    expect(
      find.byType(Image),
      findsWidgets,
      reason: '播放頭在 0 秒、素材涵蓋 0~4 秒，預覽應該要畫出這張圖',
    );

    // 點一下時間軸上的它
    final r = t.getRect(block);
    await t.tapAt(r.center);
    await _settle(t, 6);

    // 選取後工具列的「切割」之類應該可用；直接看選取框：
    // _ClipBlock 選取時邊框變成 kSelect（金色），用 Container 的 decoration 判斷
    final container = t.widget<Container>(
      find
          .descendant(of: block, matching: find.byType(Container))
          .first,
    );
    final deco = container.decoration as BoxDecoration?;
    final border = deco?.border as Border?;
    expect(
      border?.top.width,
      2.0,
      reason: '被選取的片段邊框寬度應該是 2（沒選是 1）',
    );
  });

}
