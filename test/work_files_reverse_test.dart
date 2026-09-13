// 倒轉檔走工作檔管線（WorkFiles.beginReverse／commitReverse／
// abortReverse／lookupReverse）的邊界。
//
// 以前倒轉檔寫在系統暫存目錄：被清掉之後草稿重開整段片段被剔除
//（「有 1 段素材已找不到」）。改放工作檔目錄、進同一份索引：寫到一半
// 的檔掛在 in-flight 名單（清掃不碰）、登記之後清掃認得它（不當孤兒）、
// 同一段再倒一次直接拿現成的
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/work_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sep = Platform.pathSeparator;
  late Directory root;
  late String wfDir;

  setUp(() async {
    // 放在專案的 build/ 底下：系統暫存目錄那顆碟可能是滿的
    final base = await Directory(
      '${Directory.current.path}${sep}build${sep}wf_reverse_test',
    ).create(recursive: true);
    root = await base.createTemp('run_');
    wfDir = '${root.path}${sep}workfiles';
    await Directory(wfDir).create();
    WorkFiles.supportDirOverride = root;
    WorkFiles.holdSweep = false;
    // 索引裡先放一筆別的工作檔：空索引的保險絲會讓 sweep 什麼都不清，
    // 這裡要測的是「清掃認不認得倒轉檔」
    final w0 = await File('$wfDir${sep}w0.mp4').writeAsString('w');
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        '/src/other.mov': {'work': w0.path, 'at': 1, 'cv': 2},
      }),
    });
    WorkFiles.resetForTest();
  });

  tearDown(() async {
    WorkFiles.supportDirOverride = null;
    WorkFiles.holdSweep = false;
    WorkFiles.resetForTest();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, dynamic>> index() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('workFiles.v4');
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  test('目的地在工作檔目錄、副檔名照給', () async {
    final dest = await WorkFiles.beginReverse(ext: 'm4a');
    expect(dest, startsWith('$wfDir$sep'));
    expect(dest, endsWith('.m4a'));
    WorkFiles.abortReverse(dest);
  });

  test('登記之後：查得到、清掃留著它；沒登記的孤兒清掃會刪', () async {
    final dest = await WorkFiles.beginReverse(ext: 'mp4');
    await File(dest).writeAsString('reversed');
    await WorkFiles.commitReverse('/src/a.mov', 1.25, 3.5, dest);

    expect(await WorkFiles.lookupReverse('/src/a.mov', 1.25, 3.5), dest);
    expect(
      await WorkFiles.lookupReverse('/src/a.mov', 1.25, 3.6),
      isNull,
      reason: '不同的區段不是同一份倒轉檔',
    );
    expect(
      await WorkFiles.lookupReverse('/src/b.mov', 1.25, 3.5),
      isNull,
      reason: '不同的原檔不是同一份倒轉檔',
    );
    final idx = await index();
    expect(idx['/src/a.mov#rev:1.250~3.500'], isA<Map>());
    expect((idx['/src/a.mov#rev:1.250~3.500'] as Map)['work'], dest);
    expect(
      (idx['/src/a.mov#rev:1.250~3.500'] as Map)['cv'],
      WorkFiles.reverseColorVersion,
    );

    // 一支沒登記的殘檔（上次做到一半被殺）：清掃當孤兒刪掉；登記過的留著
    final orphan = await File('$wfDir${sep}rev_orphan.mp4').writeAsString('x');
    await WorkFiles.sweep();
    expect(File(dest).existsSync(), isTrue, reason: '登記過的倒轉檔不能被清');
    expect(orphan.existsSync(), isFalse, reason: '沒登記的才是孤兒');
  });

  test('寫到一半（in-flight）：清掃整個讓路，不會把它當孤兒刪掉', () async {
    final dest = await WorkFiles.beginReverse(ext: 'mp4');
    await File(dest).writeAsString('half');
    await WorkFiles.sweep();
    expect(File(dest).existsSync(), isTrue);
    WorkFiles.abortReverse(dest);
    expect(File(dest).existsSync(), isFalse, reason: '放棄＝殘檔刪掉');
    expect(
      (await index()).keys.where((k) => k.contains('#rev:')),
      isEmpty,
      reason: '放棄的不進索引',
    );
  });

  test('檔案被總量清理丟掉之後查不到（呼叫端照 revOf 重做）', () async {
    final dest = await WorkFiles.beginReverse(ext: 'mp4');
    await File(dest).writeAsString('reversed');
    await WorkFiles.commitReverse('/src/a.mov', 0, 2, dest);
    expect(await WorkFiles.lookupReverse('/src/a.mov', 0, 2), dest);
    await File(dest).delete();
    expect(await WorkFiles.lookupReverse('/src/a.mov', 0, 2), isNull);
  });

  test('舊版色彩標記的倒轉檔不沿用', () async {
    final old = await File('$wfDir${sep}old_reverse.mp4').writeAsString('old');
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        '/src/old.mov#rev:0.000~2.000': {'work': old.path, 'at': 1, 'cv': 2},
      }),
    });
    WorkFiles.resetForTest();

    expect(await WorkFiles.lookupReverse('/src/old.mov', 0, 2), isNull);
  });

  test('原檔已經不在（相簿暫存被回收）：索引裡的倒轉檔照樣認——那正是要救的情況', () async {
    final dest = await WorkFiles.beginReverse(ext: 'mp4');
    await File(dest).writeAsString('reversed');
    // 原檔路徑根本不存在：stamp 算不出來，不能因此把倒轉檔判成過期
    await WorkFiles.commitReverse('/gone/IMG_0001.MOV', 0, 2, dest);
    expect(await WorkFiles.lookupReverse('/gone/IMG_0001.MOV', 0, 2), dest);
  });
}
