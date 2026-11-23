import 'dart:async';

/// The longest stretch a scene load runs on the UI isolate before it lets
/// a frame through.
const loadTurn = Duration(milliseconds: 4);

final _since = Stopwatch()..start();

/// A point where a scene load (a host built ahead of time, or a UI scene)
/// may give the event loop a turn: null while the load has run less than
/// [loadTurn] since the last turn, else a future that completes after
/// one (a zero timer, so a frame due meanwhile is drawn first). Loads use
/// `if (loadPace() case final p?) await p;` so the common case stays
/// synchronous. Pacing changes when the work runs, never what it builds.
Future<void>? loadPace() {
  if (_since.elapsed < loadTurn) return null;
  return Future<void>.delayed(Duration.zero).whenComplete(_since.reset);
}
