import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_replay/prismarine_replay.dart';
import 'package:test/test.dart';

import 'support/counter_game.dart';

Map<String, Object?> _header(int frames, double time, int routeHash) =>
    counterSnapshots.header(
      frames: frames,
      time: time,
      frame: frames,
      routeHash: routeHash,
      bodyBytes: 3,
      writeMs: 1.234,
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('snap'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'the header keeps its key order with the game fields after the hash',
    () {
      final h = counterSnapshots.header(
        frames: 12,
        time: 6.5,
        frame: 40,
        routeHash: -2,
        fields: {'total': 9, 'scene': null},
        bodyBytes: 100,
        writeMs: 0.125,
        reason: 'scene',
      );
      expect(
        jsonEncode(h),
        '{"format":"counter.snapshot/1","version":1,"frames":12,"time":6.5,'
        '"frame":40,"routeHash":"fffffffffffffffe","total":9,"scene":null,'
        '"bodyBytes":100,"writeMs":0.13,"reason":"scene"}',
      );
      expect(_header(1, 0, 0).containsKey('reason'), isFalse);
    },
  );

  test('a file is the header line and the zlib body', () {
    final body = Uint8List.fromList([1, 2, 3]);
    final h = _header(5, 2.5, 99);
    final bytes = snapshotFileBytes(h, body);
    final nl = bytes.indexOf(10);
    expect(utf8.decode(bytes.sublist(0, nl)), jsonEncode(h));
    expect(zlib.decode(bytes.sublist(nl + 1)), body);
    final path = '${dir.path}/${snapshotFileName(5)}';
    expect(path, endsWith('/000000005.snap'));
    counterSnapshots.writeSync(path, h, body);
    expect(File(path).readAsBytesSync(), bytes);
    final s = counterSnapshots.open(path)!;
    expect((s.frames, s.time, s.routeHash), (5, 2.5, 99));
    expect(s.body(), body);
    expect(const SnapshotFormat('counter.snapshot/1', 2).open(path), isNull);
    expect(const SnapshotFormat('other/1', 1).open(path), isNull);
    expect(counterSnapshots.open('${dir.path}/none.snap'), isNull);
  });

  test('the latest snapshot of a route matches its hash', () {
    final rec = recordCounter([1, 2, 3, 4, 5, 6]);
    final route = RouteReader(rec.lines, format: counterRoute);
    final other = recordCounter([9, 9, 9, 9]);
    final body = Uint8List(1);
    for (final f in [2, 4]) {
      counterSnapshots.writeSync(
        '${dir.path}/${snapshotFileName(f)}',
        _header(f, f / 2, route.hashAt(f)),
        body,
      );
    }
    counterSnapshots.writeSync(
      '${dir.path}/${snapshotFileName(3)}',
      _header(3, 1.5, RouteReader(other.lines, format: counterRoute).hashAt(3)),
      body,
    );
    final dirs = [dir.path];
    expect(counterSnapshots.list(dir.path).map((s) => s.frames), [2, 3, 4]);
    expect(counterSnapshots.latestFor(route, frames: 3, dirs: dirs)!.frames, 2);
    expect(counterSnapshots.latestFor(route, frames: 6, dirs: dirs)!.frames, 4);
    expect(counterSnapshots.latestFor(route, frames: 1, dirs: dirs), isNull);
    expect(
      counterSnapshots.latestBeforeTime(route, time: 1.9, dirs: dirs)!.frames,
      2,
    );
  });

  test('pruning keeps the recent ones and the latest of each span', () {
    final body = Uint8List(1);
    for (final t in [10.0, 200.0, 290.0, 400.0, 700.0, 1300.0]) {
      final f = t.toInt();
      counterSnapshots.writeSync(
        '${dir.path}/${snapshotFileName(f)}',
        _header(f, t, 0),
        body,
      );
    }
    final gone = counterSnapshots.prune(dir.path, now: 1400);
    expect(gone.map((p) => p.split('/').last), [
      snapshotFileName(10),
      snapshotFileName(200),
    ]);
    expect(counterSnapshots.list(dir.path).map((s) => s.frames), [
      290,
      400,
      700,
      1300,
    ]);
  });

  test('a write on an isolate prunes and returns the size', () async {
    final path = '${dir.path}/${snapshotFileName(1)}';
    final h = _header(1, 0.5, 0);
    final size = await counterSnapshots.write(
      path,
      h,
      Uint8List(10),
      pruneAt: 0.5,
    );
    expect(size, File(path).lengthSync());
    expect(snapshotSize(size), '1 KB');
    expect(snapshotSize(3 << 20), '3.0 MB');
  });

  test('the schedule waits for a scene open, the period and a held frame', () {
    final s = SnapshotSchedule(every: 10, sceneGap: 2, wait: 3);
    final sim = CounterSim();
    expect(s.due(sim), isNull);
    sim
      ..time = 1
      ..sceneOpens = 1;
    expect(s.due(sim), isNull);
    sim
      ..time = 2.5
      ..sceneOpens = 2;
    expect(s.due(sim), 'scene');
    s.taken(sim);
    sim.time = 12.5;
    expect(s.due(sim), isNull);
    sim.time = 14;
    expect(s.due(sim), isNull);
    sim.time = 15.5;
    expect(s.due(sim), 'periodic');
    s.taken(sim);
    sim
      ..time = 26
      ..frameHeld = true;
    expect(s.due(sim), 'periodic (held frame)');
  });

  test('a body tail reads after the rest', () {
    final game = CounterGame();
    final sim = CounterSim()
      ..total = 4
      ..tail = (Counter()..ticks = 6);
    final body = game.writeState(sim);
    final back = CounterSim();
    game
      ..readState(back, body)
      ..started(back, {'tail': true});
    expect((back.total, back.tail!.ticks), (4, 6));
    final none = game.writeState(CounterSim());
    final again = CounterSim();
    game
      ..readState(again, none)
      ..started(again, {'tail': true});
    expect(again.tail!.ticks, 0);
  });
}
