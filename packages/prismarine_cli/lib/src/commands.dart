import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'app.dart';
import 'base_command.dart';
import 'doctor.dart';
import 'engine_command.dart';
import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';
import 'universal.dart';

/// Runs the prismarine command with [args] and returns its exit code.
Future<int> runPrismarine(List<String> args) async {
  if (args.isNotEmpty && (args.first == 'flutter' || args.first == 'dart')) {
    return _passThrough(args.first, args.sublist(1));
  }
  final runner = _Runner()
    ..addCommand(_RunCommand())
    ..addCommand(_BuildCommand())
    ..addCommand(_CookCommand())
    ..addCommand(EngineCommand())
    ..addCommand(_DoctorCommand())
    ..addCommand(_EnvCommand())
    ..addCommand(_PassCommand('flutter'))
    ..addCommand(_PassCommand('dart'));
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln('${e.message}\n\n${e.usage}');
    return 64;
  } on Failure {
    return 1;
  }
}

class _Runner extends CommandRunner<int> {
  _Runner()
    : super(
        'prismarine',
        'Builds and runs prismarine apps on macOS, Linux and Windows.',
        usageLineLength: 100,
      );

  @override
  String get usageFooter => examples;
}

/// Runs the steps of [c] up to the build of its app for [platform] and returns
/// the path of the built app. [extra] goes to `flutter build`. [debug] and
/// [stock] build on the engine of Flutter. [profile] builds in profile mode on
/// the profile out folder of the patched engine. [universal] builds one app
/// for both CPUs of a Mac. [assets] also runs the asset steps.
Future<String> _buildApp(
  BaseCommand c,
  String platform,
  List<String> extra, {
  bool debug = false,
  bool profile = false,
  bool stock = false,
  bool universal = false,
  bool assets = false,
}) async {
  c.needFlutter();
  final project = c.findApp(given: c.argResults!.option('app'))!;
  final s = c.steps(project);
  c.ui.line('app ${project.name} in ${project.dir}');
  await s.packages();
  final release = s.release();
  await s.checkToolchain(release);
  final engine = await s.engine(release);
  await s.shaders(engine);
  if (assets) await s.assets();
  if (debug || stock) {
    c.ui.line(
      'This ${debug ? 'debug' : 'release'} build runs on the engine of '
      'Flutter, without the patches.',
    );
  }
  if (profile) {
    final p = findProfileEngine(engine, engineDir(c.toolchain.environment));
    if (p == null) {
      throw Failure(
        'The engine has no profile out folder beside ${engine.outPath}.',
        fix: 'prismarine engine build --mode=profile',
      );
    }
    c.ui.line('This profile build runs on ${p.outPath}.');
    return s.build(platform, p, extra, mode: 'profile');
  }
  if (!universal) {
    return s.build(
      platform,
      debug || stock ? null : engine,
      extra,
      mode: debug ? 'debug' : 'release',
    );
  }
  if (platform != 'macos' || debug || stock) {
    throw UsageException(
      '--universal works only for a release build for macOS on the patched engine.',
      '',
    );
  }
  final x64 = await s.engine(release, target: 'macos-x64');
  final keep = '${project.dir}/build/prismarine/universal';
  Directory(keep).createSync(recursive: true);
  final parts = <String>[];
  for (final (cpu, e) in [('arm64', engine), ('x86_64', x64)]) {
    final exe = await s.build(platform, e, extra);
    final app = exe.substring(0, exe.indexOf('.app/') + 4);
    final aside = '$keep/$cpu.app';
    if (Directory(aside).existsSync()) {
      Directory(aside).deleteSync(recursive: true);
    }
    Directory(app).renameSync(aside);
    parts.add(aside);
  }
  final out = builtApp(project.dir, platform);
  final app = out.substring(0, out.indexOf('.app/') + 4);
  await c.ui.step(
    'universal',
    () => mergeUniversalApp(parts[0], parts[1], app, s.tools),
    done: (n) => '$n Mach-O files merged',
  );
  return out;
}

String _platform(ArgResults r) {
  final p = r.rest.isEmpty || r.rest.first.startsWith('-')
      ? hostPlatform()
      : r.rest.first;
  if (!const ['macos', 'linux', 'windows'].contains(p)) {
    throw UsageException(
      'Unknown platform "$p". The platforms are macos, linux and windows.',
      '',
    );
  }
  return p;
}

