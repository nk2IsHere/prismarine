import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Compiled shader shards kept by what they were compiled from, so a
/// slice, a refresh or a cook compiles only the shards whose sources
/// changed: a shard's key is its entries' ids, bundle specs and sources (with
/// every file they include), the compile arguments, and impellerc's and
/// Apple's Metal compiler's identity (path, size, time). A shard is kept only
/// when it compiled whole; one with a failed entry compiles again next time.
class ShaderShardCache {
  ShaderShardCache._(this.dir, this._tools);

  /// The cache in [dir] for the tools at [impellerc] and [metal] (null:
  /// none), or null when [dir] is null.
  static ShaderShardCache? open(
    String? dir,
    String impellerc,
    String? metal,
    Object settings,
  ) {
    if (dir == null) return null;
    String identity(String? path) {
      if (path == null) return '-';
      final f = File(path);
      if (!f.existsSync()) return path;
      final s = f.statSync();
      return '$path ${s.size} ${s.modified.microsecondsSinceEpoch}';
    }

    return ShaderShardCache._(
      dir,
      // v1: what a cached shard holds (bundles per backend, final sources,
      // Metal errors); bump when the shard's processing changes.
      'v1\n${identity(impellerc)}\n${identity(metal)}\n${jsonEncode(settings)}',
    );
  }

  final String dir;
  final String _tools;

  /// The key of a shard of [ids] with [specs] (entry → bundle spec), whose
  /// sources are the files [files] names (entry → path), resolving
  /// `#include "<path>"` under [includeRoot].
  String key(
    List<String> ids,
    Map<String, Object?> specs,
    Map<String, String> files,
    String includeRoot,
  ) {
    final b = StringBuffer(_tools);
    final seen = <String>{};
    void add(String path) {
      if (!seen.add(path)) return;
      final f = File(path);
      if (!f.existsSync()) {
        b.write('\nmissing $path');
        return;
      }
      final text = f.readAsStringSync();
      b
        ..write('\n')
        ..write(text.length)
        ..write('\n')
        ..write(text);
      for (final m in RegExp(r'#include "([^"]+)"').allMatches(text)) {
        add('$includeRoot/${m[1]}');
      }
    }

    for (final id in ids) {
      b
        ..write('\nentry $id ')
        ..write(jsonEncode(specs[id]));
      add(files[id]!);
    }
    return sha256.convert(utf8.encode(b.toString())).toString();
  }

  /// The shard kept under [key]: its bundles by backend directory, its
  /// entries' final sources and Metal errors; null when not kept.
  ({
    Map<String, Uint8List> bundles,
    Map<String, String> sources,
    Map<String, String> metalErrors,
  })?
  lookup(String key) {
    final d = Directory('$dir/$key');
    final meta = File('${d.path}/shard.json');
    if (!meta.existsSync()) return null;
    final j = jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
    return (
      bundles: {
        for (final b in (j['backends']! as List).cast<String>())
          b: File('${d.path}/$b.shaderbundle.gz').readAsBytesSync(),
      },
      sources: (j['sources']! as Map).cast<String, String>(),
      metalErrors: (j['metalErrors']! as Map).cast<String, String>(),
    );
  }

  /// Keeps a shard under [key], written whole or not at all.
  void store(
    String key,
    Map<String, Uint8List> bundles,
    Map<String, String> sources,
    Map<String, String> metalErrors,
  ) {
    final tmp = Directory('$dir/.$key.$pid')..createSync(recursive: true);
    for (final MapEntry(:key, :value) in bundles.entries) {
      File('${tmp.path}/$key.shaderbundle.gz').writeAsBytesSync(value);
    }
    File('${tmp.path}/shard.json').writeAsStringSync(
      jsonEncode({
        'backends': bundles.keys.toList(),
        'sources': sources,
        'metalErrors': metalErrors,
      }),
    );
    final to = Directory('$dir/$key');
    if (to.existsSync()) {
      tmp.deleteSync(recursive: true);
      return;
    }
    tmp.renameSync(to.path);
  }
}
