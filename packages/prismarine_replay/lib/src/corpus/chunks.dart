import 'dart:math' as math;

/// One snapshot that a baseline replay wrote. [file] is in the run's
/// snapshot folder. [frames] is the route frames played before it, [frame]
/// the sim's frame count and [time] the simulated time. [wall] is the wall
/// seconds of the baseline replay when it was taken. [cost] is those seconds
/// as one replay alone would take them.
class BaselineSnap {
  BaselineSnap(Map<String, Object?> j)
    : file = j['file']! as String,
      frames = (j['frames']! as num).toInt(),
      frame = (j['frame']! as num).toInt(),
      time = (j['time']! as num).toDouble(),
      wall = (j['wall']! as num).toDouble(),
      cost = ((j['cost'] ?? j['wall'])! as num).toDouble();
  final String file;
  final int frames, frame;
  final double time, wall, cost;
}

/// A piece of a run. It starts at the snapshot [from] or at the route's
/// start when null. It plays to [toFrames] route frames or to the end when
/// null. [estimate] is the baseline's cost of the piece.
class Chunk {
  Chunk(this.index, this.from, this.toFrames, this.estimate);
  final int index;
  final BaselineSnap? from;
  final int? toFrames;
  final double estimate;
}

/// Cuts a run into chunks of at most [target] baseline cost at its
/// snapshots. A stretch between two snapshots is not cut. [total] is the
/// cost of the whole baseline replay. [until] in simulated seconds drops the
/// snapshots after it. A run without snapshots is one chunk.
List<Chunk> planChunks(
  List<BaselineSnap> snaps,
  double total, {
  required double target,
  double? until,
}) {
  final usable = [
    for (final s in snaps)
      if (until == null || s.time < until) s,
  ]..sort((a, b) => a.frames.compareTo(b.frames));
  // A limit ends the run early. Its cost is interpolated between the last
  // snapshot before the limit and the first after it.
  var end = total;
  final after = [
    for (final s in snaps)
      if (until != null && s.time >= until) s,
  ]..sort((a, b) => a.frames.compareTo(b.frames));
  if (until != null && after.isNotEmpty) {
    final u = usable.lastOrNull, d = after.first;
    final (t0, w0) = u == null ? (0.0, 0.0) : (u.time, u.cost);
    end = d.time > t0 ? w0 + (until - t0) / (d.time - t0) * (d.cost - w0) : w0;
  }
  final starts = <BaselineSnap?>[null];
  var at = 0.0;
  var i = 0;
  while (target > 0 && end - at > target && i < usable.length) {
    // The furthest snapshot within the target, else the next one.
    var k = i;
    while (k + 1 < usable.length && usable[k + 1].cost - at <= target) {
      k++;
    }
    if (usable[k].cost <= at) break;
    starts.add(usable[k]);
    at = usable[k].cost;
    i = k + 1;
  }
  return [
    for (var c = 0; c < starts.length; c++)
      Chunk(
        c,
        starts[c],
        c + 1 < starts.length ? starts[c + 1]!.frames : null,
        (c + 1 < starts.length ? starts[c + 1]!.cost : end) -
            (starts[c]?.cost ?? 0),
      ),
  ];
}

/// Returns the result of a run from the results of its chunks in order, as
/// a whole run reports it. It has the first divergence per channel and,
/// unless [full], only those within [tail] simulated seconds of the
/// earliest one.
Map<String, Object?> mergeChunks(
  List<Map<String, Object?>> parts, {
  required double tail,
  required bool full,
}) {
  final first = <String, Map<String, Object?>>{};
  for (final p in parts) {
    for (final d in (p['first'] as List?) ?? const []) {
      final m = (d as Map).cast<String, Object?>();
      final ch = m['channel']! as String;
      final had = first[ch];
      if (had == null || (m['frame']! as num) < (had['frame']! as num)) {
        first[ch] = m;
      }
    }
  }
  var kept = first.values.toList();
  if (!full && kept.isNotEmpty) {
    final t0 = kept.map((d) => (d['t']! as num).toDouble()).reduce(math.min);
    kept = [
      for (final d in kept)
        if ((d['t']! as num).toDouble() <= t0 + tail) d,
    ];
  }
  final last = parts.last;
  return {
    'route': last['route'],
    'frames': parts.fold<int>(
      0,
      (n, p) => n + ((p['frames'] as num?) ?? 0).toInt(),
    ),
    'end': last['end'],
    'wall': parts.fold<double>(0, (n, p) => n + ((p['wall'] as num?) ?? 0)),
    'sliceEnded': ?last['sliceEnded'],
    'stopped': ?parts.map((p) => p['stopped']).nonNulls.firstOrNull,
    'baselineLeft': last['baselineLeft'],
    'first': kept,
    'chunks': [
      for (final p in parts)
        {
          'from': p['fromFrame'] ?? 0,
          'frames': p['frames'],
          'wall': p['wall'],
          'diverged': ((p['first'] as List?) ?? const []).isNotEmpty,
        },
    ],
  };
}

/// The cost that each other replay at the same time adds to one replay. On
/// a machine with 8 cores and 16 threads one replay alone ran 2.9 times as
/// fast as one of 16.
const loadCost = 0.13;

/// The cost of the stretches of a pool's jobs as one replay alone would take
/// them, from the start and end of each job in [spans]. A stretch beside
/// n − 1 other jobs costs its seconds / (1 + (n − 1) · [loadCost]).
class SoloCosts {
  SoloCosts(this.spans)
    : _cuts = {
        for (final (a, b) in spans) ...[a, b],
      }.toList()..sort();
  final List<(double, double)> spans;
  final List<double> _cuts;

  /// Returns the cost of the pool time from [a] to [b].
  double of(double a, double b) {
    var c = 0.0;
    var t = a;
    for (final x in [..._cuts.where((x) => x > a && x < b), b]) {
      final mid = (t + x) / 2;
      final n = spans.where((s) => s.$1 <= mid && mid < s.$2).length;
      c += (x - t) / (1 + (math.max(n, 1) - 1) * loadCost);
      t = x;
    }
    return c;
  }
}
