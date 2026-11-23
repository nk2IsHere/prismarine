import 'dart:typed_data';

/// The loads and pipelines that the runner made since it started, counted and
/// timed by kind and by phase. The phase is the record of a frame, the new
/// draws of a frame made ready before it records them or a background warm-up.
/// An app reads it at a cut or scene switch and again at its first picture to
/// see the loads that held up a slow switch. Every slot is a plain number added
/// in place.
final class LoadTally {
  static const kinds = ['shard', 'texture', 'mesh', 'pipeline', 'state'];
  static const phases = ['record', 'prepare', 'warm'];
  static const shard = 0, texture = 1, mesh = 2, pipeline = 3, state = 4;

  /// The count of each kind and phase at kind × phases + phase. [ms] holds
  /// their ms.
  final counts = Int32List(kinds.length * phases.length);
  final ms = Float64List(kinds.length * phases.length);

  /// The phase of the loads now, 0 for record, 1 for prepare and 2 for warm.
  int phase = 0;

  /// Sets [phase] from the name in RenderAssets.phase.
  void phaseNamed(String name) =>
      phase = name == 'prepare' ? 1 : (name == 'warm' ? 2 : 0);

  void add(int kind, double took) {
    final i = kind * phases.length + phase;
    counts[i]++;
    ms[i] += took;
  }

  /// Returns a copy of the counts and times now, for [since].
  (Int32List, Float64List) mark() =>
      (Int32List.fromList(counts), Float64List.fromList(ms));

  /// Returns the loads made since the [mark] [at] as a JSON-ready map of
  /// `kind.phase` entries with a count and ms, for the entries with any
  /// count.
  Map<String, Object> since((Int32List, Float64List) at) => {
    for (var i = 0; i < counts.length; i++)
      if (counts[i] > at.$1[i])
        '${kinds[i ~/ phases.length]}.${phases[i % phases.length]}': [
          counts[i] - at.$1[i],
          double.parse((ms[i] - at.$2[i]).toStringAsFixed(1)),
        ],
  };
}
