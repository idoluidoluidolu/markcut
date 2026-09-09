// 迴歸守門：空白專案第一批影片（工具列「＋」→ 影片 → 各自一軌）要蓋讀取
// 畫面、先把每支的粗縮圖帶抽出來再放行。
//
// 實測 197／198 的路徑就是這條（剪輯 → 空白 → ＋ → 六支各自一軌），不是首頁
// 帶 videoPaths 進來那條；進場閘以前只掛在 _importInitialVideos，這條路
// 完全沒讀取畫面，而完整縮圖帶要等全部代理轉完才抽——縮圖全是第一格。
//
// 假的原生端：兩支 HDR 素材、代理一律失敗（整場播原檔，不換檔）；抽幀每格
// 慢 60ms，讀取畫面才看得到（真機一支 4K 粗帶大約也是這個量級）
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/widgets/prep_gate_view.dart';

import 'editor_harness.dart';

late Directory _dir;
String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

void main() {
  final frame = solidPng(0, 255, 0);
  var pickVideos = <String>[];
  var framesServed = 0;

  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_blank_gate_');
    File(_p('a.mp4')).writeAsStringSync('video A');
    File(_p('b.mp4')).writeAsStringSync('video B');
    WorkFiles.supportDirOverride = _dir;
    WorkFiles.holdSweep = false;

    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b, tempDir: _dir);
    // 系統相片選取器（測試主機的 defaultTargetPlatform 是 android）
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/pick'),
      (call) async => call.method == 'videos' ? pickVideos : null,
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            final path = call.arguments as String;
            final name = path.split(Platform.pathSeparator).last;
            if (!name.endsWith('.mp4')) return null;
            return <String, dynamic>{
              'w': 1920,
              'h': 1080,
              'codec': 'hvc1',
              'rotated': false,
              'sdr709': false,
              'durSec': name.startsWith('a') ? 5.0 : 3.0,
            };
          case 'probe':
            return <String, dynamic>{
              'frames': 300,
              'keyframes': 60,
              'maxGopFrames': 6,
            };
          case 'toWorkFile':
            return null;
        }
        return null;
      },
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/export'),
      (call) async => switch (call.method) {
        'available' || 'hasHDR' || 'isHDR' => true,
        _ => null,
      },
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async {
        if (call.method != 'frameAt') return null;
        framesServed++;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return frame;
      },
    );
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    Diag.reset();
    framesServed = 0;
  });

  bool gateShown() => find.byType(PrepGateView).evaluate().isNotEmpty;

  testWidgets('空白專案「＋ → 影片 → 各自一軌」：讀取畫面蓋上，粗帶抽完就掀、縮圖不是只有第一格', (t) async {
    pickVideos = [_p('a.mp4'), _p('b.mp4')];
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 10);
    expect(gateShown(), isFalse, reason: '空白專案本身沒有讀取畫面');

    await t.tap(find.text('加素材'));
    await settle(t, 10);
    await t.tap(find.text('影片'));
    await settle(t, 10);
    // 兩支以上會問排法：各自一軌（實測就是這條）
    await t.tap(find.text('各自一軌'));
    await waitUntil(t, gateShown, maxMs: 4000, reason: '第一批影片要蓋讀取畫面（進場閘）');
    await waitUntil(
      t,
      () => !gateShown(),
      maxMs: 12000,
      reason: '粗帶抽完就掀（最高 5 秒）',
    );

    final tl = modelOf(t);
    expect(tl.clips.length, 2);
    expect(tl.clips.map((c) => c.track).toSet(), {0, 1}, reason: '各自一軌');
    // 兩支各十格粗帶——不是一張封面拉滿整條
    expect(editorOf(t).thumbs[0]?.length, 10);
    expect(editorOf(t).thumbs[1]?.length, 10);
    expect(framesServed, greaterThanOrEqualTo(20));
    expect(Diag.report(), contains('進場縮圖：2/2 支粗帶'));

    // 讓草稿存檔、代理補試那些收尾跑完，別留計時器
    await settle(t, 80);
    await t.pump(const Duration(seconds: 5));
  });
}
