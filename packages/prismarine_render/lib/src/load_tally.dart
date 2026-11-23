import 'dart:typed_data';

/// What the runner made since it started, counted and timed by kind and by
/// who asked: a frame's own record, a frame's new draws made ready before
/// it records them, or a background warm-up. The player reads it at a cut
/// or scene switch and again at its first picture, so a slow switch names
/// the loads it waited for. Every slot is a plain number added in place.
final class LoadTally {
  static const kinds = ['shard', 'texture', 'mesh', 'pipeline', 'state'];
  static const phases = ['record', 'prepare', 'warm'];
  static const shard = 0, texture = 1, mesh = 2, pipeline = 3, state = 4;

  /// Per kind and phase (kind × phases + phase): how many, and their ms.
  final counts = Int32List(kinds.length * phases.length);
  final ms = Float64List(kinds.length * phases.length);

  /// The phase loads count under now: 0 record, 1 prepare, 2 warm.
  int phase = 0;

  /// Sets [phase] from RenderAssets.phase's name.
  void phaseNamed(String name) =>
      phase = name == 'prepare' ? 1 : (name == 'warm' ? 2 : 0);

  void add(int kind, double took) {
    final i = kind * phases.length + phase;
    counts[i]++;
    ms[i] += took;
  }

  /// A copy of the counts and times now, for [since].
  (Int32List, Float64List) mark() =>
      (Int32List.fromList(counts), Float64List.fromList(ms));

  /// What was made since [at] (a [mark]): `kind.phase count ms` entries
  /// with any count, as a JSON-ready map.
  Map<String, Object> since((Int32List, Float64List) at) => {
    for (var i = 0; i < counts.length; i++)
      if (counts[i] > at.$1[i])
        '${kinds[i ~/ phases.length]}.${phases[i % phases.length]}': [
          counts[i] - at.$1[i],
          double.parse((ms[i] - at.$2[i]).toStringAsFixed(1)),
        ],
  };
}
