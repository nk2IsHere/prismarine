import 'dart:io';

/// `MCSM_MEM_LOG=<seconds>`: each isolate's memory census line that often
/// (what its caches hold by count), with the wall clock in ms so the
/// isolates' lines line up (diagnostics).
final class MemLog {
  MemLog(this.who, {this.figures});

  final String who;

  /// The caller's own figures for the process line, appended after the
  /// resident set. Null adds nothing.
  final String Function()? figures;
  static final _period = int.tryParse(
    Platform.environment['MCSM_MEM_LOG'] ?? '',
  );
  final _clock = Stopwatch()..start();
  int _next = 0;

  /// Whether a line is due now.
  bool get due {
    final p = _period;
    if (p == null) return false;
    final ms = _clock.elapsedMilliseconds;
    if (ms < _next) return false;
    _next = ms + p * 1000;
    return true;
  }

  // alloc-cold: a diagnostics line now and then.
  /// The process's resident set and the caller's [figures].
  String get process {
    final rss = 'rss ${ProcessInfo.currentRss >> 20} MB';
    final f = figures;
    return f == null ? rss : '$rss, ${f()}';
  }

  // alloc-cold: a diagnostics line now and then.
  /// The census line for [census].
  String line(String census) =>
      'mem $who ${DateTime.now().millisecondsSinceEpoch} $census';
}
