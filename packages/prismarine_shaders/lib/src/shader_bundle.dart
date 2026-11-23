import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'metal_compile.dart';
import 'shader_bundle_cache.dart';
import 'shader_bundle_split.dart';

/// The backends a slice carries, and the directory each goes to: S2 needs
/// Metal or Vulkan.
const bundleBackends = {'metal_desktop': 'metal', 'vulkan': 'vulkan'};

/// impellerc's arguments for S2: MSL 2.3, for invariant positions and
/// gl_Layer (the patched engine's impellerc).
const impellercArgs = ['--metal-version=2.3'];

/// How impellerc compiles each S2 entry. Metal preserves invariant
/// positions: the exe's main pass tests depth for equality with a depth
/// pass drawn by other vertex shaders. Safe math and Vulkan's float controls
/// stay off and spirv-opt on: on the oracle's frames neither changes a pixel
/// on Vulkan nor costs measurable time on either backend, and fast math
/// moves at most a level on a few pixels (formats/s2/shaders.md "Backend
/// settings"); spirv-opt also shrinks the SPIR-V by about a third.
const bundleEntryOptions = {
  'metal_preserve_invariance': true,
  'metal_safe_math': false,
  'spirv_optimize': true,
};

/// One shader-bundle entry for an S2 translation of [stage] (`vert`,
/// `frag`, `comp`, or `vertex`/`fragment`/`compute`) in [file].
Map<String, Object> bundleEntry(String file, String stage) => {
  'type': switch (stage) {
    'vert' || 'vertex' => 'vertex',
    'comp' || 'compute' => 'compute',
    _ => 'fragment',
  },
  'file': file,
  'targets': bundleBackends.keys.toList(),
  ...bundleEntryOptions,
};

/// [glsl] with each uniform block not in [bound] made a plain struct with a
/// private instance of the same name: code that still names it compiles, and
/// nothing asks for a binding the compiled shader doesn't have.
String unboundBlocksAsStructs(String glsl, Set<String> bound) =>
    glsl.replaceAllMapped(RegExp(r'uniform (\w+) \{([^}]*)\} (\w+);'), (m) {
      if (bound.contains(m[1])) return m[0]!;
      return 'struct ${m[1]}_unbound {${m[2]}};\n${m[1]}_unbound ${m[3]};';
    });

/// Where engine builds live under the data root ([findImpellerc]).
List<String> engineRoots(String data) => [
  '$data/engine/flutter/engine/src',
  for (final t in [
    'macos-arm64',
    'macos-x64',
    'linux-x64',
    'linux-arm64',
    'windows-x64',
    'windows-arm64',
  ])
    '$data/engine/$t/src',
];

