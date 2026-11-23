// Summaries of a profiled window. The GC pauses come from the GC stream of
// the VM timeline and the allocation by class from the allocation profile.

/// Sums the GC [events] by name into count, total, maximum and p95 in
/// milliseconds, with `scavengesPerSecond` over [seconds]. B and E events
/// pair by name and thread. X events carry their `dur`.
Map<String, Object?> gcSummary(
  List<Map<String, Object?>> events,
  double seconds,
) {
  final open = <(String, Object?), int>{};
  final durs = <String, List<double>>{};
  // Metadata events with ph M carry no timestamp.
  final sorted = [
    for (final e in events)
      if (e['ts'] is num) e,
  ]..sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));
  for (final e in sorted) {
    final name = e['name'] as String? ?? '?';
    final key = (name, e['tid']);
    final ts = (e['ts'] as num).toInt();
    switch (e['ph']) {
      case 'B':
        open[key] = ts;
      case 'E':
        final b = open.remove(key);
        if (b != null) (durs[name] ??= []).add((ts - b) / 1000);
      case 'X':
        (durs[name] ??= []).add(((e['dur'] as num?) ?? 0) / 1000);
    }
  }
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in durs.entries) {
    final v = [...value]..sort();
    out[key] = {
      'count': v.length,
      'totalMs': v.fold(0.0, (a, b) => a + b),
      'maxMs': v.last,
      'p95Ms': v[((v.length - 1) * 0.95).round()],
    };
  }
  final scavenges = (durs['Scavenge'] ?? const []).length;
  out['scavengesPerSecond'] = seconds > 0 ? scavenges / seconds : 0.0;
  return out;
}

/// Returns the [n] classes of [bytesByClass] with the most bytes and their
/// MB/s over [seconds]. A class with a count in [instances] also gets its
/// count and mean size, which tell many small allocations from a few large
/// ones.
List<Map<String, Object?>> allocTop(
  List<(String, int)> bytesByClass,
  double seconds, {
  int n = 40,
  Map<String, int> instances = const {},
}) {
  final s = [...bytesByClass]..sort((a, b) => b.$2.compareTo(a.$2));
  return [
    for (final (name, bytes) in s.take(n))
      {
        'class': name,
        'bytes': bytes,
        'mbPerSecond': seconds > 0 ? bytes / seconds / 1e6 : 0.0,
        if (instances[name] case final i? when i > 0) ...{
          'instances': i,
          'meanBytes': bytes / i,
        },
      },
  ];
}
