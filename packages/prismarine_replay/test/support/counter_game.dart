import 'dart:typed_data';

import 'package:prismarine_replay/prismarine_replay.dart';
import 'package:prismarine_snap/prismarine_snap.dart';

const counterRoute = RouteFormat('counterRoute');
const counterSnapshots = SnapshotFormat('counter.snapshot/1', 1);

/// A sim that adds the input of each frame to a total. A scene opens at
/// every multiple of 10 in the total.
class CounterSim implements ReplaySim {
  @override
  double time = 0;
  @override
  int frame = 0;
  @override
  int sceneOpens = 0;
  @override
  bool frameHeld = false;
  int total = 0;
  int pending = 0;
  bool booted = false;
  bool closed = false;
  Counter? tail;

  @override
  void step(double dt) {
    final before = total ~/ 10;
    total += pending;
    pending = 0;
    if (total ~/ 10 != before) sceneOpens++;
    time += dt;
    frame++;
    tail?.ticks++;
  }
}

/// The tail object of a counter snapshot.
class Counter {
  int ticks = 0;
}

/// The counter game. A frame line has `add`, the input of the frame.
class CounterGame implements ReplayGame<CounterSim, RouteReader> {
  CounterGame({this.dirs = const []});
  final List<String> dirs;
  final registry = SnapRegistry()
    ..codec<CounterSim>(
      'counter.Sim',
      write: (w, o) => w
        ..f64(o.time)
        ..int_(o.frame)
        ..int_(o.sceneOpens)
        ..int_(o.total),
      read: (r, o) => o
        ..time = r.f64()
        ..frame = r.int_()
        ..sceneOpens = r.int_()
        ..total = r.int_(),
    )
    ..codec<Counter>(
      'counter.Tail',
      write: (w, o) => w.int_(o.ticks),
      read: (r, o) => o.ticks = r.int_(),
    );

  @override
  SnapshotFormat get snapshots => counterSnapshots;

  @override
  RouteReader route(List<String> lines, {String? path}) =>
      RouteReader(lines, format: counterRoute, path: path);

  @override
  CounterSim open(RouteReader route, Map<String, Object?> config) =>
      CounterSim();

  @override
  void boot(CounterSim sim, RouteReader route, Map<String, Object?> config) =>
      sim.booted = true;

  SnapshotTail? _tail;

  @override
  void started(CounterSim sim, Map<String, Object?> config) {
    if (config['tail'] != true) return;
    final t = sim.tail = Counter();
    _tail?.read(t);
    _tail = null;
  }

  @override
  double? input(CounterSim sim, RouteReader route) {
    final f = route.next();
    if (f == null) return null;
    sim.pending = (f['add']! as num).toInt();
    return (f['dt']! as num).toDouble();
  }

  @override
  Uint8List writeState(CounterSim sim) {
    final w = SnapWriter(registry)
      ..uint(counterSnapshots.version)
      ..known(sim)
      ..fillKnown(sim)
      ..finish();
    writeSnapshotTail(w, sim.tail);
    return w.takeBytes();
  }

  @override
  void readState(CounterSim sim, Uint8List body) {
    final r = SnapReader(registry, body);
    if (r.uint() != counterSnapshots.version) throw SnapError('version');
    r
      ..known(sim)
      ..fillKnown(sim)
      ..finish();
    _tail = SnapshotTail(r);
  }

  @override
  Map<String, Object?> snapshotFields(CounterSim sim) => {'total': sim.total};

  @override
  List<String> snapshotDirs(RouteReader route) => dirs;

  @override
  void close(CounterSim sim) => sim.closed = true;
}

/// Records a route of [adds], one frame each, at 0.5 s a frame.
RouteRecorder recordCounter(List<int> adds) {
  final rec = RouteRecorder(counterRoute, {'seed': 7, 't0': 0.0});
  for (final a in adds) {
    rec.addFrame(0.5, {'add': a});
  }
  return rec;
}
