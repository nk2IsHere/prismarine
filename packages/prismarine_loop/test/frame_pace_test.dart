import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

/// Runs [seconds] of display frames at 120 Hz. A step takes [stepFrames]
/// display frames when the pace allows fewer. Every [dropEvery]-th step gets
/// no picture. The stages take [stageMs].
({int now, int shown}) _run(
  FramePace p, {
  required int from,
  required int shown,
  required double seconds,
  int stepFrames = 1,
  int dropEvery = 0,
  double stageMs = 4,
}) {
  const frame = 8333;
  var now = from, steps = 0, busyUntil = from;
  final end = from + (seconds * 1e6).round();
  while (now < end) {
    now += frame;
    if (now < busyUntil) continue;
    if (p.begin(now) < 0) continue;
    busyUntil = now + (stepFrames - 1) * frame + 1;
    if (dropEvery == 0 || ++steps % dropEvery != 0) shown++;
    p.end(
      now + 1000,
      presented: true,
      shown: shown,
      simMs: stageMs,
      uiMs: stageMs,
      buildMs: stageMs,
      gpuMs: stageMs,
    );
  }
  return (now: now, shown: shown);
}

void main() {
  FramePace pace() => FramePace()..intervalUs = 8333;

  test('a scene that holds the display rate stays on it', () {
    final p = pace();
    _run(p, from: 0, shown: 0, seconds: 10);
    expect(p.divisor, 1);
    expect(p.downs, 0);
  });

  test('four pictures in five still count as the display rate', () {
    final p = pace();
    _run(p, from: 0, shown: 0, seconds: 10, dropEvery: 5, stageMs: 9);
    expect(p.divisor, 1);
  });

  test('late steps take the pace down and the slower pace steps evenly', () {
    final p = pace();
    // Every step takes two display frames, and every step is late at pace 1.
    final a = _run(
      p,
      from: 0,
      shown: 0,
      seconds: 3,
      stepFrames: 2,
      stageMs: 14,
    );
    expect(p.divisor, 2);
    expect(p.downs, 1);
    // At pace 2 the steps are on time. The stages do not fit the display
    // rate.
    _run(
      p,
      from: a.now,
      shown: a.shown,
      seconds: 10,
      stepFrames: 2,
      stageMs: 14,
    );
    expect(p.divisor, 2);
    expect(p.downs, 1);
  });

  test('too few pictures take the pace down after two windows', () {
    final p = pace();
    final a = _run(
      p,
      from: 0,
      shown: 0,
      seconds: 1.5,
      dropEvery: 3,
      stageMs: 4,
    );
    expect(p.divisor, 1, reason: 'one bad window is not enough');
    _run(
      p,
      from: a.now,
      shown: a.shown,
      seconds: 1.5,
      dropEvery: 3,
      stageMs: 4,
    );
    expect(p.divisor, 2);
  });

  test('a lighter scene takes the pace back up', () {
    final p = pace();
    final a = _run(
      p,
      from: 0,
      shown: 0,
      seconds: 3,
      stepFrames: 2,
      stageMs: 14,
    );
    expect(p.divisor, 2);
    _run(p, from: a.now, shown: a.shown, seconds: 4, stageMs: 4);
    expect(p.divisor, 1);
    expect(p.ups, 1);
  });

  test('stages that fit one by one but not in a row keep the pace', () {
    final p = pace();
    final a = _run(
      p,
      from: 0,
      shown: 0,
      seconds: 3,
      stepFrames: 2,
      stageMs: 14,
    );
    expect(p.divisor, 2);
    // The simulation, the build and the record take 6.5 ms each and 19.5 ms
    // in a row.
    _run(p, from: a.now, shown: a.shown, seconds: 10, stageMs: 6.5);
    expect(p.divisor, 2);
  });

  test('a rate that does not hold is tried again after longer waits', () {
    final p = pace();
    // The stages read as fitting, but at the display rate steps come late.
    var s = _run(p, from: 0, shown: 0, seconds: 3, stepFrames: 2, stageMs: 4);
    expect(p.divisor, 2);
    final tries = <int>[];
    var ups = 0;
    for (var i = 0; i < 400; i++) {
      s = _run(
        p,
        from: s.now,
        shown: s.shown,
        seconds: 0.25,
        stepFrames: 2,
        stageMs: 4,
      );
      if (p.ups != ups) {
        ups = p.ups;
        tries.add(s.now);
      }
    }
    expect(tries.length, greaterThan(2));
    final gaps = [
      for (var i = 1; i < tries.length; i++) tries[i] - tries[i - 1],
    ];
    expect(gaps.last, greaterThan(gaps.first));
  });

  test('ticks that start late still step whole, even display frames', () {
    final p = FramePace(fixed: 2)..intervalUs = 8333;
    const delays = [300, 5200, 400, 6100, 900, 300, 7000, 350, 2500, 4100];
    final steps = <int>[], at = <int>[];
    for (var frame = 0; frame < 400; frame++) {
      final now = frame * 8333 + delays[frame % delays.length];
      final step = p.begin(now);
      if (step < 0) continue;
      steps.add(step);
      at.add(frame);
    }
    expect(steps.skip(1).toSet(), {2 * 8333});
    expect(at.every((f) => f.isEven), isTrue);
    // At the rate of the display a tick that a busy isolate held back steps
    // its own frame. The tick after a missed frame steps two.
    final q = FramePace()..intervalUs = 8333;
    final got = <int>[];
    for (final (frame, delay) in [(0, 300), (1, 6000), (2, 400), (4, 500)]) {
      got.add(q.begin(frame * 8333 + delay));
    }
    expect(got, [0, 8333, 8333, 2 * 8333]);
  });

  test('a fixed pace never changes; loads and pauses decide nothing', () {
    final f = FramePace(fixed: 2)..intervalUs = 8333;
    _run(f, from: 0, shown: 0, seconds: 5, stepFrames: 3, stageMs: 30);
    expect(f.divisor, 2);
    final p = pace();
    // Steps 150 ms apart are hitches and not a rate.
    var now = 0;
    for (var i = 0; i < 100; i++) {
      now += 150000;
      p.begin(now);
      p.end(
        now,
        presented: false,
        shown: 0,
        simMs: 1,
        uiMs: 1,
        buildMs: 1,
        gpuMs: 1,
      );
    }
    expect(p.divisor, 1);
  });

  test('a step is its display frames in seconds, unrounded', () {
    final p = FramePace(fixed: 2)
      ..intervalUs = 8333
      ..intervalSeconds = 1 / 120;
    p.begin(0);
    // The ticks are a little late in their display frames.
    expect(p.begin(16900), 16666);
    expect(p.stepSeconds, 2 / 120);
    // Steps of exactly 1/60 s reach a key at 1/30 s in two frames, as a
    // fixed 1/60 s step does. Whole microseconds stop 0.7 µs short.
    var clock = 0.0;
    for (var i = 0; i < 2; i++) {
      clock = (clock + p.stepSeconds).toDouble();
    }
    expect(clock >= 1 / 30 - 1e-12, isTrue);
  });
}
