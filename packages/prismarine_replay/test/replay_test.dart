import 'dart:async';
import 'dart:io';

import 'package:prismarine_replay/prismarine_replay.dart';
import 'package:test/test.dart';

import 'support/counter_game.dart';

/// Plays [route] on [sim] to its end.
void playOut(CounterGame game, CounterSim sim, RouteReader route) {
  while (true) {
    final dt = game.input(sim, route);
    if (dt == null) return;
    sim.step(dt);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('replay'));
  tearDown(() => dir.deleteSync(recursive: true));

  final adds = [for (var i = 0; i < 400; i++) i % 7];

  test('a replay from a snapshot ends in the state of a full replay', () {
    final game = CounterGame(dirs: [dir.path]);
    final rec = recordCounter(adds);
    final full = openReplay(game, game.route(rec.lines));
    expect((full.snapshot, full.sim.booted), (null, true));
    final writer = ReplaySnapshots(
      game,
      dir.path,
      game.route(rec.lines),
      schedule: SnapshotSchedule(every: 4, sceneGap: 4, wait: 0),
      prune: false,
    );
    final r = writer.route;
    while (true) {
      final dt = game.input(full.sim, r);
      if (dt == null) break;
      full.sim.step(dt);
      writer.afterFrame(full.sim);
    }
    expect(writer.written, isNotEmpty);
    final logs = <String>[];
    final route = game.route(rec.lines);
    final part = openReplay(game, route, frames: 300, log: logs.add);
    expect(part.snapshot, isNotNull);
    expect(part.snapshot!.frames, lessThanOrEqualTo(300));
    expect(part.snapshot!.header['total'], isA<int>());
    expect(route.played, part.snapshot!.frames);
    expect(part.sim.booted, isFalse);
    expect(logs.single, startsWith('snapshot: '));
    playOut(game, part.sim, route);
    expect(
      (part.sim.total, part.sim.frame, part.sim.time),
      (full.sim.total, full.sim.frame, full.sim.time),
    );
  });

  test('a snapshot that does not read boots the replay', () {
    final game = CounterGame(dirs: [dir.path]);
    final rec = recordCounter(adds);
    final route = game.route(rec.lines);
    counterSnapshots.writeSync(
      '${dir.path}/${snapshotFileName(5)}',
      counterSnapshots.header(
        frames: 5,
        time: 2.5,
        frame: 5,
        routeHash: route.hashAt(5),
        bodyBytes: 1,
        writeMs: 0,
      ),
      .fromList([9]),
    );
    final logs = <String>[];
    final start = openReplay(game, route, frames: 10, log: logs.add);
    expect((start.snapshot, start.sim.booted, route.played), (null, true, 0));
    expect(logs.single, contains('not read'));
  });

  test('the shadow writes the snapshots of a route as it arrives', () async {
    final game = CounterGame();
    final rec = recordCounter(adds);
    final lines = StreamController<String>();
    final logs = <String>[];
    final done = runShadow(
      game,
      {'dir': dir.path},
      lines.stream,
      log: logs.add,
    );
    for (final l in rec.lines) {
      lines.add(l);
      await Future<void>.delayed(Duration.zero);
    }
    await lines.close();
    await done;
    final snaps = counterSnapshots.list(dir.path);
    expect(snaps, isNotEmpty);
    final route = game.route(rec.lines);
    for (final s in snaps) {
      expect(route.hashAt(s.frames), s.routeHash);
    }
    // A shadow of a run restored from the last snapshot starts there.
    final from = snaps.last;
    final second = Directory('${dir.path}/second')..createSync();
    final more = recordCounter([...adds, ...adds]);
    final restored = runShadow(
      game,
      {'dir': second.path, 'restoredFrom': from.path},
      Stream.fromIterable(more.lines),
      log: logs.add,
    );
    await restored;
    for (final s in counterSnapshots.list(second.path)) {
      expect(s.frames, greaterThan(from.frames));
      expect(game.route(more.lines).hashAt(s.frames), s.routeHash);
    }
  });

  test('a shadow refuses a restore from a file that is no snapshot', () async {
    final logs = <String>[];
    await runShadow(
      CounterGame(),
      {'dir': dir.path, 'restoredFrom': '${dir.path}/none.snap'},
      const Stream.empty(),
      log: logs.add,
    );
    expect(logs.single, startsWith('not started'));
  });
}
