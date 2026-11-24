import 'dart:io';
import 'dart:isolate';

import 'package:prismarine_cook/prismarine_cook.dart';

import 'doctor.dart';
import 'engine_fetch.dart';
import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';

/// The steps that a command runs on one app. They check the toolchain, fetch
/// the engine, resolve the packages, cook the app and build it.
class AppSteps {
  AppSteps(this.ui, this.toolchain, this.tools, {this.project});

  final Ui ui;
  final Toolchain toolchain;
  final Tools tools;

  /// The app, or null when the command runs outside an app.
  final Project? project;

  Map<String, String> get env => toolchain.environment;

  /// Checks the toolchain for [release]. Throws a [Failure] that lists every
  /// problem.
  Future<String> checkToolchain(EngineRelease? release) =>
      ui.step<String>('toolchain', () async {
        final checks = ToolchainChecks(
          toolchain,
          (c) => tools.read(c),
          os: hostPlatform(),
          env: env,
          flutterWant: project?.flutter,
        );
        final problems = [
          for (final f in checks.all(release))
            if (f.problem) f,
        ];
        if (problems.isEmpty) return 'Flutter ${toolchain.version}';
        throw Failure(
          [for (final p in problems) '${p.what}: ${p.detail}.'].join('\n  '),
          fix: problems.map((p) => p.fix).whereType<String>().join('\n       '),
        );
      }, done: (s) => s);

  /// Reads the engine release of the app, the `engine` of its
  /// `prismarine.yaml`. Throws a [Failure] when the file sets none or when the
  /// prismarine that the app resolves has another release. Outside an app it
  /// reads the release of the prismarine checkout of this command.
  EngineRelease release() {
    final p = project;
    if (p == null) {
      return EngineRelease.read(
        '${checkoutOfCommand()}/third_party/flutter_engine/RELEASE',
      );
    }
    final file = releaseFileOfApp(p.dir);
    if (file == null && p.needsPubGet) {
      throw Failure(
        'The packages of the app ${p.name} are not resolved.',
        fix: 'prismarine flutter pub get, in ${p.dir}',
      );
    }
    if (file == null) {
      throw Failure(
        'The app ${p.name} does not use the flutter_gpu of prismarine.',
        fix:
            'add flutter_gpu with the path <prismarine>/third_party/flutter_gpu under dependency_overrides in pubspec.yaml',
      );
    }
    final have = EngineRelease.read(file);
    final want = p.engine;
    if (want == null) {
      throw Failure(
        '${p.dir}/prismarine.yaml sets no engine.',
        fix: 'add the line engine: ${have.tag} to ${p.dir}/prismarine.yaml',
      );
    }
    if (want != have.tag) {
      throw Failure(
        'prismarine.yaml asks for the engine $want, but the prismarine that '
        'the app resolves is for ${have.tag}.',
        fix:
            'set engine: ${have.tag} in ${p.dir}/prismarine.yaml, or move the app to the prismarine of $want',
      );
    }
    return have;
  }

  /// Finds the engine of [release] for [target], the target of this computer
  /// by default, and fetches it when it is missing or [force] is set. For this
  /// computer it records the impellerc of the engine in the app, where the
  /// build hook reads it.
  Future<Engine> engine(
    EngineRelease release, {
    bool force = false,
    String? target,
  }) {
    var fetched = false;
    final host = hostTarget();
    return ui.step(
      target == null ? 'engine' : 'engine $target',
      () async {
        final target_ = target ?? host;
        if (target_ == null) {
          throw Failure('prismarine has no engine for this OS and CPU.');
        }
        final dir = engineDir(env);
        var e = force ? null : findEngine(dir, target_, release).engine;
        if (e != null && e.missingParts.isNotEmpty && e.fetched) e = null;
        if (e == null) {
          e = await fetchEngine(release, dir, target_, toolchain, tools, ui);
          fetched = true;
        } else {
          linkDartSdk(e, toolchain);
        }
        final missing = e.missingParts;
        if (missing.isNotEmpty) {
          throw Failure(
            'The engine in ${e.outPath} lacks ${missing.join(', ')}.',
            fix: 'prismarine engine build',
          );
        }
        final p = project;
        if (p != null && target_ == host) {
          EngineChoice(e.impellerc, release.tag).writeIn(p.dir);
        }
        return e;
      },
      done: (e) => !e.fetched
          ? 'built from the patches in ${e.src}'
          : fetched
          ? '${release.name} fetched into ${e.src.substring(0, e.src.length - 4)}'
          : '${release.name} ok',
    );
  }

  /// Runs `flutter pub get` in the app when its package config is older
  /// than its pubspec.
  Future<void> packages() async {
    final p = project!;
    if (!p.needsPubGet) return;
    await ui.step('packages', () async {
      await tools.must(
        [toolchain.flutter, 'pub', 'get'],
        dir: p.dir,
        log: 'pub-get',
        cause: '`flutter pub get` failed in ${p.dir}.',
        fix: 'prismarine flutter pub get --verbose',
      );
    }, done: (_) => 'resolved');
  }

  /// Cooks the shaders of the app with the impellerc of [engine]. [force]
  /// cooks every shader again.
  Future<void> shaders(Engine engine, {bool force = false}) async {
    final p = project!;
    for (final entry in p.shaders) {
      await ui.step(
        'shaders ${entry.id}',
        () async {
          try {
            return await cookShaders(
              p,
              entry,
              impellerc: engine.impellerc,
              cacheDir: shaderCacheDir(env),
              force: force,
            );
          } on ShaderCookError catch (e) {
            throw Failure('$e', fix: 'fix the shader, then prismarine cook');
          } on ProjectError catch (e) {
            throw Failure('$e', fix: 'edit ${p.dir}/prismarine.yaml');
          }
        },
        done: (c) => c.current
            ? '${c.shaders} current'
            : '${c.shaders - c.cached} rebuilt, ${c.cached} from the cache',
      );
    }
  }

