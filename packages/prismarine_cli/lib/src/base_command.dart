import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'app.dart';
import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';

const examples = '''

Examples:
  prismarine run                       Builds and starts the app of this folder, or the sample at the root of prismarine
  prismarine run -- --perf=10          Passes --perf=10 to the app
  prismarine build linux               Builds the app for Linux in release mode
  prismarine run --stock --app=tools/gpu_smoke
                                       Runs gpu_smoke on the engine of Flutter
  prismarine doctor                    Lists every problem of the toolchain and the engine with its fix
  prismarine cook apps/prismarine_sample
  prismarine env --shell=powershell | Invoke-Expression''';

abstract class BaseCommand extends Command<int> {
  BaseCommand() {
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Shows the output of every tool as it runs.',
    );
  }

  @override
  String get usageFooter => examples;

  bool get verbose => argResults!.flag('verbose');

  late final Ui ui = Ui(verbose: verbose);
  late final Toolchain toolchain = Toolchain.find(Platform.environment);

  /// The app of the command. It is `--app`, else a folder in the arguments, else
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
