import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'host.dart';

/// A prismarine app with its `prismarine.yaml`.
class Project {
  Project._(this.dir, this.name, this.shaders, this.assets);

  /// The folder of the app, which holds `pubspec.yaml` and `prismarine.yaml`.
  final String dir;

  /// The name of the package of the app.
  final String name;
  final List<ShaderEntry> shaders;
  final List<AssetStep> assets;

  /// Reads the app in [dir]. Returns null when [dir] has no
  /// `prismarine.yaml`. Throws a [ProjectError] for a file that does not
  /// follow the form.
  static Project? load(String dir) {
    final file = File('$dir/prismarine.yaml');
    if (!file.existsSync()) return null;
    final pubspec = File('$dir/pubspec.yaml');
    final name = pubspec.existsSync()
        ? (loadYaml(pubspec.readAsStringSync()) as Map)['name'] as String? ?? ''
        : '';
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw ProjectError('${file.path}: ${e.message}');
    }
    if (doc != null && doc is! Map) {
      throw ProjectError('${file.path}: the file is not a map.');
    }
    final map = (doc as Map?) ?? const {};
    for (final k in map.keys) {
      if (k != 'shaders' && k != 'assets') {
        throw ProjectError(
          '${file.path}: unknown key "$k". The keys are shaders and assets.',
        );
      }
    }
    Map<String, Map> section(String key) {
      final s = map[key];
      if (s == null) return const {};
      if (s is! Map) throw ProjectError('${file.path}: $key is not a map.');
      return {
        for (final MapEntry(:key, :value) in s.entries)
          if (value is Map)
            '$key': value
          else
            '$key': throw ProjectError('${file.path}: ${'$key'} is not a map.'),
      };
    }

    return Project._(
      dir,
      name,
      [
        for (final MapEntry(:key, :value) in section('shaders').entries)
          ShaderEntry._parse(key, value, file.path),
      ],
      [
        for (final MapEntry(:key, :value) in section('assets').entries)
          AssetStep._parse(key, value, file.path),
      ],
    );
  }

  /// Finds the app of [start], the nearest folder at or above it with a
  /// `prismarine.yaml`. Returns null when none has one.
  static String? find(String start) {
    var d = Directory(start).absolute;
    while (true) {
      if (File('${d.path}/prismarine.yaml').existsSync()) return d.path;
      final up = d.parent;
      if (up.path == d.path) return null;
      d = up;
    }
  }

  /// The root folder of package [package] from the package config of the
  /// app. Returns null when the config is missing or lacks the package.
  String? packageRoot(String package) => packageRootIn(dir, package);

  /// The package config of the app.
  File get packageConfig => File('$dir/.dart_tool/package_config.json');

  /// True when the package config is missing or older than `pubspec.yaml`
  /// or `pubspec.lock`.
  bool get needsPubGet {
    final config = packageConfig;
    if (!config.existsSync()) return true;
    final t = config.lastModifiedSync();
    for (final f in ['pubspec.yaml', 'pubspec.lock']) {
      final p = File('$dir/$f');
      if (p.existsSync() && p.lastModifiedSync().isAfter(t)) return true;
    }
    return false;
  }
}

