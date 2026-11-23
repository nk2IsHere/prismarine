import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Compiled shader shards, kept by the inputs of their compile. A build
/// compiles only the shards whose sources changed. The key of a shard covers
/// the ids, bundle specs and sources of its entries with every included
/// file, the compile settings and the identity of impellerc and of the Metal
/// compiler, which is their path, size and time. A shard is kept only when
/// it compiled whole. A shard with a failed entry is compiled again by the
/// next build.
class ShaderShardCache {
  ShaderShardCache._(this.dir, this._tools);

  /// Opens the cache in [dir] for the tools at [impellerc] and [metal].
  /// [metal] is null without a Metal compiler. The keys cover [settings]
  /// as JSON. Returns null when [dir] is null.
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
      // The version of the contents of a cached shard, which are the bundles
      // for each backend, the final sources and the Metal errors. A change
      // to the processing of a shard raises it.
      'v1\n${identity(impellerc)}\n${identity(metal)}\n${jsonEncode(settings)}',
    );
  }

  final String dir;
  final String _tools;

  /// Returns the key of a shard of [ids]. [specs] maps each entry to its
  /// bundle spec and [files] maps it to its source file. An
  /// `#include "<path>"` resolves against [includeRoot].
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

  /// Returns the shard kept under [key] with its bundles for each backend
  /// directory and the final sources and Metal errors of its entries.
  /// Returns null when the cache has no such shard.
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

  /// Keeps a shard under [key]. The shard is written whole or not at all.
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
