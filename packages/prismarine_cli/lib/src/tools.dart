import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ui.dart';

/// The result of a tool run.
class ToolResult {
  ToolResult(this.exitCode, this.output);
  final int exitCode;

  /// The output of the tool, stdout and stderr together.
  final String output;

  bool get ok => exitCode == 0;
}

/// Runs the tools of the steps. Each run writes the output of its tool to a
/// log file. With `--verbose` the output is also printed, else the line of
/// the running step shows its last line.
class Tools {
  Tools(this.ui, {required this.environment, required this.logDir});

  final Ui ui;

  /// The environment of every tool, with the Flutter SDK first on `PATH`.
  final Map<String, String> environment;

  final String logDir;

  /// Runs [command] in [dir] with [extraEnvironment] added to [environment].
  /// Writes its output to `<logDir>/<log>.log` and returns its exit code and
  /// output.
  Future<ToolResult> run(
    List<String> command, {
    String? dir,
    required String log,
    Map<String, String> extraEnvironment = const {},
  }) async {
    final file = File('$logDir/$log.log')..parent.createSync(recursive: true);
    final sink = file.openWrite()..writeln('\$ ${command.join(' ')}');
    final Process p;
    try {
      p = await Process.start(
        command.first,
        command.sublist(1),
        workingDirectory: dir,
        environment: {...environment, ...extraEnvironment},
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
      );
    } on ProcessException catch (e) {
      await sink.close();
      return ToolResult(127, e.message);
    }
    final text = StringBuffer();
    // A tool that prints `progress: <done>/<total> <what>` lines (a step that
    // runs for hours) keeps its last one as the status; its other lines
    // then go only to the log.
    var progress = false;
    void take(String line) {
      sink.writeln(line);
      text.writeln(line);
      final t = line.trim();
      if (t.startsWith('progress: ')) {
        progress = true;
        ui.status = t.substring(10);
        if (ui.verbose) ui.line(line);
      } else if (ui.verbose) {
        ui.line(line);
      } else if (t.isNotEmpty && !progress) {
        ui.status = t;
      }
    }

    final a = p.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(take)
        .asFuture<void>();
    final b = p.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(take)
        .asFuture<void>();
    final code = await p.exitCode;
    await Future.wait([a, b]);
    await sink.close();
    return ToolResult(code, text.toString());
  }

  /// Runs [command] and throws a [Failure] with [cause], the last lines of
  /// its output and [fix] when it exits with an error. [dir], [log] and
  /// [extraEnvironment] are as for [run].
  Future<ToolResult> must(
    List<String> command, {
    String? dir,
    required String log,
    required String cause,
    String? fix,
    Map<String, String> extraEnvironment = const {},
  }) async {
    final r = await run(
      command,
      dir: dir,
      log: log,
      extraEnvironment: extraEnvironment,
    );
    if (r.ok) return r;
    final tail = r.output
        .trimRight()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final last = tail.skip(tail.length > 12 ? tail.length - 12 : 0);
    throw Failure(
      '$cause\n${last.map((l) => '    $l').join('\n')}',
      fix: fix,
      log: '$logDir/$log.log',
    );
  }

  /// Runs [command] in [dir] without a log and returns its output, or null
  /// when it cannot start or fails.
  String? read(List<String> command, {String? dir}) {
    try {
      final r = Process.runSync(
        command.first,
        command.sublist(1),
        workingDirectory: dir,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
      );
      if (r.exitCode != 0) return null;
      return '${r.stdout}'.trim();
    } on ProcessException {
      return null;
    }
  }
}