/// The root folder of [package] in the package config of the package in
/// [dir]. Returns null when the config is missing or lacks the package.
String? packageRootIn(String dir, String package) {
  final config = File('$dir/.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final j = jsonDecode(config.readAsStringSync()) as Map;
  for (final p in (j['packages'] as List).cast<Map>()) {
    if (p['name'] != package) continue;
    final root = config.uri.resolve(p['rootUri'] as String);
    var path = root.toFilePath();
    if (path.length > 1 && (path.endsWith('/') || path.endsWith(r'\'))) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }
  return null;
}

/// A file `prismarine.yaml` that does not follow its form.
class ProjectError implements Exception {
  ProjectError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _string(Map m, String key, String where, {String? or}) {
  final v = m[key];
  if (v == null && or != null) return or;
  if (v is! String || v.isEmpty) {
    throw ProjectError('$where: $key must be a string.');
  }
  return v;
}

List<String> _strings(Map m, String key, String where) {
  final v = m[key];
  if (v == null) return const [];
  if (v is String) return [v];
  if (v is! List) throw ProjectError('$where: $key must be a list.');
  return [for (final e in v) '$e'];
}

void _onlyKeys(Map m, Set<String> keys, String where) {
  for (final k in m.keys) {
    if (!keys.contains(k)) {
      throw ProjectError(
        '$where: unknown key "$k". The keys are ${keys.join(', ')}.',
      );
    }
  }
}

/// A program tree that cooks into shader bundles and their records.
class ShaderEntry {
  ShaderEntry._(
    this.id,
    this.package,
    this.programs,
    this.manifest,
    this.out,
    this.backends,
    this.shard,
    this.impellercArgs,
  );

  factory ShaderEntry._parse(String id, Map m, String file) {
    final where = '$file: shaders.$id';
    _onlyKeys(m, const {
      'package',
      'programs',
      'manifest',
      'out',
      'backends',
      'shard',
      'impellerc-args',
    }, where);
    final backends = m.containsKey('backends')
        ? _strings(m, 'backends', where)
        : const ['metal', 'vulkan'];
    for (final b in backends) {
      if (b != 'metal' && b != 'vulkan') {
        throw ProjectError('$where: backend "$b" is not metal or vulkan.');
      }
    }
    final shard = m['shard'] ?? 25;
    if (shard is! int || shard < 1) {
      throw ProjectError('$where: shard must be a positive number.');
    }
    if ((m['programs'] == null) == (m['manifest'] == null)) {
      throw ProjectError('$where: give either programs or manifest.');
    }
    return ShaderEntry._(
      id,
      m['package'] == null ? null : _string(m, 'package', where),
      m['programs'] == null ? null : _string(m, 'programs', where),
      m['manifest'] == null ? null : _string(m, 'manifest', where),
      _string(m, 'out', where),
      backends,
      shard,
      _strings(m, 'impellerc-args', where),
    );
  }

  final String id;

  /// The package whose folder holds [programs] or [manifest], or null for
  /// the app.
  final String? package;

  /// A program tree of prismarine_shaders, or null for a [manifest].
  final String? programs;

  /// A shader bundle manifest of impellerc, or null for [programs]. Its
  /// files are relative to the folder of the package.
  final String? manifest;

  /// The output folder of a program tree, or the bundle file of a manifest,
  /// relative to the app.
  final String out;

  /// `metal` and `vulkan`, the backends of the bundles.
  final List<String> backends;
  final int shard;
  final List<String> impellercArgs;

  /// The folder of the program tree. Throws a [ProjectError] when the
  /// package is not in the package config of [project].
  String programsDir(Project project) => '${baseDir(project)}/$programs';

  /// The folder of [package], or of the app without one. Throws a
  /// [ProjectError] when the package is not in the package config.
  String baseDir(Project project) {
    final base = package == null ? project.dir : project.packageRoot(package!);
    if (base == null) {
      throw ProjectError(
        'shaders.$id: the app does not depend on $package. Add it to '
        'pubspec.yaml.',
      );
    }
    return base;
  }

  /// The source files and folders of the entry, the inputs of its key.
  List<String> sources(Project project) {
    if (programs != null) return [programsDir(project)];
    final base = baseDir(project);
    final m = File('$base/$manifest');
    if (!m.existsSync()) {
      throw ProjectError('shaders.$id: no manifest ${m.path}.');
    }
    final dirs = <String>{};
    final j = jsonDecode(m.readAsStringSync());
    if (j is Map) {
      for (final e in j.values) {
        if (e is Map && e['file'] is String) {
          dirs.add(File('$base/${e['file']}').parent.path);
        }
      }
    }
    return [m.path, ...(dirs.toList()..sort())];
  }

  String outDir(Project project) => '${project.dir}/$out';

  /// The settings of the entry as JSON, for the key of its stamp.
  String get settings => jsonEncode({
    'manifest': ?manifest,
    'backends': backends,
    'shard': shard,
    'impellerc-args': impellercArgs,
  });
}

/// A command that prepares assets of the app outside its bundle, such as a
/// download and conversion of a scene.
class AssetStep {
  AssetStep._(
    this.id,
    this.run,
    this.out,
    this.outEnv,
    this.inputs,
    this.exists,
  );

  factory AssetStep._parse(String id, Map m, String file) {
    final where = '$file: assets.$id';
    _onlyKeys(m, const {'run', 'out', 'out-env', 'inputs', 'exists'}, where);
    final run = _strings(m, 'run', where);
    if (run.isEmpty) throw ProjectError('$where: run is empty.');
    return AssetStep._(
      id,
      run,
      _string(m, 'out', where),
      m['out-env'] == null ? null : _string(m, 'out-env', where),
      _strings(m, 'inputs', where),
      _strings(m, 'exists', where),
    );
  }

  final String id;

  /// Paths in the output folder that a finished output has. An output with
  /// all of them and without a stamp is taken as current.
  final List<String> exists;

  /// The command and its arguments. `{out}` becomes the output folder.
  final List<String> run;

  /// The output folder. `{data}` becomes [dataHome].
  final String out;

  /// A variable that sets the output folder when it is set.
  final String? outEnv;

  /// Files and folders of the app and `package:<name>` for the `lib` folder
  /// of a package.
  final List<String> inputs;

  /// The output folder for the environment [env].
  String outDir(Map<String, String> env) {
    final set = outEnv == null ? null : env[outEnv];
    if (set != null && set.isNotEmpty) return set;
    return out.replaceAll('{data}', dataHome(env));
  }

  /// The command with `{out}` replaced by [outDir].
  List<String> command(String outDir) => [
    for (final a in run) a.replaceAll('{out}', outDir),
  ];

  /// The paths of [inputs] for [project]. Throws a [ProjectError] for a
  /// package that the app does not depend on.
  List<String> inputPaths(Project project) => [
    for (final i in inputs)
      if (i.startsWith('package:'))
        '${project.packageRoot(i.substring(8)) ?? (throw ProjectError('assets.$id: the app does not depend on ${i.substring(8)}.'))}/lib'
      else
        '${project.dir}/$i',
  ];
}
