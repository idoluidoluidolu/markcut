import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/gif_store.dart';
import 'package:markcut/services/storage_usage.dart';
import 'package:markcut/services/timeline_thumbnail_cache.dart';
import 'package:markcut/services/work_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File movie;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('markcut-cache-');
    movie = await File('${root.path}/source.mov').writeAsBytes([1, 2, 3]);
    BlobStore.dirOverride = root;
    WorkFiles.supportDirOverride = root;
    DraftAssets.supportDirOverride = root;
    GifStore.documentsDirOverride = root;
    SharedPreferences.setMockInitialValues({});
    WorkFiles.resetForTest();
  });
  tearDown(() async {
    await TimelineThumbnailCache.clear();
    BlobStore.dirOverride = null;
    BlobStore.resetForTest();
    WorkFiles.supportDirOverride = null;
    DraftAssets.supportDirOverride = null;
    GifStore.documentsDirOverride = null;
    WorkFiles.resetForTest();
    await root.delete(recursive: true);
  });
  final frames = [
    Uint8List.fromList([1, 2, 3]),
    Uint8List.fromList([4, 5]),
  ];

  test(
    'warm strip survives cache reload; replaced source cannot reuse it',
    () async {
      await TimelineThumbnailCache.write(movie.path, 2, frames);
      expect(await TimelineThumbnailCache.read(movie.path, 2), frames);
      expect(await TimelineThumbnailCache.read(movie.path, 3), isEmpty);
      await movie.writeAsBytes([9, 8, 7, 6]);
      expect(await TimelineThumbnailCache.read(movie.path, 2), isEmpty);
      expect(await TimelineThumbnailCache.usageBytes(), greaterThan(0));
    },
  );

  test(
    'oversize and corrupt entries are misses, never failed draft loads',
    () async {
      await TimelineThumbnailCache.write(movie.path, 2, [
        Uint8List(TimelineThumbnailCache.maxEntryBytes + 1),
      ]);
      expect(await TimelineThumbnailCache.usageBytes(), 0);
      await TimelineThumbnailCache.write(movie.path, 2, frames);
      final entry =
          (await Directory(
                '${root.path}/timeline_thumbnails',
              ).list().toList()).single
              as File;
      await entry.writeAsBytes([255, 255, 255, 255]);
      expect(await TimelineThumbnailCache.read(movie.path, 2), isEmpty);
    },
  );

  test(
    'category totals and cleanup preserve saved projects, GIFs and presets',
    () async {
      await TimelineThumbnailCache.write(movie.path, 2, frames);
      await DraftStore.save('test', {'sources': []}, refs: {movie.path});
      await BlobStore.writeList('wm_presets_v1', ['preset']);
      await BlobStore.writeList('stickers_v1', ['sticker']);
      final gifs = await Directory('${root.path}/gifs').create();
      await File('${gifs.path}/mine.gif').writeAsBytes(List.filled(100, 1));
      final works = await Directory('${root.path}/workfiles').create();
      final unused = await File(
        '${works.path}/old.mov',
      ).writeAsBytes(List.filled(40, 1));
      final before = await StorageUsage.scan();
      expect(before.gifBytes, 100);
      expect(before.presetBytes, greaterThan(0));
      expect(before.stickerBytes, greaterThan(0));
      expect(before.thumbnailBytes, greaterThan(0));
      expect(before.filesUnused, 40);
      expect(
        before.total,
        before.projectBytes +
            before.gifBytes +
            before.presetBytes +
            before.stickerBytes +
            before.clearableBytes,
      );
      expect(await StorageUsage.clearCaches(), before.clearableBytes);
      expect(await unused.exists(), isFalse);
      expect(await movie.exists(), isTrue);
      expect(await DraftStore.load('test'), isNotNull);
      expect(await BlobStore.readList('wm_presets_v1'), ['preset']);
      expect(await File('${gifs.path}/mine.gif').length(), 100);
      final after = await StorageUsage.scan();
      expect(after.total, before.total - before.clearableBytes);
    },
  );

  test(
    'manual cleanup cannot race an open editor or unknown draft references',
    () async {
      final works = await Directory('${root.path}/workfiles').create();
      final file = await File('${works.path}/keep.mov').writeAsBytes([1, 2, 3]);
      DraftStore.holdOpen('editing');
      try {
        expect(await StorageUsage.clearUnused(), 0);
      } finally {
        DraftStore.releaseOpen('editing');
      }
      await BlobStore.write('project_data_orphan', '{}');
      expect(await StorageUsage.clearUnused(), 0);
      expect(await file.exists(), isTrue);
    },
  );
}