/// The patched engine's impellerc, which S2's shaders need (per-block
/// uniform limits, storage resources, per-entry backends; the SDK's refuses
/// them): `$MCSM_IMPELLERC`, else the newest engine build under
/// [engineRoots] (`<root>/out/<build>/impellerc`), as tools/toolchain/env.sh
/// finds it.
String? findImpellerc({List<String> engineRoots = const []}) {
  final env = Platform.environment['MCSM_IMPELLERC'];
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

/// Entries per shard. A player reads a whole shard for any one of its
/// shaders, and a scene draws from a few in each (BeaconTown's frame: 116
/// shaders in 59 shards of 200), so a shard stays small: with their Metal
/// libraries that frame reads 26 MB at 25, 161 MB at 200.
const shardEntries = 25;

/// What [buildEffectShaderBundle] built.
class ShaderBundleReport {
  ShaderBundleReport(this.bundled, this.failed, this.bytes, {this.cached = 0});
  final int bundled;

  /// Of [bundled], the entries whose shard came from the cache (not
  /// compiled again).
  final int cached;

  /// Shader id → impellerc's message.
  final Map<String, String> failed;

  /// Bytes on disk per backend directory.
  final Map<String, int> bytes;
}

/// Builds the slice's shader bundles from its program tree with impellerc:
/// every file under `shaders/programs/<effect>/` is one entry, named
/// `<effect>/<file>`, in shards of [shard] entries per effect ([jobs]
/// impellerc runs at a time). Each shard is split into one gzip-compressed
/// bundle per backend, `bundle/<metal|vulkan>/<effect>.<k>.shaderbundle.gz`,
/// as a player opens only its own, and its sources move to
/// `programs/<effect>/<k>/`, the editable form, where a renderer finds them.
/// A block the compiler drops is made a plain struct there, so the source
/// declares exactly what the shader binds. A failing shard is retried entry
/// by entry; entries name their backends ("targets"), so GL is not compiled.
/// On macOS each Metal entry also carries its source compiled to a library
/// (`compiled`, patch 0004). What failed goes to `shaders/build.log`.
Future<ShaderBundleReport> buildEffectShaderBundle(
  String sliceDir, {
  required String impellerc,
  int jobs = 4,
  int shard = shardEntries,
  // Only these effects' shards built again, the rest kept.
  Set<String>? effects,
  // Compiled shards kept by their sources (ShaderShardCache): a shard whose
  // sources and tools are unchanged is copied, not compiled again.
  String? cacheDir,
}) async {
  final root = '$sliceDir/shaders';
  final tree = Directory('$root/programs');
  final entries = <String, (String, String)>{}; // entry → (file, stage)
  for (final f in tree.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.substring(tree.path.length + 1);
    // Bodies are included by programs, not entries of their own.
    if (rel.split('/').contains('bodies')) continue;
    if (effects != null && !effects.contains(rel.split('/').first)) continue;
    entries[rel] = (f.path, rel.split('.').last);
  }
  final out = Directory('$root/bundle');
  if (effects == null) {
    if (out.existsSync()) out.deleteSync(recursive: true);
  } else {
    // Only these effects' shards are built again: theirs go, the rest stay.
    for (final f in out.listSync(recursive: true).whereType<File>()) {
      // `<effect>.<k>.shaderbundle.gz`, where an effect's name may hold a
      // dot of its own.
      final name = f.path.substring(f.parent.path.length + 1);
      final shardDot = name.lastIndexOf('.', name.indexOf('.shaderbundle') - 1);
      if (effects.contains(name.substring(0, shardDot))) f.deleteSync();
    }
  }
  for (final d in bundleBackends.values) {
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
      for (final e in ids) e: bundleEntry(entries[e]!.$1, entries[e]!.$2),
    };
    final r = await Process.run(impellerc, [
      '--sl=$file',
      '--shader-bundle=${jsonEncode(spec)}',
      '--include=${tree.path}',
      ...impellercArgs,
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
    'args': impellercArgs,
    'options': '$bundleEntryOptions',
    'metalFlags': metalCompileFlags(bundleEntryOptions),
    'sdk': metal?.sdk,
  });

  // The sources move under their shard, where the renderer looks.
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
    // Blocks the compiler dropped leave the kept sources, and the shard is
    // built again from them, so source and bundle agree.
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
    // Each entry's MSL compiled ahead, so the engine loads a library and
    // compiles no source at run time; what Apple's compiler refuses keeps
    // only its source, and the engine's run-time compile reports it.
    final libs = <String, Uint8List>{};
    if (metal != null) {
      final flags = metalCompileFlags(bundleEntryOptions);
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
    for (final MapEntry(key: backend, value: d) in bundleBackends.entries) {
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
            e: {...bundleEntry(entries[e]!.$1, entries[e]!.$2)}..remove('file'),
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
      // A source that didn't bundle goes, so no renderer looks for it.
      for (final e in failed.keys) {
        final f = File(entries[e]!.$1);
        if (f.existsSync()) f.deleteSync();
      }
    }
  }

  await Future.wait([for (var j = 0; j < jobs; j++) worker()]);
  final bytes = {
    for (final d in bundleBackends.values)
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
