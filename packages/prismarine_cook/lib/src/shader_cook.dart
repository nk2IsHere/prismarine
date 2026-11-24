import 'dart:convert';
import 'dart:io';

import 'package:prismarine_shaders/prismarine_shaders.dart';

import 'hashing.dart';
import 'project.dart';
import 'stamp.dart';

/// The version of the cook output. A change to the form of the output
/// raises it.
const _cookVersion = 'shaders 1';

/// The result of [cookShaders].
class ShaderCook {
  ShaderCook(
    this.entry, {
    required this.current,
    this.shaders = 0,
    this.cached = 0,
  });

  final ShaderEntry entry;

  /// True when the output was current and nothing was compiled.
  final bool current;

  /// The shaders in the bundles.
  final int shaders;

  /// The shaders whose shard came from the cache.
  final int cached;
}

/// A cook of shaders that failed, with the message of each failed shader.
class ShaderCookError implements Exception {
  ShaderCookError(this.entry, this.failed);
  final String entry;
  final Map<String, String> failed;

  @override
  String toString() {
    final first = failed.entries.first;
    final more = failed.length > 1 ? ' and ${failed.length - 1} more' : '';
    return '${first.key} does not compile$more. '
        '${first.value.trim().split('\n').take(6).join('\n')}';
  }
}

/// The key of the inputs of [entry] in [project] with [impellerc]. Equal
/// keys give equal outputs.
String shaderKey(Project project, ShaderEntry entry, String impellerc) {
  final metal = MetalCompiler.find();
  String identity(String? path) {
    if (path == null) return '-';
    final s = File(path).statSync();
    return '$path ${s.size} ${s.modified.microsecondsSinceEpoch}';
  }

  return hashInputs([
    _cookVersion,
    entry.settings,
    'impellerc ${hashFile(impellerc)}',
    'metal ${identity(metal?.metal)}',
  ], trees: entry.sources(project));
}

/// The stamp of [entry] in [project], in its output folder or beside its
/// bundle file.
Stamp shaderStamp(Project project, ShaderEntry entry) => Stamp(
  entry.manifest == null
      ? '${entry.outDir(project)}/cook.json'
      : '${entry.outDir(project)}.cook.json',
);

bool _outputExists(Project project, ShaderEntry entry) => entry.manifest == null
    ? Directory('${entry.outDir(project)}/bundle').existsSync()
    : File(entry.outDir(project)).existsSync();

/// True when the output of [entry] is current for [impellerc].
bool shadersCurrent(Project project, ShaderEntry entry, String impellerc) =>
    shaderStamp(project, entry).key == shaderKey(project, entry, impellerc) &&
    _outputExists(project, entry);

/// Cooks the program tree of [entry] into its output folder when its stamp
/// is stale or [force] is set. The bundles go to
/// `<out>/bundle/<backend>/<effect>.<n>.shaderbundle.gz` and the interfaces
/// to `<out>/records.json`. Shards come from the cache in [cacheDir]. Throws
/// a [ShaderCookError] when a shader does not compile.
Future<ShaderCook> cookShaders(
  Project project,
  ShaderEntry entry, {
  required String impellerc,
  String? cacheDir,
  bool force = false,
}) async {
  final stamp = shaderStamp(project, entry);
  final key = shaderKey(project, entry, impellerc);
  final out = entry.outDir(project);
  if (!force && stamp.key == key && _outputExists(project, entry)) {
    final f = stamp.fields;
    return ShaderCook(
      entry,
      current: true,
      shaders: (f['shaders'] as int?) ?? 0,
    );
  }
  stamp.delete();
  if (entry.manifest != null) {
    return _cookManifest(project, entry, impellerc, stamp, key);
  }
  final programs = entry.programsDir(project);
  if (!Directory(programs).existsSync()) {
    throw ProjectError('shaders.${entry.id}: no folder $programs.');
  }
  final work = Directory('$out/.work');
  if (work.existsSync()) work.deleteSync(recursive: true);
  for (final f in Directory(
    programs,
  ).listSync(recursive: true).whereType<File>()) {
    File('${work.path}/programs/${f.path.substring(programs.length + 1)}')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(f.readAsBytesSync());
  }
  final report = await buildShaderBundles(
    work.path,
    ShaderBundleSettings(
      backends: {
        for (final b in entry.backends) b == 'metal' ? 'metal_desktop' : b: b,
      },
      impellercArgs: entry.impellercArgs,
    ),
    shard: entry.shard,
    impellerc: impellerc,
    cacheDir: cacheDir,
  );
  if (report.failed.isNotEmpty) {
    work.deleteSync(recursive: true);
    throw ShaderCookError(entry.id, report.failed);
  }
  final bundle = Directory('$out/bundle');
  if (bundle.existsSync()) bundle.deleteSync(recursive: true);
  Directory('${work.path}/bundle').renameSync(bundle.path);
  work.deleteSync(recursive: true);
  File('$out/records.json').writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(programRecords(programs)),
  );
  stamp.write(key, {'shaders': report.bundled});
  return ShaderCook(
    entry,
    current: false,
    shaders: report.bundled,
    cached: report.cached,
  );
}

Future<ShaderCook> _cookManifest(
  Project project,
  ShaderEntry entry,
  String impellerc,
  Stamp stamp,
  String key,
) async {
  final base = entry.baseDir(project);
  final manifest = File('$base/${entry.manifest}').readAsStringSync();
  final out = File(entry.outDir(project))..parent.createSync(recursive: true);
  final r = await Process.run(impellerc, [
    '--sl=${out.path}',
    ...entry.impellercArgs,
    '--shader-bundle=${jsonEncode(jsonDecode(manifest))}',
  ], workingDirectory: base);
  if (r.exitCode != 0) {
    if (out.existsSync()) out.deleteSync();
    throw ShaderCookError(entry.id, {
      entry.manifest!: '${r.stderr}${r.stdout}',
    });
  }
  final count = (jsonDecode(manifest) as Map).length;
  stamp.write(key, {'shaders': count});
  return ShaderCook(entry, current: false, shaders: count);
}
