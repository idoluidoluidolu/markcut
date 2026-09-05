// 工作檔的補試規則：上一次「做出來的不能用」（原生端回報失敗、轉好卻
// 全黑／解不開、呼叫端驗出壞檔送 invalidate）的素材，下一次 ensure 要
// 叫原生端走保守參數（safe），不能拿同樣的參數再轉一次——實機 2018
// 兩支素材各轉兩次，第二次跟第一次壞得一模一樣。轉成功就解除。
//
// 另外驗「縮圖該讀哪一份檔」：正在轉的素材要等轉完改讀工作檔，
// 沒工作檔的照讀原檔
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/work_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const prep = MethodChannel('markcut/prep');
  const frames = MethodChannel('markcut/frames');
  final sep = Platform.pathSeparator;
  late Directory root;
  late File src;
  late Uint8List bright;

  /// 每一次 toWorkFile 的劇本：true＝寫檔回路徑，false＝回 null
  late List<bool> outcomes;
  late List<Map<Object?, Object?>> calls;

  /// 原生端轉檔要花多久（模擬「正在轉」的窗口）
  Duration transcodeTakes = Duration.zero;

  /// 抽工作檔的格子回什麼：null＝解不開（殘檔）；bright＝正常畫面
  Uint8List? workFrame;

  setUpAll(() async {
    // 一張全白的小圖：健檢抽幀的「看得見」基準
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final img = await rec.endRecording().toImage(8, 8);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    bright = bd!.buffer.asUint8List();
  });

  setUp(() async {
    final base = await Directory(
      '${Directory.current.path}${sep}build${sep}wf_retry_test',
    ).create(recursive: true);
    root = await base.createTemp('run_');
    src = await File('${root.path}${sep}src.mp4').writeAsString('video');
    WorkFiles.supportDirOverride = root;
    WorkFiles.holdSweep = false;
    SharedPreferences.setMockInitialValues({});
    WorkFiles.resetForTest();
    MediaPrep.resetProbeCacheForTest();
    outcomes = [];
    calls = [];
    transcodeTakes = Duration.zero;
    workFrame = bright;
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(prep, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'probeLite':
          // 4K：快速通道出局，一定要轉
          return <String, dynamic>{
            'w': 2160,
            'h': 3840,
            'codec': 'avc1',
            'rotated': false,
            'sdr709': true,
            'durSec': 6.6,
          };
        case 'toWorkFile':
          final a = call.arguments as Map<Object?, Object?>;
          calls.add(a);
          final ok = outcomes.isEmpty ? true : outcomes.removeAt(0);
          if (transcodeTakes > Duration.zero) {
            await Future<void>.delayed(transcodeTakes);
          }
          if (!ok) return null;
          final dest = a['dest'] as String;
          await File(dest).writeAsString('work');
          return dest;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(frames, (call) async {
      if (call.method != 'frameAt') return null;
      final a = call.arguments as Map<Object?, Object?>;
      final path = a['path'] as String;
      return path == src.path ? bright : workFrame;
    });
  });

  tearDown(() async {
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(prep, null);
    messenger.setMockMethodCallHandler(frames, null);
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    MediaPrep.resetProbeCacheForTest();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('原生端回報失敗：下一次 ensure 送 safe，成功後解除', () async {
    outcomes = [false, true];
    expect(await WorkFiles.ensure(src.path), isNull);
    expect(calls.single.containsKey('safe'), isFalse);
    expect(WorkFiles.needsSafeRetry(src.path), isTrue);

    final made = await WorkFiles.ensure(src.path);
    expect(made, isNotNull);
    expect(calls, hasLength(2));
    expect(calls[1]['safe'], isTrue);
    expect(WorkFiles.needsSafeRetry(src.path), isFalse);
  });

  test('轉好卻解不開（健檢不過）：檔案刪掉、下一次 ensure 送 safe', () async {
    workFrame = null; // 工作檔一格都解不開，原檔看得見
    expect(await WorkFiles.ensure(src.path), isNull);
    final dest = calls.single['dest'] as String;
    expect(File(dest).existsSync(), isFalse);
    expect(WorkFiles.needsSafeRetry(src.path), isTrue);

    workFrame = bright;
    final made = await WorkFiles.ensure(src.path);
    expect(made, isNotNull);
    expect(calls[1]['safe'], isTrue);
  });

  test('呼叫端驗出壞檔送 invalidate：重轉走 safe；forget 之後不再保守', () async {
    final first = await WorkFiles.ensure(src.path);
    expect(first, isNotNull);
    expect(calls.single.containsKey('safe'), isFalse);

    await WorkFiles.invalidate(src.path);
    expect(File(first!).existsSync(), isFalse);
    expect(WorkFiles.needsSafeRetry(src.path), isTrue);
    final second = await WorkFiles.ensure(src.path);
    expect(second, isNotNull);
    expect(calls[1]['safe'], isTrue);

    // 使用者把素材移除（forget）再加回來：上一次是成功的，不用保守
    await WorkFiles.forget(src.path);
    final third = await WorkFiles.ensure(src.path);
    expect(third, isNotNull);
    expect(calls[2].containsKey('safe'), isFalse);
  });

  test('縮圖來源：沒有工作檔、也沒在轉，照讀原檔', () async {
    expect(WorkFiles.isPreparing(src.path), isFalse);
    expect(await thumbnailSourceFor(src.path), src.path);
  });

  test('縮圖來源：正在轉的素材等它轉完，改讀工作檔', () async {
    transcodeTakes = const Duration(milliseconds: 200);
    final ensuring = WorkFiles.ensure(src.path);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(WorkFiles.isPreparing(src.path), isTrue);

    final sw = Stopwatch()..start();
    final chosen = await thumbnailSourceFor(src.path);
    final made = await ensuring;
    expect(made, isNotNull);
    expect(chosen, made);
    // 真的等了轉檔那一段，不是立刻回原檔
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(100));
    expect(WorkFiles.isPreparing(src.path), isFalse);
  });

  test('縮圖來源：等太久就放棄、照讀原檔（不會卡死呼叫端）', () async {
    transcodeTakes = const Duration(milliseconds: 400);
    final ensuring = WorkFiles.ensure(src.path);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final chosen = await thumbnailSourceFor(
      src.path,
      wait: const Duration(milliseconds: 50),
    );
    expect(chosen, src.path);
    expect(await ensuring, isNotNull);
  });
}
