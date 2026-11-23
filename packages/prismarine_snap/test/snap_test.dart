import 'dart:typed_data';

import 'package:prismarine_snap/prismarine_snap.dart';
import 'package:test/test.dart';

class Node {
  Node(this.name);
  final String name;
  Node? next;
  final children = <Node>[];
  Object? payload;
}

SnapRegistry _registry() => SnapRegistry()
  ..codec<Node>(
    'Node',
    writeNew: (w, o) => w.str(o.name),
    make: (r) => Node(r.str()),
    write: (w, o) {
      w.ref(o.next);
      w.list(o.children, w.ref);
      w.value(o.payload);
    },
    read: (r, o) {
      o.next = r.ref<Node?>();
      r.listInto(o.children, r.ref<Node>);
      o.payload = r.value();
    },
  )
  ..fn('adder', (a) => _adder(a[0]! as int));

int Function(int) _adder(int n) =>
    (x) => x + n;

void main() {
  test('a cyclic graph, shared values and recipes round-trip', () {
    final a = Node('a'), b = Node('b');
    final shared = <String, dynamic>{
      'x': 1.5,
      'l': <Object?>[1, 'two', null, -0.0],
    };
    a
      ..next = b
      ..children.addAll([b, a])
      ..payload = [
        shared,
        shared,
        Float32List.fromList([1, 2, 3]),
      ];
    b
      ..next = a
      ..payload = snapFn(_adder(3), 'adder', [3]);
    final w = SnapWriter(_registry());
    final root = Node('root');
    w.known(root);
    root.next = a;
    w.fillKnown(root);
    w.finish();
    final bytes = w.takeBytes();

    final root2 = Node('root');
    final r = SnapReader(_registry(), bytes)..known(root2);
    r.fillKnown(root2);
    r.finish();
    expect(r.atEnd, isTrue);
    final a2 = root2.next!;
    final b2 = a2.next!;
    expect(a2.name, 'a');
    expect(b2.next, same(a2));
    expect(a2.children[0], same(b2));
    expect(a2.children[1], same(a2));
    final p = a2.payload! as List;
    expect(p[0], same(p[1]));
    expect(p[0], isA<Map<String, dynamic>>());
    expect((p[0] as Map)['l'], isA<List<Object?>>());
    expect((((p[0] as Map)['l'] as List)[3] as double).isNegative, isTrue);
    expect(p[2], isA<Float32List>());
    final f = b2.payload! as int Function(int);
    expect(f(4), 7);
    expect(snapFnRecipe(f)?.$1, 'adder');
  });

  test('container kinds keep their element types and shapes', () {
    final w = SnapWriter(SnapRegistry());
    final values = [
      <double>[1, 2],
      List<int>.filled(2, 7),
      List<String>.unmodifiable(['a']),
      <String, Object?>{'k': null},
      <int>{1, 2},
    ];
    for (final v in values) {
      w.value(v);
    }
    final r = SnapReader(SnapRegistry(), w.takeBytes());
    final l1 = r.value();
    expect(l1, isA<List<double>>());
    // The VM reports growable, fixed and unmodifiable lists as one runtime
    // type. They are read back growable.
    expect(r.value(), isA<List<int>>());
    expect(r.value(), isA<List<String>>());
    expect(r.value(), isA<Map<String, Object?>>());
    expect(r.value(), isA<Set<int>>());
  });

  test('a closure without a recipe is an error', () {
    final w = SnapWriter(SnapRegistry());
    expect(() => w.value(() => 1), throwsA(isA<SnapError>()));
  });
}
