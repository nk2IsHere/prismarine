import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'app.dart';
import 'doctor.dart';
import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';

/// Runs the prismarine command with [args] and returns its exit code.
Future<int> runPrismarine(List<String> args) async {
  if (args.isNotEmpty && (args.first == 'flutter' || args.first == 'dart')) {
    return _passThrough(args.first, args.sublist(1));
  }
  final runner = _Runner()
    ..addCommand(_RunCommand())
    ..addCommand(_BuildCommand())
    ..addCommand(_CookCommand())
    ..addCommand(_EngineCommand())
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
  String get usageFooter => _examples;
}

const _examples = '''

Examples:
  prismarine run                       Builds and starts the app of this folder, or the sample at the root of prismarine
  prismarine run -- --perf=10          Passes --perf=10 to the app
  prismarine build linux               Builds the app for Linux in release mode
  prismarine run --stock --app=tools/gpu_smoke
                                       Runs gpu_smoke on the engine of Flutter
  prismarine doctor                    Lists every problem of the toolchain and the engine with its fix
  prismarine cook apps/prismarine_sample
  prismarine env --shell=powershell | Invoke-Expression''';

abstract class _Command extends Command<int> {
  _Command() {
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Shows the output of every tool as it runs.',
    );
  }

  @override
  String get usageFooter => _examples;

  bool get verbose => argResults!.flag('verbose');

  late final Ui ui = Ui(verbose: verbose);
  late final Toolchain toolchain = Toolchain.find(Platform.environment);

  /// The app of the command: `--app`, else a folder in the arguments, else
  /// the nearest folder with a `prismarine.yaml`, else the sample at the
  /// root of a prismarine checkout.
  Project? findApp({bool required = true, String? given}) {
    final dir = given ?? Project.find(Directory.current.path) ?? _sample();
    if (dir == null) {
      if (!required) return null;
      ui.printFailure(
        Failure(
          'No prismarine.yaml in ${Directory.current.path} or a folder above it.',
          fix: 'cd into the folder of the app, or pass --app=<folder>',
        ),
      );
      throw Failure('no app');
    }
    try {
      final p = Project.load(Directory(dir).absolute.path);
      if (p == null) {
        ui.printFailure(
          Failure(
            'No prismarine.yaml in $dir.',
            fix: 'pass the folder of an app',
          ),
        );
        throw Failure('no app');
      }
      return p;
    } on ProjectError catch (e) {
      ui.printFailure(Failure('$e', fix: 'edit $dir/prismarine.yaml'));
      throw Failure('bad project');
    }
  }

  String? _sample() {
    final d = '${Directory.current.path}/apps/prismarine_sample';
    return File('$d/prismarine.yaml').existsSync() &&
            File(
              '${Directory.current.path}/third_party/flutter_engine/RELEASE',
            ).existsSync()
        ? d
        : null;
  }

  AppSteps steps(Project? project) {
    final logs = project == null
        ? '${Directory.systemTemp.path}/prismarine-logs'
        : '${project.dir}/.dart_tool/prismarine/logs';
    return AppSteps(
      ui,
      toolchain,
      Tools(ui, environment: toolchain.environment, logDir: logs),
      project: project,
    );
  }

  void addApp() => argParser.addOption(
    'app',
    help:
        'The folder of the app. By default the nearest folder with a prismarine.yaml.',
    valueHelp: 'folder',
  );

  /// Stops with the install command when no Flutter SDK is found.
  void needFlutter() {
    if (toolchain.flutterRoot != null) return;
    ui.printFailure(
      Failure(
        'No Flutter SDK in PRISMARINE_FLUTTER, ~/.prismarine/flutter or on PATH.',
        fix: Toolchain.installCommand(Platform.environment),
      ),
    );
    throw Failure('no flutter');
  }
}

