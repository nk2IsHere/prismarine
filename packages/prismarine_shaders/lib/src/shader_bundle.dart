import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'metal_compile.dart';
import 'shader_bundle_cache.dart';
import 'shader_bundle_split.dart';

/// The settings of a bundle build. [backends] maps each impellerc backend,
/// such as `metal_desktop` or `vulkan`, to the directory of its bundles.
/// [impellercArgs] go to every impellerc run. [entryOptions] go into every
/// bundle entry, such as `metal_preserve_invariance` or `spirv_optimize`.
class ShaderBundleSettings {
  const ShaderBundleSettings({
    required this.backends,
    this.impellercArgs = const [],
    this.entryOptions = const {},
  });

  final Map<String, String> backends;
  final List<String> impellercArgs;
  final Map<String, Object> entryOptions;

  /// One shader bundle entry for [stage] in [file]. [stage] is `vert`, `frag`
  /// or `comp`, or its long form `vertex`, `fragment` or `compute`.
  Map<String, Object> entry(String file, String stage) => {
    'type': switch (stage) {
      'vert' || 'vertex' => 'vertex',
      'comp' || 'compute' => 'compute',
      _ => 'fragment',
    },
    'file': file,
    'targets': backends.keys.toList(),
    ...entryOptions,
  };
}

/// Returns [glsl] with each uniform block that is not in [bound] turned into
/// a plain struct with an instance of the same name. Code that reads the
/// block still compiles and the shader asks for no binding that the
/// compiled shader lacks.
String unboundBlocksAsStructs(String glsl, Set<String> bound) =>
    glsl.replaceAllMapped(RegExp(r'uniform (\w+) \{([^}]*)\} (\w+);'), (m) {
      if (bound.contains(m[1])) return m[0]!;
      return 'struct ${m[1]}_unbound {${m[2]}};\n${m[1]}_unbound ${m[3]};';
    });

/// Finds the impellerc of the patched engine. Returns `$PRISMARINE_IMPELLERC`,
/// else the newest `<root>/out/<build>/impellerc` of the [engineRoots].
/// Returns null when none exists.
String? findImpellerc({List<String> engineRoots = const []}) {
  final env = Platform.environment['PRISMARINE_IMPELLERC'];
  if (env != null && File(env).existsSync()) return env;
  File? best;
  for (final root in engineRoots) {
    final out = Directory('$root/out');
    if (!out.existsSync()) continue;
    for (final build in out.listSync().whereType<Directory>()) {
      final f = File('${build.path}/impellerc');
      if (f.existsSync() &&
          (best == null ||
              f.lastModifiedSync().isAfter(best.lastModifiedSync()))) {
        best = f;
      }
    }
  }
  return best?.path;
}

/// The default number of entries in a shard. A reader loads a whole shard for
/// any one of its shaders. A small shard keeps the bytes that one scene reads
/// low.
const shardEntries = 25;

/// The result of [buildShaderBundles].
class ShaderBundleReport {
  ShaderBundleReport(this.bundled, this.failed, this.bytes, {this.cached = 0});
  final int bundled;

  /// The entries of [bundled] whose shard came from the cache.
  final int cached;

  /// The message of impellerc for each failed entry id.
  final Map<String, String> failed;

  /// The bytes on disk for each backend directory.
  final Map<String, int> bytes;
}

