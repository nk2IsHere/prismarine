import 'route.dart';
import 'sim.dart';
import 'snapshot_format.dart';
import 'snapshot_schedule.dart';

/// The start of a replay with its sim and the snapshot that it was restored
/// from, null for a boot.
final class ReplayStart<S extends ReplaySim> {
  const ReplayStart(this.sim, this.snapshot);
  final S sim;
  final SnapshotFile? snapshot;
}

/// Opens the sim of [route] at its latest snapshot at or before [frames]
/// route frames or the simulated time [time], when [snapshots] allows it
/// and one fits. Boots it at the route's start otherwise. A snapshot that
/// does not read is logged and the replay boots.
ReplayStart<S> openReplay<S extends ReplaySim, R extends RouteReader>(
  ReplayGame<S, R> game,
  R route, {
  Map<String, Object?> config = const {},
  int? frames,
  double? time,
  bool snapshots = true,
  List<String>? dirs,
  void Function(String)? log,
}) {
  if (snapshots && (frames != null || time != null)) {
    final where = dirs ?? game.snapshotDirs(route);
    final format = game.snapshots;
    final snap = frames != null
        ? format.latestFor(route, frames: frames, dirs: where)
        : format.latestBeforeTime(route, time: time!, dirs: where);
    if (snap != null) {
      try {
        final sim = game.open(route, config);
        final sw = Stopwatch()..start();
        game.readState(sim, snap.body());
        route.skipTo(snap.frames);
        log?.call(
          'snapshot: ${snap.path} (t ${snap.time.toStringAsFixed(3)}, '
          'frame ${snap.frames} of the route) read in '
          '${sw.elapsedMilliseconds} ms',
        );
        game.started(sim, config);
        return ReplayStart(sim, snap);
      } on Object catch (e) {
        log?.call('snapshot: ${snap.path} not read ($e), the full replay');
      }
    }
  }
  final sim = game.open(route, config);
  game
    ..boot(sim, route, config)
    ..started(sim, config);
  return ReplayStart(sim, null);
}

/// Writes the snapshots of a headless replay into [dir], synchronously.
class ReplaySnapshots<S extends ReplaySim, R extends RouteReader> {
  ReplaySnapshots(
    this.game,
    this.dir,
    this.route, {
    SnapshotSchedule? schedule,
    this.prune = true,
    this.log,
  }) : schedule = schedule ?? SnapshotSchedule.fromEnvironment();

  final ReplayGame<S, R> game;
  final String dir;
  final R route;
  final SnapshotSchedule schedule;

  /// True when old snapshots are pruned as a run prunes them. A corpus
  /// baseline keeps every one.
  final bool prune;
  final void Function(String)? log;

  /// The path, the write time in ms and the body size of each snapshot
  /// written.
  final written = <(String, double, int)>[];

  /// Writes a snapshot of [sim] when the schedule picks this frame.
  void afterFrame(S sim) {
    final why = schedule.due(sim);
    if (why == null) return;
    take(sim, why: why);
  }

  /// Writes a snapshot of [sim] now.
  void take(S sim, {String why = 'asked'}) {
    schedule.taken(sim);
    final sw = Stopwatch()..start();
    final body = game.writeState(sim);
    final ms = sw.elapsedMicroseconds / 1000;
    final frames = route.played;
    final format = game.snapshots;
    final header = format.header(
      frames: frames,
      time: sim.time,
      frame: sim.frame,
      routeHash: route.hashAt(frames),
      fields: game.snapshotFields(sim),
      bodyBytes: body.length,
      writeMs: ms,
      reason: why,
    );
    final path = '$dir/${snapshotFileName(frames)}';
    format.writeSync(path, header, body);
    written.add((path, ms, body.length));
    if (prune) format.prune(dir, now: sim.time);
    log?.call(
      'snapshot ($why): t ${sim.time.toStringAsFixed(3)}, '
      '${snapshotSize(body.length)} in ${ms.toStringAsFixed(1)} ms',
    );
  }
}
