import 'dart:io';

/// Writes the memory census line of each isolate every
/// `PRISMARINE_MEM_LOG=<seconds>`. The line counts the entries in the caches
/// of the isolate and carries the wall clock in ms. The lines of the
/// isolates then line up.
final class MemLog {
  MemLog(this.who, {this.figures});

  final String who;

  /// The figures of the caller for the process line, appended after the
  /// resident set. Null adds nothing.
  final String Function()? figures;
  static final _period = int.tryParse(
    Platform.environment['PRISMARINE_MEM_LOG'] ??
        Platform.environment['MCSM_MEM_LOG'] ??
        '',
  );
  final _clock = Stopwatch()..start();
  int _next = 0;

  /// True when a line is due now.
  bool get due {
    final p = _period;
    if (p == null) return false;
    final ms = _clock.elapsedMilliseconds;
    if (ms < _next) return false;
    _next = ms + p * 1000;
    return true;
  }

  // alloc-cold: a diagnostics line now and then.
  /// The resident set of the process and the [figures] of the caller.
  String get process {
    final rss = 'rss ${ProcessInfo.currentRss >> 20} MB';
    final f = figures;
    return f == null ? rss : '$rss, ${f()}';
  }

  // alloc-cold: a diagnostics line now and then.
  /// Returns the census line for [census].
  String line(String census) =>
      'mem $who ${DateTime.now().millisecondsSinceEpoch} $census';
}
