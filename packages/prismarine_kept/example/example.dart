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
