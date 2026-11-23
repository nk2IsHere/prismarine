import 'package:prismarine_snap/prismarine_snap.dart';

class Unit {
  Unit(this.name);
  final String name;
  int health = 100;
  Unit? target;
}

final registry = SnapRegistry()
  ..codec<Unit>(
    'Unit',
    writeNew: (w, u) => w.str(u.name),
    make: (r) => Unit(r.str()),
    write: (w, u) {
      w.int_(u.health);
      w.ref(u.target);
    },
    read: (r, u) {
      u.health = r.int_();
      u.target = r.ref<Unit?>();
    },
  );

void main() {
  final a = Unit('a'), b = Unit('b');
  a.target = b;
  b
    ..target = a
    ..health = 40;

  final w = SnapWriter(registry)..value([a, b]);
  w.finish();
  final bytes = w.takeBytes();

  final r = SnapReader(registry, bytes);
  final units = r.ref<List<Object?>>().cast<Unit>();
  r.finish();
  final a2 = units[0], b2 = units[1];
  print(
    '${bytes.length} bytes, cycle kept: ${identical(a2.target!.target, a2)}, '
    'health ${b2.health}',
  );
}
