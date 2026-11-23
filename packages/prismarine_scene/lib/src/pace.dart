import 'dart:async';

/// The longest stretch a scene load runs on the UI isolate before it lets
/// a frame through.
const loadTurn = Duration(milliseconds: 4);

final _since = Stopwatch()..start();

/// Returns null while a scene load has run for less than [loadTurn] since
/// the last turn of the event loop. Otherwise returns a future that
/// completes after a zero timer, which lets a frame that is due draw first.
///
/// Use it as `if (loadPace() case final p?) await p;` to keep the common
/// case synchronous. Pacing changes when the work runs and not what it
/// builds.
Future<void>? loadPace() {
  if (_since.elapsed < loadTurn) return null;
  return Future<void>.delayed(Duration.zero).whenComplete(_since.reset);
}
