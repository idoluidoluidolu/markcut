import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// Persisted iOS paths include an installation-specific container identifier.
/// Recover the same relative file in the current container, never by basename.
class AppMediaPaths {
  AppMediaPaths._();

  static final _container = RegExp(
    r'^(/(?:[^/]+/)*Containers/Data/Application/[^/]+)/(.+)$',
  );
  static String? _root;

  static void configure(String supportPath) {
    _root = _container.firstMatch(supportPath)?.group(1);
  }

  @visibleForTesting
  static void setRootForTest(String? root) => _root = root;

  static String rebase(String path) {
    final root = _root;
    if (root == null || path.isEmpty) return path;
    var local = path;
    if (local.startsWith('file:')) {
      try {
        final uri = Uri.parse(local);
        if (uri.host.isNotEmpty || uri.hasQuery || uri.hasFragment) return path;
        local = uri.toFilePath(windows: false);
      } catch (_) {
        return path;
      }
    }
    if (local.contains('\\')) return path;
    final match = _container.firstMatch(local);
    if (match == null) return path;
    final parts = match.group(2)!.split('/');
    if (parts.any((s) => s.isEmpty || s == '.' || s == '..')) return path;
    final owned =
        parts.first == 'Documents' ||
        parts.first == 'tmp' ||
        (parts.length > 1 &&
            parts.first == 'Library' &&
            (parts[1] == 'Application Support' || parts[1] == 'Caches'));
    return owned ? [root, ...parts].join(Platform.pathSeparator) : path;
  }

  /// Only schema-defined paths are transformed. Text, names and encoded images
  /// must remain byte-for-byte unchanged even when they look like file paths.
  static Map<String, dynamic> mapDraft(
    Map<String, dynamic> draft, {
    String Function(String)? transform,
  }) {
    final mapPath = transform ?? rebase;
    final out = Map<String, dynamic>.of(draft);
    void field(Map<String, dynamic> map, String key) {
      final value = map[key];
      if (value is String && value.isNotEmpty) map[key] = mapPath(value);
    }

    for (final key in ['photo', 'path']) {
      field(out, key);
    }
    for (final key in ['files', 'photos']) {
      final value = out[key];
      if (value is List) {
        out[key] = [
          for (final item in value) item is String ? mapPath(item) : item,
        ];
      }
    }
    final sources = out['sources'];
    if (sources is List) {
      out['sources'] = [
        for (final source in sources)
          if (source is Map)
            (() {
              final copy = Map<String, dynamic>.from(source);
              for (final key in ['path', 'workPath', 'workHdr', 'revOf']) {
                field(copy, key);
              }
              return copy;
            })()
          else
            source,
      ];
    }
    final overrides = out['overrides'];
    if (overrides is Map) {
      out['overrides'] = {
        for (final entry in overrides.entries)
          entry.key is String ? mapPath(entry.key as String) : entry.key:
              entry.value,
      };
    }
    return out;
  }
}
