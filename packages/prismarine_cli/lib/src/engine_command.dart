import 'package:args/command_runner.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'base_command.dart';
import 'engine_build.dart';
import 'engine_release.dart';
import 'tools.dart';
import 'ui.dart';

const _actions = {
  'fetch':
      'Fetches the release of the app, or of this checkout outside an app. The default.',
  'toolchain':
      'Windows: installs the tools that the build of the engine needs. Needs an elevated shell.',
  'setup':
      'Clones depot_tools and Flutter at the engine revision and syncs the sources of the engine.',
  'patch': 'Applies the patches that the engine tree lacks.',
  'build': 'Builds the out folders of the engine for --cpu and --mode.',
  'test':
      'Linux: builds and runs the unit tests of Flutter GPU on SwiftShader.',
  'package': 'Packs the built out folders into release archives in --dest.',
  'release':
      'Sets RELEASE and the engine check of prismarine_scene to a new release name.',
};

class EngineCommand extends BaseCommand {
  EngineCommand() {
    addApp();
    argParser
      ..addOption(
        'target',
        help:
            'fetch: the target, such as macos-x64 or linux-arm64. The default '
            'is this computer.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'fetch: fetches the release again.',
      )
      ..addOption(
        'cpu',
        allowed: ['x64', 'arm64', 'both'],
        help:
            'build, package: the CPUs. The default is the CPU of this computer.',
      )
      ..addOption(
        'mode',
        allowed: ['release', 'profile'],
        defaultsTo: 'release',
        help: 'build: the runtime mode of the engine.',
      )
      ..addOption(
        'jobs',
        help:
            'build: the jobs of ninja. 6 on macOS, 10 on Linux and the cores on Windows by default.',
      )
      ..addFlag(
        'trim',
        negatable: false,
        help:
            'build: deletes the object files after the build, which frees 2 to 4 GB. The next build is a full one.',
      )
      ..addOption(
        'dest',
        help:
            'package: the folder of the archives, <engine dir>/packages by default.',
        valueHelp: 'folder',
      );
  }

  @override
  String get name => 'engine';
  @override
  String get description =>
      'Fetches the patched engine, or builds and packs a release of it.';
  @override
  String get invocation =>
      'prismarine engine [fetch|toolchain|setup|patch|build|test|package|release <name>] [options]';

  @override
  String get usageFooter =>
      '\n\nActions:\n${[for (final MapEntry(:key, :value) in _actions.entries) '  ${key.padRight(11)}$value'].join('\n')}'
      '\n\nExamples:\n'
      '  prismarine engine                    Fetches the engine release of the app\n'
      '  prismarine engine setup              Gets the sources of the engine, once per computer\n'
      '  prismarine engine patch              Applies only the patches that are new\n'
      '  prismarine engine build --cpu=both   Builds the x64 and arm64 out folders\n'
      '  prismarine engine release prismarine2\n'
      '                                       Sets the name of the next release\n'
      '  prismarine engine package --cpu=both --dest=~/engine-packages\n'
      '                                       Packs both out folders into archives';

  @override
  Future<int> run() async {
    needFlutter();
    final rest = argResults!.rest;
    final action = rest.isEmpty ? 'fetch' : rest.first;
    if (!_actions.containsKey(action)) {
      throw UsageException('Unknown action "$action".', usage);
    }
    final env = toolchain.environment;
    if (action == 'fetch') {
      final project = findApp(
        required: false,
        given: argResults!.option('app'),
      );
      final s = steps(project);
      if (project != null) await s.packages();
      final e = await s.engine(
        s.release(),
        force: argResults!.flag('force'),
        target: argResults!.option('target'),
      );
      ui.line('flutter build flags: ${e.flutterArgs.join(' ')}');
      return 0;
    }
    final s = steps(null);
    final release = s.release();
    final dir = engineDir(env);
    final tools = Tools(
      ui,
      environment: env,
      logDir: '${release.checkout}/.dart_tool/prismarine/logs',
    );
    final b = EngineBuild(ui, tools, toolchain, release.checkout, dir);
    final os = hostPlatform();
    final host = hostTarget()!.split('-').last;
    final cpus = switch (argResults!.option('cpu')) {
      'both' => ['x64', 'arm64'],
      final String c => [c],
      null => [host],
    };
    final dest = argResults!.option('dest') ?? '$dir/packages';
    switch (action) {
      case 'toolchain':
        if (os != 'windows') {
          throw Failure(
            'The toolchain action is for Windows. On $os, prismarine doctor lists the missing tools.',
            fix: 'prismarine doctor',
          );
        }
        await installWindowsToolchain(ui, tools);
      case 'setup':
        await b.setup();
      case 'patch':
        await b.patch();
      case 'build':
        final jobs = int.tryParse(argResults!.option('jobs') ?? '');
        // A cross build takes its host tools from the out folder of the CPU of
        // this computer, which is built first.
        final outs = [
          for (final c in [
            ...cpus.where((c) => c == host),
            ...cpus.where((c) => c != host),
          ])
            await b.build(c, jobs: jobs, mode: argResults!.option('mode')!),
        ];
        // A cross build reads the host out folder, so the object files are
        // deleted only after every build.
        if (argResults!.flag('trim')) outs.forEach(b.trim);
      case 'test':
        if (os != 'linux') {
          throw Failure('The tests of the engine run on Linux only.');
        }
        await b.test(jobs: int.tryParse(argResults!.option('jobs') ?? ''));
      case 'package':
        for (final c in cpus) {
          final (target, hostOut) = targetOf(os, c);
          await packageEngine(
            ui: ui,
            tools: tools,
            release: release,
            src: b.src,
            out: outName(os, c),
            target: target,
            dest: dest,
            revision: b.revision,
            hostOut: hostOut,
          );
        }
      case 'release':
        if (rest.length != 2) {
          throw UsageException(
            'release takes the new name, such as prismarine2.',
            usage,
          );
        }
        final tag = await ui.step(
          'release',
          () async => bumpRelease(release.checkout, b.revision, rest[1]),
          done: (t) => 'RELEASE is $t',
        );
        ui.line(
          'Commit RELEASE, engine_check.dart and the prismarine.yaml files, then build and package $tag.',
        );
    }
    return 0;
  }
}
