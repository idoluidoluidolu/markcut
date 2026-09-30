import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'blob_store.dart';

/// Rebuildable timeline strips, separate from project bodies and source media.
/// Entries validate the full source identity, so hash collisions cannot show a
/// different movie. All disk operations share a queue with manual cleanup.
class TimelineThumbnailCache {
  static const maxBytes = 128 * 1024 * 1024;
  static const maxEntryBytes = 8 * 1024 * 1024;
  static Future<void> _tail = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() action) {
    // No filesystem means no shared disk operation to wait for (web / widgets).
    if (!BlobStore.usesFiles) return action();
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  static Future<Directory?> _directory() async {
    if (!BlobStore.usesFiles) return null;
    final anchor = await BlobStore.fileOf('project_thumb_cache_location');
    if (anchor == null) return null;
    final dir = Directory('${anchor.parent.parent.path}/timeline_thumbnails');
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    return dir;
  }

  static Future<String?> _identity(String path, double duration) async {
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return jsonEncode([
      2,
      path,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      duration,
    ]);
  }

  static String _name(String identity) {
    var hash = 0x811c9dc5;
    for (final c in utf8.encode(identity)) {
      hash = ((hash ^ c) * 0x01000193) & 0xffffffff;
    }
    return '${hash.toRadixString(16)}.strip';
  }

  static Future<List<Uint8List>> read(String path, double duration) =>
      _serial(() async {
        try {
          final dir = await _directory();
          if (dir == null) return const [];
          final identity = await _identity(path, duration);
          if (identity == null) return const [];
          final file = File('${dir.path}/${_name(identity)}');
          if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
            return const [];
          }
          if (await file.length() > maxEntryBytes) return const [];
          final bytes = await file.readAsBytes();
          final data = ByteData.sublistView(bytes);
          var offset = 0;
          int size() {
            final n = data.getUint32(offset);
            offset += 4;
            return n;
          }

          final keyLength = size();
          final key = utf8.decode(bytes.sublist(offset, offset + keyLength));
          if (key != identity) return const [];
          offset += keyLength;
          final count = size();
          if (count < 1 || count > 120) return const [];
          final frames = <Uint8List>[];
          for (var i = 0; i < count; i++) {
            final length = size();
            if (length == 0) return const [];
            frames.add(Uint8List.sublistView(bytes, offset, offset + length));
            offset += length;
          }
          if (offset != bytes.length) return const [];
          await file.setLastModified(DateTime.now());
          return frames;
        } catch (_) {
          return const [];
        }
      });

  static Future<void> write(
    String path,
    double duration,
    List<Uint8List> frames,
  ) => _serial(() async {
    try {
      if (frames.isEmpty ||
          frames.length > 120 ||
          frames.any((f) => f.isEmpty)) {
        return;
      }
      final dir = await _directory();
      if (dir == null) return;
      final identity = await _identity(path, duration);
      if (identity == null) return;
      final key = utf8.encode(identity);
      final total =
          8 + key.length + frames.fold<int>(0, (n, f) => n + 4 + f.length);
      if (total > maxEntryBytes) return;
      final out = BytesBuilder(copy: false);
      void size(int n) =>
          out.add((ByteData(4)..setUint32(0, n)).buffer.asUint8List());
      size(key.length);
      out.add(key);
      size(frames.length);
      for (final f in frames) {
        size(f.length);
        out.add(f);
      }
      await dir.create(recursive: true);
      final file = File('${dir.path}/${_name(identity)}');
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(out.takeBytes(), flush: true);
      await temp.rename(file.path);
      final entries = await _entries(dir);
      var bytes = entries.fold<int>(0, (n, e) => n + e.$2.size);
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final e in entries) {
        if (bytes <= maxBytes) break;
        await e.$1.delete();
        bytes -= e.$2.size;
      }
    } catch (_) {
      /* Optional cache: never prevent editing or saving. */
    }
  });

  static Future<List<(File, FileStat)>> _entries(Directory dir) async {
    if (!await dir.exists()) return [];
    final result = <(File, FileStat)>[];
    await for (final f in dir.list(followLinks: false)) {
      if (f is File &&
          (f.path.endsWith('.strip') || f.path.endsWith('.strip.tmp'))) {
        result.add((f, await f.stat()));
      }
    }
    return result;
  }

  static Future<int> usageBytes() => _serial(() async {
    final dir = await _directory();
    if (dir == null) return 0;
    return (await _entries(dir)).fold<int>(0, (n, e) => n + e.$2.size);
  });

  static Future<int> clear() => _serial(() async {
    final dir = await _directory();
    if (dir == null) return 0;
    var freed = 0;
    for (final e in await _entries(dir)) {
      try {
        await e.$1.delete();
        freed += e.$2.size;
      } catch (_) {}
    }
    return freed;
  });
}