List<String> _afterPlatform(ArgResults r) =>
    r.rest.isNotEmpty &&
        const ['macos', 'linux', 'windows'].contains(r.rest.first)
    ? r.rest.sublist(1)
    : r.rest;

void _addStock(ArgParser p) => p
  ..addFlag(
    'stock',
    negatable: false,
    help:
        'Builds in release mode on the engine of Flutter without the patches.',
  )
  ..addFlag(
    'profile',
    negatable: false,
    help:
        'Builds in profile mode on the profile out folder of the patched engine.',
  );

class _RunCommand extends BaseCommand {
  _RunCommand() {
    addApp();
    _addStock(argParser);
    argParser
      ..addFlag(
        'build',
        defaultsTo: true,
        help:
            'Builds the app before it starts. --no-build starts the app as it was last built.',
      )
      ..addOption(
        'timeout',
        help:
            'Stops the app after this many seconds and exits with 124, for unattended runs.',
        valueHelp: 'seconds',
      );
  }

  @override
  String get name => 'run';
  @override
  String get description =>
      'Checks the toolchain, fetches the engine, cooks, builds the app in release mode and starts it.';
  @override
  String get invocation =>
      'prismarine run [<platform>] [--app=<folder>] [-- <app arguments>]';

  @override
  Future<int> run() async {
    final platform = _platform(argResults!);
    if (platform != hostPlatform()) {
      throw UsageException(
        'An app for $platform does not run on ${hostPlatform()}.',
        usage,
      );
    }
    final r = argResults!;
    final timeout = r.option('timeout');
    final seconds = timeout == null ? null : int.tryParse(timeout);
    if (timeout != null && (seconds == null || seconds <= 0)) {
      throw UsageException('--timeout takes whole seconds.', usage);
    }
    final String app;
    if (r.flag('build')) {
      app = await _buildApp(
        this,
        platform,
        const [],
        stock: r.flag('stock'),
        profile: r.flag('profile'),
        assets: true,
      );
    } else {
      final project = findApp(given: r.option('app'))!;
      app = builtApp(
        project.dir,
        platform,
        mode: r.flag('profile') ? 'profile' : 'release',
      );
      if (!File(app).existsSync()) {
        final f = Failure(
          'No built app at $app.',
          fix: 'prismarine build --app=${project.dir}',
        );
        ui.printFailure(f);
        throw f;
      }
    }
    ui.line('run ${app.split(RegExp(r'[/\\]')).last}');
    final p = await Process.start(
      app,
      _afterPlatform(r),
      mode: ProcessStartMode.inheritStdio,
    );
    if (seconds == null) return p.exitCode;
    var timedOut = false;
    final code = await p.exitCode.timeout(
      Duration(seconds: seconds),
      onTimeout: () {
        timedOut = true;
        return 0;
      },
    );
    if (!timedOut) return code;
    ui.line('stopped after $seconds s');
    p.kill();
    await p.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return 137;
      },
    );
    return 124;
  }
}

class _BuildCommand extends BaseCommand {
  _BuildCommand() {
    addApp();
    argParser.addFlag(
      'debug',
      negatable: false,
      help:
          'Builds in debug mode on the engine of Flutter, without the patches.',
    );
    _addStock(argParser);
    argParser.addFlag(
      'universal',
      negatable: false,
      help:
          'macOS: builds the app for arm64 and for x86_64 and merges both into '
          'one app.',
    );
  }

  @override
  String get name => 'build';
  @override
  String get description =>
      'Checks the toolchain, fetches the engine, cooks the shaders and builds the app in release mode on the patched engine.';
  @override
  String get invocation =>
      'prismarine build [<platform>] [--app=<folder>] [-- <flutter build arguments>]';

  @override
  Future<int> run() async {
    final app = await _buildApp(
      this,
      _platform(argResults!),
      _afterPlatform(argResults!),
      debug: argResults!.flag('debug'),
      stock: argResults!.flag('stock'),
      profile: argResults!.flag('profile'),
      universal: argResults!.flag('universal'),
    );
    ui.line(app);
    return 0;
  }
}

