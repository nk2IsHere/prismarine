import 'package:prismarine_profiler/summary.dart';
import 'package:test/test.dart';

void main() {
  test('gcSummary pairs B/E per name and thread and reads X durations', () {
    final s = gcSummary([
      {
        'name': 'thread_name',
        'ph': 'M',
        'args': {'name': 'x'},
      },
      {'name': 'Scavenge', 'tid': 1, 'ph': 'B', 'ts': 1000},
      {'name': 'Scavenge', 'tid': 1, 'ph': 'E', 'ts': 2500},
      {'name': 'Scavenge', 'tid': 1, 'ph': 'B', 'ts': 5000},
      {'name': 'Scavenge', 'tid': 1, 'ph': 'E', 'ts': 5500},
      {
        'name': 'CollectOldGeneration',
        'tid': 2,
        'ph': 'X',
        'ts': 9000,
        'dur': 4000,
      },
    ], 2.0);
    final sc = s['Scavenge'] as Map;
    expect(sc['count'], 2);
    expect(sc['totalMs'], closeTo(2.0, 1e-9));
    expect(sc['maxMs'], closeTo(1.5, 1e-9));
    expect(s['scavengesPerSecond'], 1.0);
    expect((s['CollectOldGeneration'] as Map)['maxMs'], closeTo(4.0, 1e-9));
  });

  test('allocTop ranks classes by bytes allocated in the window', () {
    final top = allocTop([('A', 100), ('B', 5000), ('C', 300)], 2.0, n: 2);
    expect(top.map((e) => e['class']), ['B', 'C']);
    expect(top.first['mbPerSecond'], closeTo(5000 / 2 / 1e6, 1e-12));
  });
}
