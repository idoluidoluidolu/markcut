import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/work_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source, backup, newer, orphan;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('markcut_sweep_');
    final work = await Directory('${root.path}/workfiles').create();
    source = await File('${root.path}/source.mp4').writeAsString('source');
    backup = await File(
      '${work.path}/backup.mp4',
    ).writeAsBytes(List.filled(80, 1));
    newer = await File('${work.path}/new.mp4').writeAsBytes(List.filled(80, 2));
    orphan = await File('${work.path}/orphan.mp4').writeAsString('keep');
    BlobStore.resetForTest();
    WorkFiles.supportDirOverride = root;
    WorkFiles.maxTotalBytesOverride = 100;
    WorkFiles.holdSweep = false;
    WorkFiles.resetForTest();
  });
  tearDown(() async {
    DraftStore.releaseOpen('active');
    BlobStore.dirOverride = null;
    WorkFiles.supportDirOverride = null;
    WorkFiles.maxTotalBytesOverride = null;
    WorkFiles.resetForTest();
    await root.delete(recursive: true);
  });
  void seed({List<String>? refs, bool draft = true}) {
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        source.path: {'work': backup.path, 'at': 1},
        '${root.path}/missing.mp4': {'work': newer.path, 'at': 2},
      }),
      if (draft) 'project_data_test': '{}',
      if (refs != null) 'project_refs_test': jsonEncode(refs),
    });
    WorkFiles.resetForTest();
  }

  test('referenced indexed and orphan files survive quota cleanup', () async {
    seed(refs: [backup.path, orphan.path]);
    await WorkFiles.sweep();
    expect(await backup.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
  });
  test(
    'sole backup survives even when no draft references are available',
    () async {
      seed(draft: false);
      await source.delete();
      await WorkFiles.sweep();
      expect(await backup.exists(), isTrue);
      expect(await newer.exists(), isTrue);
    },
  );
  test('unreferenced reproducible cache can still be reclaimed', () async {
    seed(draft: false);
    await WorkFiles.sweep();
    expect(await backup.exists(), isFalse);
    expect(await newer.exists(), isTrue);
  });
  test('legacy draft without refs prevents destructive cleanup', () async {
    seed();
    await WorkFiles.sweep();
    expect(await backup.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
  });
  test('malformed reference entries block cleanup', () async {
    seed();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('project_refs_test', '[{"invalid":"path"}]');
    await WorkFiles.sweep();
    expect(await backup.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
  });
  test('active editor pins files before its next save', () async {
    seed(draft: false);
    DraftStore.holdOpen('active');
    await WorkFiles.sweep();
    expect(await backup.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
  });
  test(
    'unavailable draft storage blocks cleanup instead of appearing empty',
    () async {
      seed(draft: false);
      // A regular file cannot serve as the support directory.
      BlobStore.dirOverride = Directory(source.path);
      await WorkFiles.sweep();
      expect(await backup.exists(), isTrue);
      expect(await orphan.exists(), isTrue);
    },
  );
}
