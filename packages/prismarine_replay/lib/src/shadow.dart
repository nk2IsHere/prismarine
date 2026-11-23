import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'replay_start.dart';
import 'route.dart';
import 'sim.dart';
import 'snapshot_schedule.dart';

/// Runs a snapshot shadow. [lines] is the route of a running sim as it is
/// recorded, header first. The shadow replays it and writes the run's
/// snapshots into the folder `dir` of [config]. A run restored from the
/// snapshot `restoredFrom` of [config] is restored from it once the route
/// reaches it. Ends when [lines] ends. [beforeFrame] runs before each
/// replayed frame.
Future<void> runShadow<S extends ReplaySim, R extends RouteReader>(
  ReplayGame<S, R> game,
  Map<String, Object?> config,
  Stream<String> lines, {
  required void Function(String) log,
  void Function()? beforeFrame,
}) async {
  final restoredFrom = config['restoredFrom'] as String?;
  final restored = restoredFrom == null
      ? null
      : game.snapshots.open(restoredFrom);
  if (restoredFrom != null && restored == null) {
    log('not started: $restoredFrom is no snapshot');
    return;
  }
  R? route;
  S? sim;
  ReplaySnapshots<S, R>? writer;
  var failed = false;

  // The sim is booted or restored once the route reaches the frame to start
  // from, the snapshot's or 0.
  void start(S s, R r) {
    if (restored != null) {
      game.readState(s, restored.body());
      r.skipTo(restored.frames);
    } else {
      game.boot(s, r, config);
    }
    game.started(s, config);
    writer = ReplaySnapshots(
      game,
      config['dir']! as String,
      r,
      // The schedule starts here, as the running sim's does.
      schedule: SnapshotSchedule.fromEnvironment()..taken(s),
      log: log,
    );
  }

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final r = route;
    if (r == null) {
      final opened = route = game.route([line]);
      sim = game.open(opened, config);
      continue;
    }
    r.addLine(line);
    final s = sim!;
    if (writer == null) {
      if (r.length < (restored?.frames ?? 0)) continue;
      start(s, r);
    }
    if (failed) continue;
    while (true) {
      beforeFrame?.call();
      final dt = game.input(s, r);
      if (dt == null) break;
      s.step(dt);
      try {
        writer!.afterFrame(s);
      } on Object catch (e, st) {
        // A state that the codecs miss is reported once and the shadow
        // stops writing.
        log('not written ($e)\n$st');
        failed = true;
        break;
      }
    }
  }
  if (sim case final s?) game.close(s);
}

/// Runs a shadow process. The standard input is one JSON line of
/// configuration, then the route's lines. The standard output gets the log
/// lines. Exits when the input ends.
Future<Never> shadowMain<S extends ReplaySim, R extends RouteReader>(
  ReplayGame<S, R> game, {
  void Function()? beforeFrame,
}) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  final it = StreamIterator(lines);
  if (await it.moveNext()) {
    final config = jsonDecode(it.current) as Map<String, Object?>;
    final rest = StreamController<String>();
    unawaited(() async {
      while (await it.moveNext()) {
        rest.add(it.current);
      }
      await rest.close();
    }());
    await runShadow(
      game,
      config,
      rest.stream,
      log: stdout.writeln,
      beforeFrame: beforeFrame,
    );
  }
  await stdout.flush();
  exit(0);
}

/// A running shadow process, from the side of the host.
class ShadowProcess {
  ShadowProcess._(this._process);

  final Process _process;
  bool _closed = false;

  /// Starts [executable] with [config], then sends [lines], the route so
  /// far with its header first. Each line of the shadow's output goes to
  /// [log].
  static Future<ShadowProcess> start(
    String executable, {
    required Map<String, Object?> config,
    required List<String> lines,
    required void Function(String) log,
  }) async {
    final p = await Process.start(executable, const []);
    for (final out in [p.stdout, p.stderr]) {
      out
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => log('snapshot shadow: $l'));
    }
    final s = ShadowProcess._(p);
    p.stdin.writeln(jsonEncode(config));
    lines.forEach(s.add);
    unawaited(
      p.exitCode.then((code) {
        s._closed = true;
        if (code != 0) log('snapshot shadow: exited ($code)');
      }),
    );
    return s;
  }

  /// Sends the route's next line.
  void add(String line) {
    if (!_closed) _process.stdin.writeln(line);
  }

  /// Ends the shadow's input. The shadow finishes the snapshot that it
  /// writes and exits.
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_process.stdin.close().catchError((Object _) {}));
  }
}
