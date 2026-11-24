import 'dart:async';
import 'dart:io';

/// A step that failed, with its cause in one sentence and the command that
/// fixes it.
class Failure implements Exception {
  Failure(this.cause, {this.fix, this.log});
  final String cause;

  /// The command or action that fixes it, or null when none is known.
  final String? fix;

  /// The log file of the tool that failed.
  final String? log;

  @override
  String toString() => cause;
}

/// Prints the steps of a command, one line each with its result and time. On
/// a terminal the line of a running step shows its time and the last line of
/// its tool.
class Ui {
  Ui({this.verbose = false, IOSink? out, bool? terminal})
    : out = out ?? stdout,
      terminal = terminal ?? (stdout.hasTerminal && !verbose);

  /// Prints the output of the tools while they run.
  final bool verbose;
  final IOSink out;

  /// True when the status line of a running step is redrawn in place.
  final bool terminal;

  String? _label;
  String _status = '';
  Stopwatch? _clock;
  Timer? _ticker;

  /// Runs [body] as the step [label]. Prints the line of the step with the
  /// text that [done] returns and the time. A [Failure] of [body] is printed
  /// with its cause and fix and thrown again.
  Future<T> step<T>(
    String label,
    Future<T> Function() body, {
    String Function(T)? done,
  }) async {
    _label = label;
    _status = '';
    final clock = _clock = Stopwatch()..start();
    if (terminal) {
      _draw();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _draw(),
      );
    }
    try {
      final r = await body();
      _end(
        '$label ${done == null ? 'ok' : done(r)}, ${seconds(clock.elapsed)}',
      );
      return r;
    } on Failure catch (f) {
      _end('$label failed after ${seconds(clock.elapsed)}');
      printFailure(f);
      rethrow;
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _label = null;
    }
  }

  /// Sets the text after the time of the running step, such as the last
  /// line of its tool.
  set status(String text) {
    _status = text;
  }

  /// Prints a line between the step lines.
  void line(String text) {
    if (terminal && _label != null) out.write('\r\x1b[2K');
    out.writeln(text);
    if (terminal && _label != null) _draw();
  }

  void printFailure(Failure f) {
    out.writeln('  ${f.cause}');
    if (f.log != null) out.writeln('  log: ${f.log}');
    // A fix of several commands prints one per line, under the first.
    final fix = f.fix?.replaceAll('\n', '\n       ');
    if (fix != null) out.writeln('  fix: $fix');
  }

  void _draw() {
    final label = _label;
    if (label == null) return;
    final width = stdout.hasTerminal ? stdout.terminalColumns : 100;
    var text = '$label ... ${seconds(_clock!.elapsed)}';
    if (_status.isNotEmpty) text = '$text  $_status';
    if (text.length > width - 1) text = text.substring(0, width - 1);
    out.write('\r\x1b[2K$text');
  }

  void _end(String text) {
    if (terminal) out.write('\r\x1b[2K');
    out.writeln(text);
  }
}

/// Formats [d] as `2.4 s` under a minute and as `3 min 5 s` from a minute on.
String seconds(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)} s';
  return '${ms ~/ 60000} min ${(ms % 60000) ~/ 1000} s';
}
