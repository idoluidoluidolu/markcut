// 草稿夾的「佔用空間」與刪草稿的連帶清理（使用者：多一個顯示使用容量的
// 地方，讓使用者判斷要不要刪）。這裡釘住：
//   1. 自動存檔：Map 內容在背景編碼寫檔、封面沒換不重寫、檔案清單跟著存
//   2. 刪草稿連帶清「只有它在用」的轉檔暫存（工作檔、HDR 代理、倒轉檔、
//      救回的素材）；別份草稿在用的、或剩下的草稿有一份沒有檔案清單時都不動
//   3. 容量表：每份刪掉能省多少（共用的不算）、沒有草稿在用的暫存、清掉它們
//   4. 舊草稿沒有檔案清單：背景讀內容補算、補寫回去
//   5. 同一個鍵的讀寫刪照順序（非同步寫檔之後的讀一定讀到新的）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/storage_usage.dart';
import 'package:markcut/services/work_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sep = Platform.pathSeparator;
  late Directory root;
  late String wf;
  late String imp;

  setUp(() async {
    // 放在專案的 build/ 底下：系統暫存目錄那顆碟可能是滿的
    final base = await Directory(
      '${Directory.current.path}${sep}build${sep}storage_usage_test',
    ).create(recursive: true);
    root = await base.createTemp('run_');
    wf = '${root.path}${sep}workfiles';
    imp = '${root.path}${sep}imports';
    await Directory(wf).create();
    await Directory(imp).create();
    BlobStore.dirOverride = root;
    WorkFiles.supportDirOverride = root;
    DraftAssets.supportDirOverride = root;
    WorkFiles.holdSweep = false;
    SharedPreferences.setMockInitialValues({});
    WorkFiles.resetForTest();
  });

  tearDown(() async {
    BlobStore.dirOverride = null;
    BlobStore.resetForTest();
    WorkFiles.supportDirOverride = null;
    DraftAssets.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> touch(String path, int bytes) async {
    await File(path).writeAsBytes(List<int>.filled(bytes, 7));
    return path;
  }

  /// 工作檔索引（key → 工作檔）。要在存草稿之前種：它會重設整個 prefs
  void seedIndex(Map<String, String> works) {
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        for (final e in works.entries) e.key: {'work': e.value, 'at': 1},
      }),
    });
    WorkFiles.resetForTest();
  }

  Future<Map<String, dynamic>> index() async {
    final raw = (await SharedPreferences.getInstance()).getString('workFiles.v4');
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  File blob(String key) =>
      File('${root.path}${sep}blobs$sep$key.txt');

  group('自動存檔', () {
    test('Map 內容在背景編碼寫檔：讀回一樣，設定檔只留索引', () async {
      final data = {
        'clips': [1, 2],
        'wm': {'b64': 'A' * 5000},
        'savedAt': '2026-09-24T00:00:00.000',
      };
      expect(await DraftStore.save('a', data, clipCount: 2), isTrue);
      expect(await DraftStore.load('a'), data);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'projects_index_v1'});
      expect(blob('project_data_a').existsSync(), isTrue);
    });

    test('封面沒換（同一個字串）不重寫；換了才寫', () async {
      final t1 = 'cover-one-${DateTime.now().microsecondsSinceEpoch}';
      await DraftStore.save('a', '{}', thumb: t1);
      expect(await DraftStore.thumb('a'), t1);
      // 動手腳：若第二次存檔又重寫封面，這個內容就會被蓋掉
      blob('project_thumb_a').writeAsStringSync('tampered');
      await DraftStore.save('a', '{"clips":[1]}', thumb: t1);
      expect(await DraftStore.thumb('a'), 'tampered', reason: '同一張封面不該再寫一次');
      final t2 = 'cover-two-${DateTime.now().microsecondsSinceEpoch}';
      await DraftStore.save('a', '{"clips":[1]}', thumb: t2);
      expect(await DraftStore.thumb('a'), t2);
      // 封面被別的路徑刪掉：同一張也要補寫回去
      blob('project_thumb_a').deleteSync();
      await DraftStore.save('a', '{"clips":[1]}', thumb: t2);
      expect(await DraftStore.thumb('a'), t2);
    });

    test('檔案清單跟著存、跟著刪', () async {
      await DraftStore.save('a', '{}', refs: {'/src/b.mov', '/src/a.mov'});
      expect(await DraftStore.refs('a'), {'/src/a.mov', '/src/b.mov'});
      await DraftStore.save('a', '{}', refs: {'/src/c.mov'});
      expect(await DraftStore.refs('a'), {'/src/c.mov'});
      await DraftStore.remove('a');
      expect(await DraftStore.refs('a'), isNull);
      expect(blob('project_refs_a').existsSync(), isFalse);
    });

    test('換封面只換「檔案裡還是同一張」的', () async {
      await DraftStore.save('a', '{}', thumb: 'png-old');
      expect(await DraftStore.replaceThumbIfSame('a', 'png-else', 'jpg'), isFalse);
      expect(await DraftStore.thumb('a'), 'png-old');
      expect(await DraftStore.replaceThumbIfSame('a', 'png-old', 'jpg'), isTrue);
      expect(await DraftStore.thumb('a'), 'jpg');
    });
  });

  group('刪草稿連帶清轉檔暫存', () {
    test('只清只有它在用的：工作檔、HDR 代理、倒轉檔、救回的素材；共用的留著', () async {
      final wA = await touch('$wf${sep}wA.mp4', 10);
      final whA = await touch('$wf${sep}whA.mp4', 20);
      final revA = await touch('$wf${sep}revA.mp4', 30);
      final wS = await touch('$wf${sep}wS.mp4', 40);
      final rA = await touch('$imp${sep}rA.mp4', 50);
      seedIndex({
        '/src/a.mov': wA,
        '/src/a.mov#hdr6': whA,
        '/src/a.mov#rev:0.000~1.000': revA,
        '/src/s.mov': wS,
      });
      await DraftStore.save('A', '{}', refs: {'/src/a.mov', rA, '/src/s.mov'});
      await DraftStore.save('B', '{}', refs: {'/src/s.mov', '/src/b.mov'});
      await DraftStore.remove('A');
      for (final p in [wA, whA, revA, rA]) {
        expect(File(p).existsSync(), isFalse, reason: '$p 只有 A 在用');
      }
      expect(File(wS).existsSync(), isTrue, reason: 'B 還在用同一支原檔');
      expect((await index()).keys, ['/src/s.mov']);
    });

    test('救回的素材有別份草稿直接指著：不能刪', () async {
      final rA = await touch('$imp${sep}rA.mp4', 50);
      await DraftStore.save('A', '{}', refs: {rA});
      await DraftStore.save('B', '{}', refs: {rA});
      await DraftStore.remove('A');
      expect(File(rA).existsSync(), isTrue);
    });

    test('剩下的草稿有一份沒有檔案清單（舊版存的）：什麼都不清，寧可多留', () async {
      final wA = await touch('$wf${sep}wA.mp4', 10);
      seedIndex({'/src/a.mov': wA});
      await DraftStore.save('A', '{}', refs: {'/src/a.mov'});
      await DraftStore.save('old', '{"sources":[]}'); // 沒帶 refs
      await DraftStore.remove('A');
      expect(File(wA).existsSync(), isTrue);
    });

    test('一次刪好幾份：共用的原檔只在全部都刪時才清', () async {
      final wS = await touch('$wf${sep}wS.mp4', 40);
      final wC = await touch('$wf${sep}wC.mp4', 40);
      seedIndex({'/src/s.mov': wS, '/src/c.mov': wC});
      await DraftStore.save('A', '{}', refs: {'/src/s.mov'});
      await DraftStore.save('B', '{}', refs: {'/src/s.mov'});
      await DraftStore.save('C', '{}', refs: {'/src/c.mov'});
      await DraftStore.removeMany({'A', 'B'});
      expect(File(wS).existsSync(), isFalse);
      expect(File(wC).existsSync(), isTrue);
      expect((await DraftStore.list()).map((m) => m.id), ['C']);
    });

    test('匯出期間（holdSweep）刪草稿不動任何轉檔暫存', () async {
      final wA = await touch('$wf${sep}wA.mp4', 10);
      seedIndex({'/src/a.mov': wA});
      await DraftStore.save('A', '{}', refs: {'/src/a.mov'});
      WorkFiles.holdSweep = true;
      await DraftStore.remove('A');
      expect(File(wA).existsSync(), isTrue);
    });
  });

  group('容量表', () {
    test('每份刪掉能省多少（共用的不算）、沒有草稿在用的暫存、總量', () async {
      final wA = await touch('$wf${sep}wA.mp4', 1000);
      final wS = await touch('$wf${sep}wS.mp4', 2000);
      final wZ = await touch('$wf${sep}wZ.mp4', 4000); // 沒有草稿用的原檔
      await touch('$wf${sep}orphan.mp4', 8000); // 索引也沒有的殘檔
      final rB = await touch('$imp${sep}rB.mp4', 16000);
      seedIndex({'/src/a.mov': wA, '/src/s.mov': wS, '/src/z.mov': wZ});
      await DraftStore.save('A', '{"x":1}', refs: {'/src/a.mov', '/src/s.mov'});
      await DraftStore.save('B', '{"x":2}', refs: {'/src/s.mov', rB});

      final r = await StorageUsage.scan();
      expect(r.pending, 0);
      final ownA = r.own['A']!;
      final ownB = r.own['B']!;
      expect(ownA, greaterThan(0));
      expect(r.freeableFor({'A'}), ownA + 1000, reason: 'wS 還有 B 在用，不算');
      expect(r.freeableFor({'B'}), ownB + 16000);
      expect(r.freeableFor({'A', 'B'}), ownA + ownB + 1000 + 2000 + 16000);
      expect(r.filesInUse, 1000 + 2000 + 16000);
      expect(r.filesUnused, 4000 + 8000);
      expect(r.canClearUnused, isTrue);
      expect(r.total, r.draftBytes + r.filesInUse + r.filesUnused + r.otherDrafts);

      final freed = await StorageUsage.clearUnused();
      expect(freed, 4000 + 8000);
      expect(File(wZ).existsSync(), isFalse);
      expect(File('$wf${sep}orphan.mp4').existsSync(), isFalse);
      for (final p in [wA, wS, rB]) {
        expect(File(p).existsSync(), isTrue, reason: '$p 有草稿在用');
      }
      expect((await index()).keys.toSet(), {'/src/a.mov', '/src/s.mov'});
      final again = await StorageUsage.scan();
      expect(again.filesUnused, 0);
      expect(again.canClearUnused, isFalse);
    });

    test('舊草稿沒有檔案清單：背景讀內容補算、補寫回去', () async {
      final wA = await touch('$wf${sep}wA.mp4', 1000);
      seedIndex({'/src/a.mov': wA});
      await DraftStore.save(
        'old',
        jsonEncode({
          'sources': [
            {'path': '/src/a.mov', 'workHdr': '$wf${sep}gone.mp4'},
            {'path': '/src/t.png', 'revOf': '/src/r.mov'},
          ],
        }),
      );
      expect(await DraftStore.refs('old'), isNull);
      final progress = <(int, int)>[];
      final r = await StorageUsage.scan(onProgress: (d, t) => progress.add((d, t)));
      expect(r.pending, 0);
      expect(progress.last, (1, 1));
      expect(r.freeableFor({'old'}), r.own['old']! + 1000);
      expect(await DraftStore.refs('old'), {
        '/src/a.mov',
        '$wf${sep}gone.mp4',
        '/src/t.png',
        '/src/r.mov',
      });
    });

    test('內容解不開的舊草稿：算成未知，不給清沒在用的暫存', () async {
      await touch('$wf${sep}orphan.mp4', 100);
      seedIndex({});
      await DraftStore.save('broken', 'not json {');
      final r = await StorageUsage.scan();
      expect(r.pending, 1);
      expect(r.canClearUnused, isFalse);
      expect(await StorageUsage.clearUnused(), 0);
      expect(File('$wf${sep}orphan.mp4').existsSync(), isTrue);
    });

    test('正在寫的檔（倒轉中）算在用；有東西在寫就整個不清', () async {
      seedIndex({});
      final dest = await WorkFiles.beginReverse(ext: 'mp4');
      await touch(dest, 500);
      final r = await StorageUsage.scan();
      expect(r.filesUnused, 0);
      expect(r.filesInUse, 500);
      expect(await StorageUsage.clearUnused(), 0);
      expect(File(dest).existsSync(), isTrue);
      WorkFiles.abortReverse(dest);
    });

    test('照片／批次／拼圖草稿（內容＋素材複本）算在其他草稿', () async {
      final dir = Directory('${root.path}${sep}draft_assets${sep}batch')
        ..createSync(recursive: true);
      await touch('${dir.path}${sep}a.jpg', 3000);
      await BlobStore.write('batch_draft_v1', 'x' * 100);
      final r = await StorageUsage.scan();
      expect(r.otherDrafts, 3100);
    });
  });

  group('BlobStore', () {
    test('同一個鍵：寫到一半就讀，讀到的是新的；寫到一半就刪，刪掉的不會被救回來', () async {
      await BlobStore.write('project_data_k', 'v1');
      final pending = BlobStore.write('project_data_k', 'v2');
      expect(await BlobStore.read('project_data_k'), 'v2');
      await pending;
      unawaited(BlobStore.writeJson('project_data_j', {'a': 1}));
      expect(await BlobStore.delete('project_data_j'), isTrue);
      expect(await BlobStore.read('project_data_j'), isNull);
      expect(blob('project_data_j').existsSync(), isFalse);
    });

    test('照片／批次／拼圖／GIF 的草稿也搬出設定檔', () async {
      SharedPreferences.setMockInitialValues({
        'photo_draft_v1': '{"photo":"/p.png"}',
        'batch_draft_v1': '{"files":["/a.jpg"]}',
        'collage_draft_v1': '{"photos":["/c.jpg"]}',
        'gif_draft_v1': '{"path":"/g.mov"}',
        'timeline_snap_on': true,
      });
      await BlobStore.migrate();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'timeline_snap_on'});
      expect(await BlobStore.read('gif_draft_v1'), '{"path":"/g.mov"}');
      expect(blob('batch_draft_v1').existsSync(), isTrue);
    });

    test('大小：檔案的位元組數；沒有就 0', () async {
      await BlobStore.write('project_thumb_s', 'x' * 1234);
      expect(await BlobStore.sizeOf('project_thumb_s'), 1234);
      expect(await BlobStore.sizeOf('project_thumb_none'), 0);
    });
  });

  test('索引 key 的原檔路徑', () {
    expect(WorkFiles.sourceOfKey('/a/b.mov'), '/a/b.mov');
    expect(WorkFiles.sourceOfKey('/a/b.mov#hdr6'), '/a/b.mov');
    expect(WorkFiles.sourceOfKey('/a/b.mov#hdr'), '/a/b.mov');
    expect(WorkFiles.sourceOfKey('/a/b.mov#rev:0.000~1.500'), '/a/b.mov');
  });

  test('容量的寫法', () {
    expect(formatBytes(0), '0 MB');
    expect(formatBytes(1000), '不到 1 MB');
    expect(formatBytes(350 * 1024 * 1024), '350 MB');
    expect(formatBytes(1288490189), '1.2 GB');
    expect(formatBytes(12 * 1024 * 1024 * 1024), '12 GB');
  });
}
