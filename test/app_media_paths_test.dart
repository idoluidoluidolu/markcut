import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/services/app_media_paths.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/work_files.dart';

const oldRoot = '/private/var/mobile/Containers/Data/Application/OLD-UUID';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  String current(String tail) =>
      [root.path, ...tail.split('/')].join(Platform.pathSeparator);
  File media(String tail) {
    final file = File(current(tail));
    file.parent.createSync(recursive: true);
    return file..writeAsBytesSync([1, 2, 3]);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('draft-relocation-');
    AppMediaPaths.setRootForTest(root.path);
    BlobStore.resetForTest();
    DraftAssets.supportDirOverride = Directory(
      current('Library/Application Support'),
    );
    WorkFiles.supportDirOverride = DraftAssets.supportDirOverride;
    WorkFiles.resetForTest();
  });
  tearDown(() {
    AppMediaPaths.setRootForTest(null);
    DraftAssets.supportDirOverride = null;
    WorkFiles.supportDirOverride = null;
    WorkFiles.maxTotalBytesOverride = null;
    WorkFiles.resetForTest();
    root.deleteSync(recursive: true);
  });

  test('rebases device, simulator, file URI and /var aliases safely', () {
    for (final path in [
      '$oldRoot/Documents/素材 a.mov',
      '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/素材 a.mov',
      '/Users/dev/Library/Developer/CoreSimulator/Devices/device/data/Containers/Data/Application/OLD-UUID/Documents/素材 a.mov',
      Uri.file('$oldRoot/Documents/素材 a.mov', windows: false).toString(),
    ]) {
      expect(AppMediaPaths.rebase(path), current('Documents/素材 a.mov'));
    }
    for (final path in [
      '$oldRoot/Documents/../outside.mov',
      '$oldRoot/Documents/../../Library/secret',
      '$oldRoot/Library/Preferences/secret',
      '/var/mobile/Containers/Shared/AppGroup/ID/Documents/a.mov',
      '/storage/emulated/0/DCIM/a.mov',
      'https://example.test/a.mov',
      'file://server$oldRoot/Documents/a.mov',
      'Documents/a.mov',
    ]) {
      expect(AppMediaPaths.rebase(path), path);
    }
  });

  test(
    'production configuration derives the current container from support directory',
    () {
      const newRoot = '/var/mobile/Containers/Data/Application/NEW-UUID';
      AppMediaPaths.configure('$newRoot/Library/Application Support');
      expect(
        AppMediaPaths.rebase('$oldRoot/Documents/a.mov'),
        [newRoot, 'Documents', 'a.mov'].join(Platform.pathSeparator),
      );
      AppMediaPaths.configure('/data/user/0/app/files');
      expect(
        AppMediaPaths.rebase('$oldRoot/Documents/a.mov'),
        '$oldRoot/Documents/a.mov',
      );
    },
  );

  test(
    'all draft schemas transform only media fields without changing source data',
    () {
      final path = '$oldRoot/Documents/a.mov';
      final original = <String, dynamic>{
        'photo': path,
        'path': path,
        'files': [path],
        'photos': [path, null],
        'name': path,
        'state': path,
        'overrides': {
          path: {'text': path},
        },
        'sources': [
          {
            'path': path,
            'workPath': path,
            'workHdr': path,
            'revOf': path,
            'name': path,
            'textStyle': {'text': path},
          },
        ],
      };
      final snapshot = jsonEncode(original);
      final restored = AppMediaPaths.mapDraft(original);
      expect(restored['photo'], current('Documents/a.mov'));
      expect(restored['path'], current('Documents/a.mov'));
      expect(restored['files'], [current('Documents/a.mov')]);
      expect(restored['photos'], [current('Documents/a.mov'), null]);
      expect((restored['overrides'] as Map)[current('Documents/a.mov')], {
        'text': path,
      });
      final source = (restored['sources'] as List).single as Map;
      for (final key in ['path', 'workPath', 'workHdr', 'revOf']) {
        expect(source[key], current('Documents/a.mov'));
      }
      expect(source['textStyle'], {'text': path});
      expect(source['name'], path);
      expect(restored['state'], path);
      expect(jsonEncode(original), snapshot);
    },
  );

  for (final kind in [
    DraftAssets.photo,
    DraftAssets.batch,
    DraftAssets.collage,
  ]) {
    test(
      '$kind durable copies resolve and survive cleanup after relocation',
      () async {
        final tail =
            'Library/Application Support/draft_assets/$kind/slot/a.png';
        final kept = media(tail);
        final unused = media(
          'Library/Application Support/draft_assets/$kind/unused.png',
        );
        expect(await DraftAssets.resolve(kind, '$oldRoot/$tail'), kept.path);
        await DraftAssets.retain(kind, {'$oldRoot/$tail'});
        expect(kept.existsSync(), isTrue);
        expect(unused.existsSync(), isFalse);
      },
    );
  }

  test(
    'draft loading, reference lists and work indexes agree after relocation',
    () async {
      const sourceTail = 'Documents/source.mov';
      const workTail = 'Library/Application Support/workfiles/sdr.mp4';
      const hdrTail = 'Library/Application Support/workfiles/hdr.mp4';
      final source = media(sourceTail);
      final work = media(workTail);
      final hdr = media(hdrTail);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'project_data_moved',
        jsonEncode({
          'sources': [
            {'path': '$oldRoot/$sourceTail', 'workPath': '$oldRoot/$workTail'},
          ],
          'clips': [],
        }),
      );
      await prefs.setString(
        'project_refs_moved',
        jsonEncode(['$oldRoot/$sourceTail', '$oldRoot/$hdrTail']),
      );
      await prefs.setString(
        'workFiles.v4',
        jsonEncode({
          '$oldRoot/$sourceTail': {
            'work': '$oldRoot/$workTail',
            'cv': 2,
            'at': 1,
          },
          '$oldRoot/$sourceTail#hdr6': {'work': '$oldRoot/$hdrTail', 'at': 1},
        }),
      );
      final draft = (await DraftStore.load('moved'))!;
      expect((draft['sources'] as List).single['path'], source.path);
      expect(await DraftStore.refs('moved'), {source.path, hdr.path});
      expect(await WorkFiles.lookup(source.path), work.path);
      expect(await WorkFiles.lookupHdr(source.path), hdr.path);
      WorkFiles.maxTotalBytesOverride = 0;
      await WorkFiles.sweep();
      expect(work.existsSync(), isTrue);
      expect(hdr.existsSync(), isTrue);
      await source.delete();
      // stat() returns notFound rather than throwing: the sole backup is valid.
      expect(await WorkFiles.lookup(source.path), work.path);
    },
  );
}
