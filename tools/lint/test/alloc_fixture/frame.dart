// The fixture of the allocation lint, a small program with the one frame
// entry `frame`. The expected kinds of a line follow `// expect:`. A line
// without them must report nothing.
// ignore_for_file: unused_local_variable, unused_element, unused_field
// ignore_for_file: prefer_function_declarations_over_variables
import 'dart:typed_data';

class Vec {
  const Vec(this.x, this.y);
  final double x, y;
}

abstract class Shape {
  double area();
}

class Square implements Shape {
  Square(this.side);
  final double side;
  final corners = <Vec>[]; // expect: literal
  @override
  double area() => side * side;
}

class Circle implements Shape {
  Circle(this.radius);
  final double radius;
  @override
  double area() {
    final label = 'circle $radius'; // expect: string
    return 3.14159 * radius * radius;
  }
}

class Apart {
  double area() => [1.0].length.toDouble();
}

class Kept {
  final values = Float64List(8);
  late final _visit_ = _visit;
  var sum = 0.0;

  void _visit(int i) {
    final copy = values.sublist(0); // expect: new
    sum += copy[i];
  }

  void each(void Function(int) f) {
    for (var i = 0; i < values.length; i++) {
      f(i);
    }
  }

  void run() => each(_visit_);
}

final kept = Kept();
final shapes = <Shape>[Square(2), Circle(1)];
const origin = Vec(0, 0);
Object? slot;
final byName = <String, double>{};

// alloc-cold: a first use
List<int> _load() => List.filled(1024, 0);

// alloc-setup: binds once, its closures run per frame
void bind(void Function(String, double Function(double)) add) {
  final table = <String>[];
  add('twice', (x) {
    final pair = (x, x); // expect: literal
    return pair.$1 * 2;
  });
}

int _plain(int a, int b) => a + b;

double frame(double dt, List<int> ids, Set<int> live) {
  var total = 0.0;
  // Calls reach every override of the receiver's type.
  for (final s in shapes) {
    total += s.area();
  }
  final v = Vec(dt, dt); // expect: new
  final sq = Square(dt); // expect: new
  final c = origin;
  final list = [dt, dt]; // expect: literal
  final text =
      '$dt' // expect: string
      'x';
  final joined = text + text; // expect: string
  final f = (int i) => i + ids.length; // expect: closure
  final g = _plain;
  final m = kept.each; // expect: closure
  slot = dt; // expect: box
  byName['dt'] = dt; // expect: box
  final clamped = dt.clamp(0, 1); // expect: box
  final whole = ids.length.clamp(0, 4);
  for (final id in live) {
    // expect: iterate
    total += id;
  }
  for (final id in ids) {
    total += id;
  }
  final doubled = ids.map((i) => i * 2); // expect: iterate closure
  final big = _load();
  final scratch = Float64List(4); // alloc: the frame's own result
  kept.run();
  total += g(1, 2) + f(1) + whole;
  if (total < 0) throw StateError('negative $total');
  return total + clamped;
}
