import 'dart:async';
import 'dart:isolate';

import 'package:prismarine_jobs/prismarine_jobs.dart';
import 'package:test/test.dart';

int _square(int x) => x * x;
List<int> _big(int n) => List<int>.generate(n, (i) => i);
Future<int> _sleep(int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  return 0;
}

void main() {
  test('runs jobs on worker isolates and returns their results', () async {
    final pool = JobPool(workers: 2);
    final main = Isolate.current.hashCode;
    final r = await Future.wait([
      for (var i = 0; i < 5; i++) pool.run(() => _square(i)),
    ]);
    expect(r, [0, 1, 4, 9, 16]);
    final where = await pool.run(() => Isolate.current.hashCode);
    expect(where, isNot(main));
  });

  test('never runs more than its worker count at once', () async {
    final pool = JobPool(workers: 2);
    var peak = 0;
    final t = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (pool.running > peak) peak = pool.running;
    });
    await Future.wait([for (var i = 0; i < 6; i++) pool.run(() => _sleep(30))]);
    t.cancel();
    expect(peak, 2);
  });

  test('higher priority queued jobs start first', () async {
    final pool = JobPool(workers: 1);
    final order = <String>[];
    final block = pool.run(() => _sleep(40));
    final a = pool
        .run(() => 1, priority: JobPriority.background)
        .then((_) => order.add('bg'));
    final b = pool
        .run(() => 2, priority: JobPriority.frame)
        .then((_) => order.add('frame'));
    await Future.wait([block, a, b]);
    expect(order, ['frame', 'bg']);
  });

  test('a cancelled queued job fails with JobCancelled; a throwing job '
      'fails with its error; the pool keeps working', () async {
    final pool = JobPool(workers: 1);
    final block = pool.run(() => _sleep(30));
    final token = JobToken();
    final c = pool.run(() => 1, token: token);
    token.cancel();
    await expectLater(c, throwsA(isA<JobCancelled>()));
    await expectLater(
      pool.run<int>(() => throw const FormatException('bad')),
      throwsA(isA<FormatException>()),
    );
    await block;
    expect(await pool.run(() => _big(1000).length), 1000);
  });

  test('cancelAll fails every queued job (Review Focus 3); idle completes '
      'when the pool drains', () async {
    final pool = JobPool(workers: 1);
    final block = pool.run(() => _sleep(30));
    final q = [for (var i = 0; i < 3; i++) pool.run(() => i)];
    pool.cancelAll();
    for (final f in q) {
      await expectLater(f, throwsA(isA<JobCancelled>()));
    }
    await pool.idle();
    expect(pool.queued + pool.running, 0);
    await block;
  });

  test('stats report label, priority, wait and run times', () async {
    final stats = <JobStats>[];
    final pool = JobPool(workers: 1, onStats: stats.add);
    await pool.run(
      () => _square(3),
      label: 'sq',
      priority: JobPriority.preload,
    );
    expect(stats.single.label, 'sq');
    expect(stats.single.priority, JobPriority.preload);
    expect(stats.single.ok, isTrue);
    expect(stats.single.runMs, greaterThanOrEqualTo(0));
  });

  test('background jobs share at most backgroundWorkers workers, so preload '
      'and frame jobs keep the rest', () async {
    final pool = JobPool(workers: 3, backgroundWorkers: 1);
    var peakBg = 0;
    final t = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (pool.runningBackground > peakBg) peakBg = pool.runningBackground;
    });
    final bg = <Future<int>>[
      for (var i = 0; i < 4; i++)
        pool.run(() => _sleep(20), priority: JobPriority.background),
    ];
    final sw = Stopwatch()..start();
    await pool.run(() => _sleep(1), priority: JobPriority.preload);
    final preloadWait = sw.elapsedMilliseconds;
    await Future.wait(bg);
    t.cancel();
    expect(peakBg, 1);
    expect(preloadWait, lessThan(20), reason: 'not stuck behind background');
  });

  // Review B-2: a closed pool (its session gone) runs nothing new.
  test(
    'close fails queued jobs and every later run with JobCancelled',
    () async {
      final pool = JobPool(workers: 1);
      final block = pool.run(() => _sleep(20));
      final queued = pool.run(() => 1);
      pool.close();
      await expectLater(queued, throwsA(isA<JobCancelled>()));
      await expectLater(pool.run(() => 2), throwsA(isA<JobCancelled>()));
      expect(pool.closed, isTrue);
      await block;
    },
  );
}
