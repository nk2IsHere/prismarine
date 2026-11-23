# prismarine_snap

prismarine_snap writes an object graph to bytes and reads it back with the same identities. Shared references and cycles
come back as they were. Use it for snapshots of a running simulation, such as the whole state of a game between two
frames. The details are on [the area page](../../docs/areas/snap.md).

## Usage

You register a codec for each class with state in a `SnapRegistry`. The `writeNew` function of a codec writes the inputs
of the constructor where the object is first referenced. `make` reads them back. The `write` and `read` functions handle
the rest of the state, which the stream holds after all objects exist. A cycle therefore does not run through a
constructor. Numbers, strings, lists, maps, sets and typed lists need no codec.

`SnapWriter.value` writes a value and `finish` writes the queued state. `takeBytes` returns the stream. On the other
side, `SnapReader.ref` reads the value and `finish` reads the state. Objects that both sides already have, such as the
roots of a fresh session, go to `known` on the writer and on the reader in the same order. The stream then holds only
their state. A closure made with `snapFn` is written as its recipe and made again by the factory that `SnapRegistry.fn`
registers.

## Example

The example writes two units that target each other and reads them back. It is
[`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools. The bytes of a
stream are the same on every platform.
