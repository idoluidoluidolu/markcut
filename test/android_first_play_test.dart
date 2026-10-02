import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/quality_diagnostics.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/widgets/prep_gate_view.dart';

import 'editor_harness.dart';

class _Player implements PlayerX {
  _Player(this.path);
  @override
  final String path;
  Completer<void>? ready;
  bool initialized = false;
  bool fail = false;
  bool playing = false;
  bool disposed = false;
  int playCalls = 0;
  Duration position = Duration.zero;

  @override
  Future<void> initialize() async {
    await ready?.future;
    if (fail) throw StateError('decoder failed');
    initialized = true;
  }

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: initialized,
    isPlaying: playing,
    duration: const Duration(seconds: 6),
    position: position,
    size: const Size(2160, 3840),
  );
  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<Duration?> positionNow() async {
    if (playing) position += const Duration(milliseconds: 33);
    return position;
  }

  @override
  Future<void> seekTo(Duration at) async {
    position = at;
  }

  @override
  Future<void> setLooping(bool loop) async {}
  @override
  Future<void> setPlaybackSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  void dispose() {
    playing = false;
    disposed = true;
  }

  @override
  String get debugInfo => 'fake';
  @override
  Widget view({Key? key}) => ColoredBox(key: key, color: Colors.blue);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Player player;
  _Player? workPlayer;
  var creates = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Exercise the same fallback branch as Android on any test host.
    Diag.compPlayer.value = false;
    Diag.singlePlayer.value = false;
    Diag.playerLayer.value = false;
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    dir = Directory.systemTemp.createTempSync('markcut_first_play_');
    WorkFiles.supportDirOverride = dir;
    final path = '${dir.path}/video.mp4';
    File(path).writeAsBytesSync([0]);
    player = _Player(path);
    workPlayer = null;
    creates = 0;
    bigPhoneView(binding);
    mockEditorPlugins(binding, tempDir: dir);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async => switch (call.method) {
        'available' => true,
        'probeLite' => <String, dynamic>{
          'durSec': 6.0,
          'w': 2160,
          'h': 3840,
          'sdr709': true,
          'codec': 'avc1',
        },
        _ => null,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/export'),
      (_) async => false,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async => call.method == 'frameAt' ? solidPng(20, 40, 80) : null,
    );
  });
  tearDown(() {
    Diag.compPlayer.value = true;
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(
          videoPath: player.path,
          thumbnailNow: t.binding.clock.now,
          playerFactory: (path, {bool system = false}) {
            creates++;
            return path == player.path ? player : (workPlayer = _Player(path));
          },
        ),
      ),
    );
    await settle(t, 15);
    await t.pump(const Duration(seconds: 5));
    await settle(t, 6);
    expect(find.byType(PrepGateView), findsNothing);
    expect(modelOf(t).clips.length, 1);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settle(t, 3);
    expect(t.takeException(), isNull);
  }

  testWidgets('中繼資料匯入成功仍建立 Android 片段播放器，第一下播放就啟動', (t) async {
    await open(t);
    expect(creates, 1, reason: 'probeLite 不會代替建立真正的播放器');
    expect(player.initialized, isTrue);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 15);
    expect(player.playCalls, greaterThan(0));
    expect(playheadOf(t), greaterThan(0));
    await close(t);
  });

  testWidgets('已完成的預覽檔在下一次起播前換上，不繼續播 4K 原片', (t) async {
    await open(t);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 5);
    expect(player.playing, isTrue);
    final source = modelOf(t).sources.first;
    source.workPath = '${dir.path}/work.mp4';
    await tick(t, 5);
    expect(creates, 1, reason: '預覽檔在播放途中落地，不能中途抽換畫面');
    final diagnostic = QualityDiagnostics.instance.contextProvider!();
    expect(diagnostic['fallbackLeadUsesWorkFile'], isFalse);
    expect(diagnostic['fallbackLeadSourceChangePending'], isTrue);
    expect(diagnostic.toString(), isNot(contains(dir.path)));
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 10);
    expect(creates, 2);
    expect(player.disposed, isTrue);
    expect(workPlayer!.playing, isTrue);
    expect(playheadOf(t), greaterThan(0));
    final updated = QualityDiagnostics.instance.contextProvider!();
    expect(updated['fallbackLeadUsesWorkFile'], isTrue);
    expect(updated['fallbackLeadSourceChangePending'], isFalse);
    await close(t);
  });

  for (final cancel in [false, true]) {
    testWidgets('初始化慢時時間軸等待，${cancel ? '取消後不偷播' : '完成後直接播第一次'}', (t) async {
      player.ready = Completer<void>();
      await open(t);
      await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
      await tick(t, 15);
      expect(player.playCalls, 0);
      expect(playheadOf(t), 0);
      if (cancel) {
        await t.tap(find.byIcon(Icons.pause_rounded).first);
        await t.pump();
      }
      player.ready!.complete();
      await tick(t, 15);
      expect(creates, 1, reason: '等待期間不能重複開解碼器');
      expect(player.playCalls, cancel ? 0 : greaterThan(0));
      expect(playheadOf(t), cancel ? 0 : greaterThan(0));
      await close(t);
    });
  }
}
