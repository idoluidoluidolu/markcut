// 舊草稿補封面（DraftCoverRepair）。
//
// 十月初那幾版的自動存檔畫好封面又丟掉、打開過的草稿第一次存檔就把封面
// 刪掉（見 draft_cover_*_test）：實機上最新的一批草稿全是灰底。修好之後
// 打開再存一次就有完整封面；沒再打開的，由個人中心／草稿夾補一張——
// 只抽素材的一格，挑的是一開場看得到的那一層。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/draft_cover_repair.dart';
import 'package:markcut/services/draft_store.dart';

import 'editor_harness.dart' show solidPng;

const _frames = MethodChannel('markcut/frames');

Map<String, dynamic> _source(
  String path,
  ClipKind kind, {
  int w = 1920,
  int h = 1080,
  String? work,
}) => MediaSource(
  path: path,
  name: 'x',
  kind: kind,
  duration: 10,
  w: w,
  h: h,
  workPath: work,
).toJson();

Map<String, dynamic> _clip(
  int id,
  int source, {
  double offset = 0,
  int track = 0,
  double trimStart = 0,
}) => TimelineClip(
  id: id,
  sourceIndex: source,
  trimStart: trimStart,
  trimEnd: trimStart + 5,
  offset: offset,
  track: track,
).toJson();

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  /// 原生抽格被叫了哪幾次（路徑@毫秒）
  final frameCalls = <String>[];
  final frame = solidPng(0, 0, 255, size: 24);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DraftCoverRepair.resetForTest();
    dir = await Directory.systemTemp.createTemp('cover-repair-');
    frameCalls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_frames, (
      call,
    ) async {
      if (call.method != 'frameAt') return null;
      final args = call.arguments as Map;
      frameCalls.add('${args['path']}@${args['ms']}');
      return frame;
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_frames, null);
    await dir.delete(recursive: true);
  });

  String file(String name, List<int> bytes) {
    final f = File('${dir.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync(bytes);
    return f.path;
  }

  Future<void> seed(String id, Map<String, dynamic> draft) => DraftStore.save(
    id,
    jsonEncode(draft),
    clipCount: (draft['clips'] as List).length,
  );

  group('挑封面那一層', () {
    test('一開場看得到的影片、上面的軌道優先；照片疊在上面也讓影片；隱藏軌不算', () {
      final pick = pickDraftCover(
        jsonEncode({
          'sources': [
            _source('/a/bottom.mov', ClipKind.video),
            _source('/a/top.mov', ClipKind.video, w: 1080, h: 1920),
            _source('/a/photo.jpg', ClipKind.image),
            _source('/a/hidden.mov', ClipKind.video),
            _source('/a/later.mov', ClipKind.video),
          ],
          'clips': [
            _clip(1, 0),
            // 多選匯入各自一軌全疊在 0 秒：看得到的是最上面那支
            _clip(2, 1, track: 1, trimStart: 1.5),
            _clip(3, 2, track: 2),
            _clip(4, 3, track: 3),
            _clip(5, 4, offset: 8, track: 5),
          ],
          'hiddenTracks': [3],
        }),
      );
      expect(pick, isNotNull);
      expect(pick!.path, '/a/top.mov');
      expect(pick.video, isTrue);
      // 跟編輯器的封面同一刻（t≈0.02 秒）：素材 1.5 秒起剪
      expect(pick.at, closeTo(1.52, 1e-9));
      expect(pick.aspect, closeTo(1080 / 1920, 1e-9));
    });

    test('只有照片：最上面那張；一開場沒東西就取最早出現的', () {
      final photos = pickDraftCover(
        jsonEncode({
          'sources': [
            _source('/a/1.jpg', ClipKind.image),
            _source('/a/2.jpg', ClipKind.image),
          ],
          'clips': [_clip(1, 0), _clip(2, 1, track: 1)],
        }),
      );
      expect(photos?.path, '/a/2.jpg');
      expect(photos?.video, isFalse);
      final late = pickDraftCover(
        jsonEncode({
          'sources': [
            _source('/a/b.mov', ClipKind.video),
            _source('/a/a.mov', ClipKind.video),
          ],
          'clips': [_clip(1, 0, offset: 6, track: 1), _clip(2, 1, offset: 3)],
        }),
      );
      expect(late?.path, '/a/a.mov');
    });

    test('空白專案、只有文字、壞掉的內容：挑不出來', () {
      expect(pickDraftCover(jsonEncode({'sources': [], 'clips': []})), isNull);
      expect(
        pickDraftCover(
          jsonEncode({
            'sources': [
              {'path': '', 'name': '字', 'kind': ClipKind.text.index},
            ],
            'clips': [_clip(1, 0)],
          }),
        ),
        isNull,
      );
      expect(pickDraftCover('不是 JSON'), isNull);
    });
  });

  test('影片草稿：工作檔在就從工作檔抽那一格，存的就是原生回的那張', () async {
    final orig = file('orig.mov', [1]);
    final work = file('work.mp4', [2]);
    await seed('video', {
      'sources': [_source(orig, ClipKind.video, work: work)],
      'clips': [_clip(1, 0, trimStart: 2)],
    });
    final b64 = await DraftCoverRepair.fill('video');
    expect(b64, isNotNull);
    expect(frameCalls, ['$work@2020'], reason: '原檔多半是 4K HDR，工作檔便宜得多');
    expect(base64Decode(b64!), frame);
    expect(await DraftStore.thumb('video'), b64);
    final m = (await DraftStore.list()).single;
    expect(m.hasThumb, isTrue);
    expect(m.thumbAspect, 1.0, reason: '比例照抽出來那一格量');
  });

  test('工作檔已經被清掉：退回原檔', () async {
    final orig = file('orig.mov', [1]);
    await seed('swept', {
      'sources': [_source(orig, ClipKind.video, work: '${dir.path}/gone.mp4')],
      'clips': [_clip(1, 0)],
    });
    expect(await DraftCoverRepair.fill('swept'), isNotNull);
    expect(frameCalls, ['$orig@20']);
  });

  test('照片草稿：照片本身縮成封面，不用原生抽格', () async {
    final photo = file('photo.png', solidPng(250, 10, 10, size: 40));
    await seed('photo', {
      'sources': [_source(photo, ClipKind.image, w: 40, h: 40)],
      'clips': [_clip(1, 0)],
    });
    final b64 = await DraftCoverRepair.fill('photo');
    expect(b64, isNotNull);
    expect(frameCalls, isEmpty);
    final m = (await DraftStore.list()).single;
    expect(m.hasThumb, isTrue);
    expect(m.thumbAspect, 1.0);
  });

  test('素材不見了：什麼都不寫，這次開 App 也不再重試', () async {
    await seed('gone', {
      'sources': [_source('${dir.path}/missing.mov', ClipKind.video)],
      'clips': [_clip(1, 0)],
    });
    expect(await DraftCoverRepair.fill('gone'), isNull);
    expect(await DraftCoverRepair.fill('gone'), isNull);
    expect(frameCalls, isEmpty);
    expect(await DraftStore.thumb('gone'), isNull);
    expect((await DraftStore.list()).single.hasThumb, isFalse);
  });

  test('已經有封面（編輯器剛存的真封面）：直接用它，不另外抽、不蓋掉', () async {
    final orig = file('orig.mov', [1]);
    await DraftStore.save(
      'has',
      jsonEncode({
        'sources': [_source(orig, ClipKind.video)],
        'clips': [_clip(1, 0)],
      }),
      thumb: 'EXISTING',
      thumbAspect: 1,
    );
    expect(await DraftCoverRepair.fill('has'), 'EXISTING');
    expect(frameCalls, isEmpty);
  });
}
