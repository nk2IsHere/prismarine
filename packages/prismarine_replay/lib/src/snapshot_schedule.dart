import 'dart:io';

import 'sim.dart';

/// Decides the frames at which a running sim takes its snapshots. A
/// snapshot follows the first frame after a scene opens, at most one per
/// [sceneGap] seconds of simulated time. One follows every [every] seconds
/// otherwise. A periodic snapshot waits up to [wait] seconds for a
/// frame that the host does not draw.
class SnapshotSchedule {
  SnapshotSchedule({this.every = 180, this.sceneGap = 20, this.wait = 30});

  /// Returns the default schedule. `PRISMARINE_SNAPSHOT_EVERY=<s>`, or its
  /// `MCSM_SNAPSHOT_EVERY` form, takes one every s seconds and at scene
  /// opens at most that often, without the wait.
  factory SnapshotSchedule.fromEnvironment() {
    final env = Platform.environment;
    final every = double.tryParse(
      env['PRISMARINE_SNAPSHOT_EVERY'] ?? env['MCSM_SNAPSHOT_EVERY'] ?? '',
    );
    if (every == null) return SnapshotSchedule();
    return SnapshotSchedule(every: every, sceneGap: every, wait: 0);
  }

  final double every, sceneGap, wait;
  double? _last;
  int? _opens;
  double? _dueSince;

  /// Returns the reason for a snapshot of [sim] after this frame, or null
  /// when none is due.
  String? due(ReplaySim sim) {
    final t = sim.time;
    final last = _last ??= t;
    final opens = sim.sceneOpens;
    final opened = _opens != null && opens != _opens;
    _opens = opens;
    if (opened && t - last >= sceneGap) return 'scene';
    if (t - last < every) return null;
    if (sim.frameHeld) return 'periodic (held frame)';
    final since = _dueSince ??= t;
    return t - since >= wait ? 'periodic' : null;
  }

  /// Records that a snapshot of [sim] was taken now.
  void taken(ReplaySim sim) {
    _last = sim.time;
    _dueSince = null;
  }
}
