import 'dart:math';

import 'package:prismarine_kept/prismarine_kept.dart';
import 'package:test/test.dart';

void main() {
  test('reads and writes as the default map, in insertion order', () {
    final rand = Random(7);
    final kept = KeptMap<String, int>();
    final ref = <String, int>{};
    for (var step = 0; step < 20000; step++) {
      final key = 'k${rand.nextInt(300)}';
      switch (rand.nextInt(10)) {
        case 0 || 1:
          expect(kept.remove(key), ref.remove(key));
        case 2:
          if (rand.nextInt(50) == 0) {
            kept.clear();
            ref.clear();
          }
        default:
          kept[key] = step;
          ref[key] = step;
      }
      expect(kept.length, ref.length);
      expect(kept[key], ref[key]);
      expect(kept.containsKey(key), ref.containsKey(key));
    }
    expect(kept.keys.toList(), ref.keys.toList());
    expect(kept.values.toList(), ref.values.toList());
    final walked = <String>[];
    kept.forEach((k, v) {
      walked.add(k);
      expect(v, ref[k]);
    });
    expect(walked, ref.keys.toList());
  });

  test('clear keeps the storage', () {
    final m = KeptMap<int, int>();
    for (var i = 0; i < 1000; i++) {
      m[i] = i;
    }
    final room = m.capacity;
    for (var frame = 0; frame < 10; frame++) {
      m.clear();
      expect(m, isEmpty);
      for (var i = 0; i < 1000; i++) {
        m[i * 7] = i;
      }
      expect(m.capacity, room);
      expect(m[7 * 999], 999);
    }
  });

  test('removals are packed instead of growing', () {
    final m = KeptMap<int, int>();
    for (var i = 0; i < 3; i++) {
      m[i] = i;
    }
    final room = m.capacity;
    for (var i = 3; i < 1000; i++) {
      m.remove(i - 3);
      m[i] = i;
    }
    expect(m.capacity, room);
    expect(m.keys.toList(), [997, 998, 999]);
  });

  test('identity maps tell equal keys apart', () {
    final a = [1], b = [1];
    final m = KeptMap<List<int>, String>.identity()
      ..[a] = 'a'
      ..[b] = 'b';
    expect(m.length, 2);
    expect(m[a], 'a');
    expect(m[b], 'b');
    expect(m[[1]], isNull);
  });

  test('a change while walking throws', () {
    final m = KeptMap<int, int>()
      ..[1] = 1
      ..[2] = 2;
    expect(
      () => m.forEach((k, _) => m[k + 10] = 0),
      throwsA(isA<ConcurrentModificationError>()),
    );
    expect(() {
      for (final k in m.keys) {
        m.remove(k);
      }
    }, throwsA(isA<ConcurrentModificationError>()));
  });

  test('sets add, find and remove as the default set', () {
    final s = KeptSet<String>();
    expect(s.add('a'), isTrue);
    expect(s.add('a'), isFalse);
    s.addAll(['b', 'c']);
    expect(s.remove('b'), isTrue);
    expect(s.remove('b'), isFalse);
    expect(s.toList(), ['a', 'c']);
    expect(s.contains('c'), isTrue);
    expect(s.lookup('a'), 'a');
    final room = s.capacity;
    s.clear();
    expect(s, isEmpty);
    expect(s.capacity, room);
    final i = KeptSet<List<int>>.identity();
    final x = [1];
    i
      ..add(x)
      ..add([1]);
    expect(i.length, 2);
    expect(i.contains(x), isTrue);
  });

  test('lists add, read and cut as the default list, storage kept', () {
    final l = KeptList<int>();
    final ref = <int>[];
    for (var i = 0; i < 100; i++) {
      l.add(i);
      ref.add(i);
    }
    expect(l, ref);
    final room = l.capacity;
    l.clear();
    expect(l, isEmpty);
    expect(l.capacity, room);
    l.addAll([3, 1, 2]);
    l.sort();
    expect(l, [1, 2, 3]);
    l[0] = 9;
    expect(l.toList(), [9, 2, 3]);
    l.length = 1;
    expect(l, [9]);
    expect(() => l[1], throwsRangeError);
    expect(() => l.length = 5, throwsUnsupportedError);
    final n = KeptList<int?>()..length = 2;
    expect(n, [null, null]);
  });

  test('nested and repeated key walks see every key', () {
    final m = KeptMap<int, int>();
    for (var i = 0; i < 5; i++) {
      m[i] = i * 10;
    }
    final pairs = <(int, int)>[];
    for (var round = 0; round < 3; round++) {
      pairs.clear();
      for (final a in m.keys) {
        for (final b in m.keys) {
          pairs.add((a, b));
        }
      }
      expect(pairs.length, 25);
      expect(m.values.toList(), [0, 10, 20, 30, 40]);
    }
    // A walk that stops early does not change the next walk.
    for (final k in m.keys) {
      if (k == 1) break;
    }
    expect(m.keys.toList(), [0, 1, 2, 3, 4]);
  });

  test('keptCopyOf keeps a list while it holds the same objects', () {
    final a = Object(), b = Object();
    final first = keptCopyOf(null, [a, b]);
    expect(first, [a, b]);
    expect(() => first.add(a), throwsUnsupportedError);
    expect(identical(keptCopyOf(first, [a, b]), first), isTrue);
    final swapped = keptCopyOf(first, [b, a]);
    expect(identical(swapped, first), isFalse);
    expect(swapped, [b, a]);
    expect(keptCopyOf(swapped, [b]), [b]);
  });
}
