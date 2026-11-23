# prismarine_kept

prismarine_kept has maps, sets and lists that keep their storage when you clear them. The maps and sets of the Dart VM
free their storage on `clear()` and allocate it again when the next frame fills them. Use a kept collection for state
that every frame clears and fills again, such as the set of meshes drawn in this frame. The details are on [the area
page](../../docs/areas/kept.md).

## Usage

`KeptMap`, `KeptSet` and `KeptList` implement `Map`, `Set` and `List`. You use them as the collections of the core
library. A map or a set compares its keys with `==` and `hashCode`, or by identity with its `identity` constructor.
Iteration follows the order of insertion. A change during iteration throws, as with the default map.

## Example

The example clears and fills a set and a list in each frame. It is [`example/example.dart`](example/example.dart):

```dart
import 'package:prismarine_kept/prismarine_kept.dart';

class Mesh {
  Mesh(this.name);
  final String name;
}

/// The meshes that this frame draws, cleared and filled every frame.
final drawn = KeptSet<Mesh>.identity();

/// The meshes in the order of their first draw in this frame.
final order = KeptList<Mesh>();

void frame(Iterable<Mesh> visible) {
  drawn.clear();
  order.clear();
  for (final m in visible) {
    if (drawn.add(m)) order.add(m);
  }
}

void main() {
  final rock = Mesh('rock'), tree = Mesh('tree');
  frame([rock, tree, rock]);
  frame([tree, rock]);
  print(order.map((m) => m.name).join(', '));
}
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools.