/// Builds the bundles of the program tree in [root] with [impellerc] and
/// [settings]. Each `<root>/programs/<effect>/<file>` outside a `bodies`
/// folder is one entry. Each effect is built in shards of [shard] entries
/// with [jobs] impellerc runs at a time. A shard gives one gzip-compressed
/// bundle per backend at
/// `<root>/bundle/<directory>/<effect>.<k>.shaderbundle.gz` and its sources
/// move to `<root>/programs/<effect>/<k>/`. The failures go
/// to `<root>/build.log`. With [effects], only the shards of these effects
/// are built again. With [cacheDir], a shard whose sources and tools have
/// not changed comes from the [ShaderShardCache] in that directory.
Future<ShaderBundleReport> buildShaderBundles(
  String root,
  ShaderBundleSettings settings, {
  required String impellerc,
  int jobs = 4,
  int shard = shardEntries,
  Set<String>? effects,
  String? cacheDir,
}) async {
  final tree = Directory('$root/programs');
  final entries =
      <String, (String, String)>{}; // entry id to its file and stage
  for (final f in tree.listSync(recursive: true).whereType<File>()) {
    // Windows lists with backslashes. Entry ids and effects use slashes.
    final rel = f.path.substring(tree.path.length + 1).replaceAll(r'\', '/');
    // Programs include the files of a bodies folder. They are not entries.
    if (rel.split('/').contains('bodies')) continue;
    if (effects != null && !effects.contains(rel.split('/').first)) continue;
    entries[rel] = (f.path, rel.split('.').last);
  }
  final out = Directory('$root/bundle');
  if (effects == null) {
    if (out.existsSync()) out.deleteSync(recursive: true);
  } else {
    // Deletes the bundles of these effects and keeps the rest.
    for (final f in out.listSync(recursive: true).whereType<File>()) {
      // A file has the form `<effect>.<k>.shaderbundle.gz` and the name of
      // an effect can contain a dot.
      final name = f.path.substring(f.parent.path.length + 1);
      final shardDot = name.lastIndexOf('.', name.indexOf('.shaderbundle') - 1);
      if (effects.contains(name.substring(0, shardDot))) f.deleteSync();
    }
  }
  for (final d in settings.backends.values) {
    Directory('${out.path}/$d').createSync(recursive: true);
  }
  final failed = <String, String>{};
  final byEffect = <String, List<String>>{};
  for (final e in entries.keys.toList()..sort()) {
    (byEffect[e.split('/').first] ??= []).add(e);
  }
  final groups = <(String, List<String>)>[
    for (final MapEntry(key: effect, value: all) in byEffect.entries)
      for (var i = 0; i < all.length; i += shard)
        (
          '$effect.${i ~/ shard}',
          all.sublist(i, (i + shard).clamp(0, all.length)),
        ),
  ];
  var next = 0;

  Future<String?> build(List<String> ids, String file) async {
    final spec = {
      for (final e in ids) e: settings.entry(entries[e]!.$1, entries[e]!.$2),
    };
    final r = await Process.run(impellerc, [
      '--sl=$file',
      '--shader-bundle=${jsonEncode(spec)}',
      '--include=${tree.path}',
      ...settings.impellercArgs,
    ]);
    if (r.exitCode == 0) return null;
    final msg = '${r.stdout}\n${r.stderr}'
        .split('\n')
        .where(
          (l) =>
              l.trim().isNotEmpty &&
              !l.startsWith('Frame ') &&
              !l.contains('backtrace'),
        )
        .take(3)
        .join(' | ');
    return msg.isEmpty ? 'impellerc exit ${r.exitCode}' : msg;
  }

  final metal = MetalCompiler.find();
  final metalErrors = <String, String>{};
  var bundled = 0, cached = 0;
  final cache = ShaderShardCache.open(cacheDir, impellerc, metal?.metal, {
    'args': settings.impellercArgs,
    'options': '${settings.entryOptions}',
    'metalFlags': metalCompileFlags(settings.entryOptions),
    'sdk': metal?.sdk,
  });

  // Moves the sources into the folder of their shard.
  void move(String k, List<String> ids) {
    final shardDir = k.substring(k.lastIndexOf('.') + 1);
    for (final e in ids) {
      final (file, _) = entries[e]!;
      final effect = e.substring(0, e.indexOf('/'));
      final name = e.substring(e.indexOf('/') + 1);
      final to = File('${tree.path}/$effect/$shardDir/$name')
        ..parent.createSync(recursive: true);
      File(file).renameSync(to.path);
    }
    bundled += ids.length;
  }

  Future<void> split(
    String full,
    String k,
    List<String> ids, {
    String? key,
  }) async {
    var bytes = File(full).readAsBytesSync();
    // The sources lose the blocks that the compiler dropped and the shard
    // is built again from them. The sources and the bundle then agree.
    var rewrote = false;
    for (final MapEntry(key: e, value: msl) in metalSources(bytes).entries) {
      final bound = metalBoundBlocks(msl).toSet();
      final f = File(entries[e]!.$1);
      final text = f.readAsStringSync();
      final kept = unboundBlocksAsStructs(text, bound);
      if (kept != text) {
        f.writeAsStringSync(kept);
        rewrote = true;
      }
    }
    if (rewrote && await build(ids, full) == null) {
      bytes = File(full).readAsBytesSync();
    }
    // Compiles the MSL of each entry ahead of time. The engine then loads a
    // library and compiles no source at run time. An entry that the Metal
    // compiler refuses keeps only its source and the compile of the engine
    // at run time reports the error.
    final libs = <String, Uint8List>{};
    if (metal != null) {
      final flags = metalCompileFlags(settings.entryOptions);
      for (final MapEntry(key: e, value: msl) in metalSources(bytes).entries) {
        final (lib, err) = await metal.compile(
          msl,
          '${out.path}/$k.metal',
          flags,
        );
        if (lib != null) libs[e] = lib;
        if (err != null) metalErrors[e] = err;
      }
      final m = Directory('${out.path}/$k.metal');
      if (m.existsSync()) m.deleteSync(recursive: true);
    }
    final gz = <String, Uint8List>{};
    for (final MapEntry(key: backend, value: d) in settings.backends.entries) {
      final one = keepShaderBundleBackends(bytes, {
        backend,
      }, metalCompiled: backend == 'metal_desktop' ? libs : const {});
      final z = gz[d] = Uint8List.fromList(gzip.encode(one));
      File('${out.path}/$d/$k.shaderbundle.gz').writeAsBytesSync(z);
    }
    File(full).deleteSync();
    if (key != null) {
      cache!.store(
        key,
        gz,
        {for (final e in ids) e: File(entries[e]!.$1).readAsStringSync()},
        {
          for (final e in ids)
            if (metalErrors.containsKey(e)) e: metalErrors[e]!,
        },
      );
    }
    move(k, ids);
  }

  Future<void> worker() async {
    while (next < groups.length) {
      final (k, ids) = groups[next++];
      final full = '${out.path}/$k.shaderbundle';
      final key = cache?.key(
        ids,
        {
          for (final e in ids)
            e: {...settings.entry(entries[e]!.$1, entries[e]!.$2)}
              ..remove('file'),
        },
        {for (final e in ids) e: entries[e]!.$1},
        tree.path,
      );
      if (key != null) {
        if (cache!.lookup(key) case final hit?) {
          for (final MapEntry(key: d, value: z) in hit.bundles.entries) {
            File('${out.path}/$d/$k.shaderbundle.gz').writeAsBytesSync(z);
          }
          for (final e in ids) {
            File(entries[e]!.$1).writeAsStringSync(hit.sources[e]!);
          }
          metalErrors.addAll(hit.metalErrors);
          move(k, ids);
          cached += ids.length;
          continue;
        }
      }
      if (await build(ids, full) == null) {
        await split(full, k, ids, key: key);
        continue;
      }
      // Find the entries that fail, then bundle the rest of the shard.
      final good = <String>[];
      for (final e in ids) {
        final one = await build([e], '${out.path}/$k.probe.shaderbundle');
        if (one == null) {
          good.add(e);
        } else {
          failed[e] = one;
        }
      }
      final probe = File('${out.path}/$k.probe.shaderbundle');
      if (probe.existsSync()) probe.deleteSync();
      if (good.isNotEmpty && await build(good, full) == null) {
        await split(full, k, good);
      }
      // Deletes the sources that did not bundle. The tree then holds no
      // source without a bundle.
      for (final e in failed.keys) {
        final f = File(entries[e]!.$1);
        if (f.existsSync()) f.deleteSync();
      }
    }
  }

  await Future.wait([for (var j = 0; j < jobs; j++) worker()]);
  final bytes = {
    for (final d in settings.backends.values)
      d: Directory(
        '${out.path}/$d',
      ).listSync().whereType<File>().fold(0, (s, f) => s + f.lengthSync()),
  };
  File('$root/build.log').writeAsStringSync(
    [
      'impellerc $impellerc; ${entries.length} entries, $bundled bundled, '
          '${failed.length} failed, Metal compiled: ${metal != null}',
      for (final MapEntry(:key, :value) in failed.entries)
        'failed $key: $value',
      for (final MapEntry(:key, :value) in metalErrors.entries)
        'metal $key: $value',
    ].join('\n'),
  );
  return ShaderBundleReport(bundled, failed, bytes, cached: cached);
}
