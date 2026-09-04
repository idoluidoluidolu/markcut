// 工作檔轉檔前的「合不合規格」只掃一次：Dart 端掃過整支檔判定要轉，
// 原生端就不該再把關鍵幀數第二遍（prechecked 旗標）。
// Dart 端沒能掃（Android 沒 probe／探測失敗）時旗標不能亂送，原生端
// 自己判
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('markcut/prep');
  final sep = Platform.pathSeparator;
  late Directory root;
  late File src;
  late Map<Object?, Object?>? toWorkArgs;
  Map<String, dynamic>? liteReply;
  Map<String, dynamic>? probeReply;

  setUp(() async {
    final base = await Directory(
      '${Directory.current.path}${sep}build${sep}wf_prechecked_test',
    ).create(recursive: true);
    root = await base.createTemp('run_');
    src = await File('${root.path}${sep}src.mp4').writeAsString('video');
    WorkFiles.supportDirOverride = root;
    WorkFiles.holdSweep = false;
    SharedPreferences.setMockInitialValues({});
    WorkFiles.resetForTest();
    MediaPrep.resetProbeCacheForTest();
    toWorkArgs = null;
    liteReply = null;
    probeReply = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
          switch (call.method) {
            case 'available':
              return true;
            case 'probeLite':
              return liteReply;
            case 'probe':
              return probeReply;
            case 'toWorkFile':
              final a = call.arguments as Map<Object?, Object?>;
              toWorkArgs = a;
              final dest = a['dest'] as String;
              await File(dest).writeAsString('work');
              return dest;
          }
          return null;
        });
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    MediaPrep.resetProbeCacheForTest();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> lite1080h264() => {
    'w': 1920,
    'h': 1080,
    'codec': 'avc1',
    'rotated': false,
    'sdr709': true,
    'durSec': 5.0,
  };

  test('Dart 端掃完關鍵幀判定太疏：送 prechecked，原生端不用再掃', () async {
    liteReply = lite1080h264();
    probeReply = {'frames': 300, 'keyframes': 5, 'maxGopFrames': 60};
    final made = await WorkFiles.ensure(src.path);
    expect(made, isNotNull);
    expect(toWorkArgs, isNotNull);
    expect(toWorkArgs!['prechecked'], isTrue);
  });

  test('輕量探測就出局（4K HEVC）：也算掃過，一樣送 prechecked', () async {
    liteReply = {
      'w': 3840,
      'h': 2160,
      'codec': 'hvc1',
      'rotated': false,
      'sdr709': false,
      'durSec': 5.0,
    };
    final made = await WorkFiles.ensure(src.path);
    expect(made, isNotNull);
    expect(toWorkArgs!['prechecked'], isTrue);
  });

  test('探測不到（probe 回 null）：不送旗標，原生端自己判', () async {
    liteReply = lite1080h264();
    probeReply = null;
    final made = await WorkFiles.ensure(src.path);
    expect(made, isNotNull);
    expect(toWorkArgs!.containsKey('prechecked'), isFalse);
  });

  test('規格本來就合：不轉檔、直接複製一份', () async {
    liteReply = lite1080h264();
    probeReply = {'frames': 300, 'keyframes': 60, 'maxGopFrames': 6};
    final made = await WorkFiles.ensure(src.path);
    expect(made, isNotNull);
    expect(toWorkArgs, isNull);
    expect(await File(made!).readAsString(), 'video');
    final prefs = await SharedPreferences.getInstance();
    final idx = jsonDecode(prefs.getString('workFiles.v4')!) as Map;
    expect((idx[src.path] as Map)['work'], made);
  });
}