class _CookCommand extends BaseCommand {
  _CookCommand() {
    addApp();
    argParser
      ..addFlag('shaders', negatable: false, help: 'Cooks only the shaders.')
      ..addFlag('assets', negatable: false, help: 'Runs only the asset steps.')
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Cooks the shaders and runs the asset steps also when they are current.',
      );
  }

  @override
  String get name => 'cook';
  @override
  String get description =>
      'Cooks the shaders and runs the asset steps of the app that are not current.';
  @override
  String get invocation =>
      'prismarine cook [<app folder>] [--shaders] [--assets] [--force]';

  @override
  Future<int> run() async {
    needFlutter();
    final r = argResults!;
    final project = findApp(given: r.option('app') ?? r.rest.firstOrNull)!;
    final s = steps(project);
    final force = r.flag('force');
    final onlyAssets = r.flag('assets') && !r.flag('shaders');
    final onlyShaders = r.flag('shaders') && !r.flag('assets');
    await s.packages();
    if (!onlyAssets && project.shaders.isNotEmpty) {
      final engine = await s.engine(s.release());
      await s.shaders(engine, force: force);
    }
    if (!onlyShaders) await s.assets(force: force);
    return 0;
  }
}

class _DoctorCommand extends BaseCommand {
  _DoctorCommand() {
    addApp();
  }

  @override
  String get name => 'doctor';
  @override
  String get description =>
      'Lists every problem of the toolchain, the engine and the app with the command that fixes it.';
  @override
  String get invocation => 'prismarine doctor [<app folder>]';

  @override
  Future<int> run() async {
    final r = argResults!;
    final project = findApp(
      required: false,
      given: r.option('app') ?? r.rest.firstOrNull,
    );
    final s = steps(project);
    final env = toolchain.environment;
    final tools = Tools(
      ui,
      environment: env,
      logDir: Directory.systemTemp.path,
    );
    String? read(List<String> c) => tools.read(c);
    EngineRelease? release;
    Finding? releaseProblem;
    try {
      release = s.release();
    } on Failure catch (f) {
      releaseProblem = Finding.problem('Engine release', f.cause, f.fix);
    } on Object {
      release = null;
    }
    final groups = <String, List<Finding>>{
      'toolchain': [
        ...ToolchainChecks(
          toolchain,
          read,
          os: hostPlatform(),
          env: env,
          flutterWant: project?.flutter,
        ).all(release),
        ?releaseProblem,
      ],
    };
    final target = hostTarget();
    if (release != null && target != null) {
      final search = findEngine(engineDir(env), target, release);
      groups['engine ${release.tag}'] = engineChecks(
        release,
        search,
        toolchain,
        read,
        env,
      );
      if (project != null) {
        groups['app ${project.name}'] = appChecks(project, search.engine, env);
      }
    }
    var problems = 0;
    for (final MapEntry(:key, :value) in groups.entries) {
      ui.line(key);
      for (final f in value) {
        ui.line(
          '  ${f.problem ? 'problem' : 'ok     '} ${f.what}: ${f.detail}',
        );
        if (f.problem) {
          problems++;
          if (f.fix != null) ui.line('          fix: ${f.fix}');
        }
      }
    }
    ui.line(
      problems == 0
          ? 'No problems.'
          : '$problems ${problems == 1 ? 'problem' : 'problems'}.',
    );
    return problems == 0 ? 0 : 1;
  }
}

