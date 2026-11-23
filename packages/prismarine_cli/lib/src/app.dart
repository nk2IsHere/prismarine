import 'dart:io';

import 'package:prismarine_cook/prismarine_cook.dart';

import 'doctor.dart';
import 'engine_fetch.dart';
import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';

/// The steps of a command on one app: toolchain, engine, packages, cook,
/// build and run.
class AppSteps {
  AppSteps(this.ui, this.toolchain, this.tools, {this.project});

  final Ui ui;
  final Toolchain toolchain;
  final Tools tools;

  /// The app, or null outside one.
  final Project? project;

  Map<String, String> get env => toolchain.environment;

  /// Checks the toolchain. Throws a [Failure] that lists every problem.
  Future<String> checkToolchain(EngineRelease? release) =>
      ui.step<String>('toolchain', () async {
        final checks = ToolchainChecks(
          toolchain,
          (c) => tools.read(c),
          os: hostPlatform(),
          env: env,
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

  /// The release of the app, or of the checkout of this command outside an
  /// app.
  EngineRelease release() {
    final p = project;
    final file = p == null ? null : releaseFileOfApp(p.dir);
    if (file != null) return EngineRelease.read(file);
    if (p != null && !p.needsPubGet) {
      throw Failure(
        'The app ${p.name} does not use the flutter_gpu of prismarine.',
        fix:
            'add flutter_gpu with a path to third_party/flutter_gpu of prismarine to dependency_overrides of pubspec.yaml',
      );
    }
    return EngineRelease.read(
      '${checkoutOfCommand()}/third_party/flutter_engine/RELEASE',
    );
  }

  /// Finds the engine of [release] and fetches it when it is missing or
  /// [force] is set. Writes the choice for the build hook of the app.
  Future<Engine> engine(EngineRelease release, {bool force = false}) => ui.step(
    'engine',
    () async {
      final target = hostTarget();
      if (target == null) {
        throw Failure('prismarine has no engine for this OS and CPU.');
      }
      final dir = engineDir(env);
      var e = force ? null : findEngine(dir, target, release).engine;
      if (e != null && e.missingParts.isNotEmpty && e.fetched) e = null;
      if (e == null) {
        e = await fetchEngine(release, dir, target, toolchain, tools, ui);
      } else {
        linkDartSdk(e, toolchain);
      }
      final missing = e.missingParts;
      if (missing.isNotEmpty) {
        throw Failure(
          'The engine in ${e.outPath} lacks ${missing.join(', ')}.',
          fix: 'build the engine again',
        );
      }
      final p = project;
      if (p != null) EngineChoice(e.impellerc, release.tag).writeIn(p.dir);
      return e;
    },
    done: (e) =>
        e.fetched ? '${release.name} ok' : 'built from the patches in ${e.src}',
  );

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

  /// Cooks the shaders of the app with [engine].
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

  /// Runs the asset steps of the app that are stale.
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
            ? 'taken as current, the output in ${c.out} has no stamp'
            : c.current
            ? 'current in ${c.out}'
            : 'done in ${c.out}',
      );
    }
  }

  /// Builds the app for [platform] on [engine], or on the engine of Flutter
  /// without one. Returns the path of the built app.
  Future<String> build(String platform, Engine? engine, List<String> extra) {
    final p = project!;
    return ui.step('build $platform', () async {
      await tools.must(
        [
          toolchain.flutter,
          'build',
          platform,
          if (engine == null)
            '--debug'
          else ...[
            '--release',
            ...engine.flutterArgs,
          ],
          ...extra,
        ],
        dir: p.dir,
        log: 'build-$platform',
        cause: '`flutter build $platform` failed.',
        fix: 'prismarine build $platform --verbose',
      );
      final app = builtApp(p.dir, platform, release: engine != null);
      if (!File(app).existsSync()) {
        throw Failure('The build left no app at $app.');
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

/// The prismarine checkout of this command.
String checkoutOfCommand() {
  final script = Platform.script.toFilePath();
  var d = File(script).parent;
  while (true) {
    if (File('${d.path}/third_party/flutter_engine/RELEASE').existsSync()) {
      return d.path;
    }
    if (d.parent.path == d.path) {
      throw Failure('The command is not in a checkout of prismarine: $script.');
    }
    d = d.parent;
  }
}

/// The path of the app of the Flutter app in [dir] built for [platform].
String builtApp(String dir, String platform, {bool release = true}) {
  final mode = release ? 'Release' : 'Debug';
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
