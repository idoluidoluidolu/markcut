// 草稿被上限清理刪掉時，WorkFiles.releaseFiles 連帶清 App 自有檔案的
// 邊界：只碰 workfiles/ 與 imports/、原檔還有人用的留著、匯出期間不動
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
  late String impDir;

  setUp(() async {
    // 放在專案的 build/ 底下：系統暫存目錄那顆碟可能是滿的
    final base = await Directory(
      '${Directory.current.path}${sep}build${sep}wf_release_test',
    ).create(recursive: true);
    root = await base.createTemp('run_');
    wfDir = '${root.path}${sep}workfiles';
    impDir = '${root.path}${sep}imports';
    await Directory(wfDir).create();
    await Directory(impDir).create();
    WorkFiles.supportDirOverride = root;
    WorkFiles.holdSweep = false;
    SharedPreferences.setMockInitialValues({});
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

  Future<File> touch(String p) => File(p).writeAsString('x');

  Future<Map<String, dynamic>> index() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('workFiles.v4');
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  test('只刪 workfiles/ 與 imports/ 底下的檔，別的路徑一律不碰', () async {
    final w1 = await touch('$wfDir${sep}w1.mp4');
    final r1 = await touch('$impDir${sep}r1.mp4');
    final other = await touch('${root.path}${sep}other.mp4');
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        '/src/a.mov': {'work': w1.path, 'at': 1},
      }),
    });
    WorkFiles.resetForTest();
    final n = await WorkFiles.releaseFiles({
      w1.path,
      r1.path,
      other.path,
    }, referenced: (_) => false);
    expect(n, 2);
    expect(w1.existsSync(), isFalse);
    expect(r1.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    // 索引那筆也要一起走
    expect((await index()).containsKey('/src/a.mov'), isFalse);
  });

  test('工作檔的原檔還有別份草稿在用：檔案跟索引都留著', () async {
    final w1 = await touch('$wfDir${sep}w1.mp4');
    final wh = await touch('$wfDir${sep}wh1.mp4');
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        '/src/a.mov': {'work': w1.path, 'at': 1},
        '/src/b.mov#hdr6': {'work': wh.path, 'at': 1},
      }),
    });
    WorkFiles.resetForTest();
    final n = await WorkFiles.releaseFiles({
      w1.path,
      wh.path,
    }, referenced: (p) => p == '/src/b.mov');
    expect(n, 1);
    expect(w1.existsSync(), isFalse);
    expect(wh.existsSync(), isTrue);
    expect((await index()).keys, ['/src/b.mov#hdr6']);
  });

  test('匯出期間（holdSweep）什麼都不動', () async {
    final w1 = await touch('$wfDir${sep}w1.mp4');
    WorkFiles.holdSweep = true;
    expect(await WorkFiles.releaseFiles({w1.path}, referenced: (_) => false), 0);
    expect(w1.existsSync(), isTrue);
  });

  test('檔案已經不在：索引照清、不算刪除、不丟例外', () async {
    final gone = '$wfDir${sep}gone.mp4';
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        '/src/a.mov': {'work': gone, 'at': 1},
      }),
    });
    WorkFiles.resetForTest();
    expect(await WorkFiles.releaseFiles({gone}, referenced: (_) => false), 0);
    expect((await index()).isEmpty, isTrue);
  });
}