/// The steps up to the build that `build` and `run` share. Returns the
/// path of the built app.
Future<String> _buildApp(
  _Command c,
  String platform,
  List<String> extra, {
  bool debug = false,
  bool stock = false,
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
  await s.assets();
  if (debug || stock) {
    c.ui.line(
      'This ${debug ? 'debug' : 'release'} build runs on the engine of '
      'Flutter, without the patches.',
    );
  }
  return s.build(platform, debug || stock ? null : engine, extra, debug: debug);
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

void _addStock(ArgParser p) => p.addFlag(
  'stock',
  negatable: false,
  help:
      'Builds in release mode on the engine of Flutter, without the patches, '
      'such as for a comparison.',
);

class _RunCommand extends _Command {
  _RunCommand() {
    addApp();
    _addStock(argParser);
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
    final app = await _buildApp(
      this,
      platform,
      const [],
      stock: argResults!.flag('stock'),
    );
    ui.line('run ${app.split(RegExp(r'[/\\]')).last}');
    final p = await Process.start(
      app,
      _afterPlatform(argResults!),
      mode: ProcessStartMode.inheritStdio,
    );
    return p.exitCode;
  }
}

class _BuildCommand extends _Command {
  _BuildCommand() {
    addApp();
    argParser.addFlag(
      'debug',
      negatable: false,
      help:
          'Builds in debug mode on the engine of Flutter, without the patches.',
    );
    _addStock(argParser);
  }

  @override
  String get name => 'build';
  @override
  String get description =>
      'Checks the toolchain, fetches the engine, cooks and builds the app in release mode on the patched engine.';
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
    );
    ui.line(app);
    return 0;
  }
}

class _CookCommand extends _Command {
  _CookCommand() {
    addApp();
    argParser
      ..addFlag('shaders', negatable: false, help: 'Cooks only the shaders.')
      ..addFlag('assets', negatable: false, help: 'Runs only the asset steps.')
      ..addFlag(
        'force',
        negatable: false,
        help: 'Cooks again what is current.',
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

class _EngineCommand extends _Command {
  _EngineCommand() {
    addApp();
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Fetches the release again.',
    );
  }

  @override
  String get name => 'engine';
  @override
  String get description =>
      'Fetches the patched engine of the release of the app, or of this checkout outside an app.';
  @override
  String get invocation => 'prismarine engine [--force]';

  @override
  Future<int> run() async {
    needFlutter();
    final project = findApp(required: false, given: argResults!.option('app'));
    final s = steps(project);
    if (project != null) await s.packages();
    final release = s.release();
    final e = await s.engine(release, force: argResults!.flag('force'));
    ui.line('flutter build flags: ${e.flutterArgs.join(' ')}');
    return 0;
  }
}

class _DoctorCommand extends _Command {
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
    try {
      release = s.release();
    } on Object {
      release = null;
    }
    final groups = <String, List<Finding>>{
      'toolchain': ToolchainChecks(
        toolchain,
        read,
        os: hostPlatform(),
        env: env,
      ).all(release),
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

/// The checks of the packages and the cook state of [project].
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
      final o = a.outDir(env);
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

class _EnvCommand extends _Command {
  _EnvCommand() {
    argParser.addOption(
      'shell',
      allowed: ['sh', 'powershell', 'cmd'],
      defaultsTo: Platform.isWindows ? 'powershell' : 'sh',
      help: 'The shell of the lines.',
    );
  }

  @override
  String get name => 'env';
  @override
  String get description =>
      'Prints the lines that set the Flutter SDK, the pub cache and the engine in a shell.';
  @override
  String get invocation => 'prismarine env [--shell=sh|powershell|cmd]';

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
    try {
      final release = steps(null).release();
      final e = target == null
          ? null
          : findEngine(engineDir(env), target, release).engine;
      if (e != null) {
        vars['PRISMARINE_IMPELLERC'] = e.impellerc;
        vars['PRISMARINE_ENGINE_ARGS'] = e.flutterArgs.join(' ');
      }
    } on Failure {
      // Outside a checkout the engine lines are left out.
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

class _PassCommand extends _Command {
  _PassCommand(this.name);
  @override
  final String name;
  @override
  String get description =>
      'Runs $name of the Flutter SDK of prismarine with its pub cache.';
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