  /// Runs the asset steps of the app whose inputs changed. [force] runs every
  /// step.
  Future<void> assets({bool force = false}) async {
    final p = project!;
    for (final step in p.assets) {
      await ui.step(
        'assets ${step.id}',
        () async {
          try {
            return await cookAsset(
              p,
              step,
              environment: env,
              force: force,
              run: (command, dir) async {
                final c = [
                  command.first == 'dart' ? toolchain.dart : command.first,
                  ...command.skip(1),
                ];
                final r = await tools.run(
                  c,
                  dir: dir,
                  log: 'assets-${step.id}',
                );
                if (!r.ok) {
                  throw Failure(
                    '`${command.join(' ')}` exited with ${r.exitCode}.\n'
                    '${_tail(r.output)}',
                    fix: 'prismarine cook --verbose',
                    log: '${tools.logDir}/assets-${step.id}.log',
                  );
                }
                return 0;
              },
            );
          } on ProjectError catch (e) {
            throw Failure('$e', fix: 'edit ${p.dir}/prismarine.yaml');
          }
        },
        done: (c) => c.adopted
            ? 'output found in ${c.out}, not run again'
            : c.current
            ? 'current in ${c.out}'
            : 'done in ${c.out}',
      );
    }
  }

  /// Builds the app for [platform] in [mode], `release`, `profile` or `debug`,
  /// on [engine], or on the engine of Flutter when [engine] is null. A debug
  /// build runs on the engine of Flutter. [extra] goes to `flutter build`.
  /// Returns the path of the built app.
  Future<String> build(
    String platform,
    Engine? engine,
    List<String> extra, {
    String mode = 'release',
  }) {
    final p = project!;
    return ui.step('build $platform', () async {
      await tools.must(
        [
          toolchain.flutter,
          'build',
          platform,
          '--$mode',
          if (mode != 'debug' && engine != null) ...engine.flutterArgs,
          ...extra,
        ],
        dir: p.dir,
        log: 'build-$platform',
        cause: '`flutter build $platform` failed.',
        fix: 'prismarine build $platform --verbose',
      );
      final app = builtApp(p.dir, platform, mode: mode);
      if (!File(app).existsSync()) {
        throw Failure('flutter build made no app at $app.');
      }
      return app;
    }, done: (a) => 'ok, ${_relative(a, p.dir)}');
  }

  String _relative(String path, String dir) =>
      path.startsWith('$dir/') ? path.substring(dir.length + 1) : path;
}

String _tail(String output) {
  final lines = output
      .trimRight()
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();
  return lines
      .skip(lines.length > 10 ? lines.length - 10 : 0)
      .map((l) => '    $l')
      .join('\n');
}

/// Finds the prismarine checkout of this command. It searches upward from the
/// package of the command and from its kernel file.
String checkoutOfCommand() {
  final starts = <String>[];
  try {
    final lib = Isolate.resolvePackageUriSync(
      Uri.parse('package:prismarine_cli/prismarine_cli.dart'),
    );
    if (lib != null) starts.add(File.fromUri(lib).parent.path);
  } on Object {
    // A kernel file without a package config resolves no package.
  }
  starts.add(File(Platform.script.toFilePath()).parent.path);
  for (final start in starts) {
    var d = Directory(start);
    while (true) {
      if (File('${d.path}/third_party/flutter_engine/RELEASE').existsSync()) {
        return d.path;
      }
      if (d.parent.path == d.path) break;
      d = d.parent;
    }
  }
  throw Failure(
    'The command is not in a checkout of prismarine: ${Platform.script}.',
  );
}

/// The path of the executable that `flutter build` makes for the app in [dir]
/// on [platform] in [mode], `release`, `profile` or `debug`.
String builtApp(String dir, String platform, {String mode = 'release'}) {
  mode = '${mode[0].toUpperCase()}${mode.substring(1)}';
  switch (platform) {
    case 'macos':
      final name =
          _setting(
            '$dir/macos/Runner/Configs/AppInfo.xcconfig',
            RegExp(r'^PRODUCT_NAME\s*=\s*(.+)$'),
          ) ??
          'Runner';
      return '$dir/build/macos/Build/Products/$mode/$name.app/Contents/MacOS/$name';
    case 'linux':
      final name =
          _setting(
            '$dir/linux/CMakeLists.txt',
            RegExp(r'^set\(BINARY_NAME\s+"([^"]+)"\)'),
          ) ??
          'runner';
      final arch = hostTarget() == 'linux-arm64' ? 'arm64' : 'x64';
      return '$dir/build/linux/$arch/${mode.toLowerCase()}/bundle/$name';
    default:
      final name =
          _setting(
            '$dir/windows/CMakeLists.txt',
            RegExp(r'^set\(BINARY_NAME\s+"([^"]+)"\)'),
          ) ??
          'runner';
      final arch = hostTarget() == 'windows-arm64' ? 'arm64' : 'x64';
      return '$dir\\build\\windows\\$arch\\runner\\$mode\\$name.exe';
  }
}

String? _setting(String file, RegExp pattern) {
  final f = File(file);
  if (!f.existsSync()) return null;
  for (final l in f.readAsLinesSync()) {
    final m = pattern.firstMatch(l.trim());
    if (m != null) return m[1]!.trim();
  }
  return null;
}
