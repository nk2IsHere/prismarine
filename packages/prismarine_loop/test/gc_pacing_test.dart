// Tests the idle point of GC pacing, the cases in which it lets the VM
// collect and the time it gives.
import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the frame end is an idle point unless a picture is on its way; '
      'the record end always is', () {
    final calls = <(int, int, int)>[];
    var busy = false;
    final gc = GcPacing(
      enabled: true,
      collect: (budget, lo, hi) {
        calls.add((budget, lo, hi));
        return 0;
      },
      busy: () => busy,
      frameMicros: 1000000,
      idleMinBytes: 8,
      idleMaxBytes: 32,
    );
    gc.beginFrame();
    gc.endFrame();
    expect(calls, hasLength(1));
    // The time left of the interval of the frame, with the bounds as given.
    expect(calls.single.$1, inInclusiveRange(900000, 1000000));
    expect((calls.single.$2, calls.single.$3), (8, 32));

    busy = true;
    gc.beginFrame();
    gc.endFrame();
    expect(calls, hasLength(1));
    gc.idlePoint();
    expect(calls, hasLength(2));
    gc.stop();
  });

  test('a frame past its interval gives no time; a collection is reported '
      'with its time and budget', () {
    final reported = <(int, double)>[];
    final budgets = <int>[];
    final gc = GcPacing(
      enabled: true,
      collect: (budget, lo, hi) {
        budgets.add(budget);
        return 1;
      },
      frameMicros: 0,
      onIdle: (ran, ms, budgetMs) => reported.add((ran, budgetMs)),
    );
    gc.beginFrame();
    gc.idlePoint();
    expect(budgets, [0]);
    expect(reported, [(1, 0.0)]);
    expect(gc.idleCollections, 1);
  });

  test('nothing is asked on an engine without the call, or when off', () {
    var asked = 0;
    GcPacing(enabled: true).idlePoint();
    GcPacing(
        enabled: false,
        collect: (_, _, _) {
          asked++;
          return 0;
        },
      )
      ..beginFrame()
      ..endFrame()
      ..idlePoint();
    expect(asked, 0);
  });

  test('a switch\'s hold compacts once the old space grew the bytes asked '
      'for past what the last compaction left, and only then', () {
    var capacity = 150;
    final asked = <int>[];
    final reported = <(int, int)>[];
    final gc = GcPacing(
      enabled: true,
      oldSpace: (request) {
        asked.add(request);
        capacity -= 100;
        return 2;
      },
      // The used size does not measure free memory and is not read.
      heap: (which) => which == 1 ? capacity : throw StateError('$which'),
      compactGrowthBytes: 200,
      onCompact: (ms, before, after) => reported.add((before, after)),
    );
    gc.switchHold();
    expect(asked, isEmpty);
    capacity = 1000;
    gc.switchHold();
    expect(asked, [2]);
    expect(reported, [(1000, 900)]);
    expect(gc.compactions, 1);
    // The growth counts from the size after the compaction, 900.
    capacity = 1050;
    gc.switchHold();
    expect(asked, [2]);
    capacity = 1100;
    gc.switchHold();
    expect(asked, [2, 2]);
  });

  test('no compaction without the engine\'s calls or when off', () {
    var asked = 0;
    GcPacing(enabled: true, compactGrowthBytes: 0).switchHold();
    GcPacing(
      enabled: true,
      oldSpace: (_) => ++asked,
      heap: (which) => which == 1 ? 1000 : 0,
    ).switchHold();
    expect(asked, 0);
  });

  test('a coming scene starts the mark when its switch will compact, at '
      'most once in 10 s, and the compaction says it was marked ahead', () {
    var capacity = 100;
    final asked = <int>[];
    final gc = GcPacing(
      enabled: true,
      oldSpace: (request) {
        asked.add(request);
        if (request == 2) capacity = 50;
        return request == 1 ? 1 : 2;
      },
      heap: (which) => which == 1 ? capacity : 0,
      compactGrowthBytes: 200,
    );
    gc.premark();
    expect(asked, isEmpty);
    capacity = 1000;
    gc
      ..premark()
      ..premark();
    expect(asked, [1]);
    expect(gc.premarks, 1);
    gc.switchHold();
    expect(asked, [1, 2]);
    expect(gc.lastPremarkAge, isNotNull);
    capacity = 1000;
    gc.switchHold();
    expect(gc.lastPremarkAge, isNull);
  });
}