/// Checks that the packages of [project] are resolved, that its shaders are
/// cooked for [engine] and that its assets are prepared in the folders that
/// [env] sets.
List<Finding> appChecks(
  Project project,
  Engine? engine,
  Map<String, String> env,
) {
  if (project.needsPubGet) {
    return [
      Finding.problem(
        'Packages',
        'not resolved since the last change of pubspec.yaml',
        'prismarine cook',
      ),
    ];
  }
  final out = [Finding.ok('Packages', 'resolved')];
  for (final e in project.shaders) {
    if (engine == null) continue;
    try {
      out.add(
        shadersCurrent(project, e, engine.impellerc)
            ? Finding.ok('Shaders ${e.id}', 'current')
            : Finding.problem(
                'Shaders ${e.id}',
                'not cooked for the current sources and engine',
                'prismarine cook --shaders',
              ),
      );
    } on ProjectError catch (x) {
      out.add(Finding.problem('Shaders ${e.id}', '$x', 'edit prismarine.yaml'));
    }
  }
  for (final a in project.assets) {
    try {
      final o = a.outDir(env, appDir: project.dir);
      out.add(
        assetStamp(a, o).key == assetKey(project, a, o)
            ? Finding.ok('Assets ${a.id}', 'current in $o')
            : Finding.problem(
                'Assets ${a.id}',
                'not prepared in $o for the current inputs',
                'prismarine cook --assets',
              ),
      );
    } on ProjectError catch (x) {
      out.add(Finding.problem('Assets ${a.id}', '$x', 'edit prismarine.yaml'));
    }
  }
  return out;
}

class _EnvCommand extends BaseCommand {
  _EnvCommand() {
    addApp();
    argParser.addOption(
      'shell',
      allowed: ['sh', 'powershell', 'cmd'],
      defaultsTo: Platform.isWindows ? 'powershell' : 'sh',
      help: 'The shell that reads the lines.',
    );
  }

  @override
  String get name => 'env';
  @override
  String get description =>
      'Prints the lines that set the Flutter SDK, the pub cache and the engine in a shell.';
  @override
  String get invocation =>
      'prismarine env [--app=<folder>] [--shell=sh|powershell|cmd]';

  @override
  Future<int> run() async {
    needFlutter();
    final env = toolchain.environment;
    final vars = <String, String>{
      'PATH': '${toolchain.flutterRoot}${Platform.pathSeparator}bin',
      'PUB_CACHE': ?toolchain.pubCache,
      'PRISMARINE_ENGINE_DIR': engineDir(env),
    };
    final target = hostTarget();
    // The release of the app gives the engine. Outside an app the release of
    // this checkout gives it.
    final app = findApp(required: false, given: argResults!.option('app'));
    try {
      final release = steps(app).release();
      final e = target == null
          ? null
          : findEngine(engineDir(env), target, release).engine;
      if (e != null) {
        vars['PRISMARINE_IMPELLERC'] = e.impellerc;
        vars['PRISMARINE_ENGINE_ARGS'] = e.flutterArgs.join(' ');
        final profile = findProfileEngine(e, engineDir(env));
        if (profile != null) {
          vars['PRISMARINE_ENGINE_PROFILE_ARGS'] = profile.flutterArgs.join(
            ' ',
          );
        }
      }
    } on Failure catch (f) {
      // An app whose release fails stops here. A shell evaluates stdout, so
      // the failure goes to stderr. Outside an app and outside a checkout the
      // engine lines are left out.
      if (app != null) {
        Ui(out: stderr).printFailure(f);
        return 1;
      }
    }
    for (final MapEntry(:key, :value) in vars.entries) {
      final path = key == 'PATH';
      stdout.writeln(switch (argResults!.option('shell')) {
        'powershell' =>
          path
              ? '\$env:PATH = "$value;" + \$env:PATH'
              : '\$env:$key = "$value"',
        'cmd' => path ? 'set "PATH=$value;%PATH%"' : 'set "$key=$value"',
        _ => path ? 'export PATH="$value:\$PATH"' : 'export $key="$value"',
      });
    }
    return 0;
  }
}

class _PassCommand extends BaseCommand {
  _PassCommand(this.name);
  @override
  final String name;
  @override
  String get description =>
      'Runs $name of the Flutter SDK that prismarine uses, with the pub cache of prismarine.';
  @override
  String get invocation => 'prismarine $name <arguments>';
  @override
  Future<int> run() async => _passThrough(name, argResults!.rest);
}

Future<int> _passThrough(String tool, List<String> args) async {
  final t = Toolchain.find(Platform.environment);
  if (t.flutterRoot == null) {
    stderr.writeln(
      'No Flutter SDK. Install it with:\n  ${Toolchain.installCommand(Platform.environment)}',
    );
    return 1;
  }
  final p = await Process.start(
    tool == 'flutter' ? t.flutter : t.dart,
    args,
    environment: t.environment,
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  return p.exitCode;
}
