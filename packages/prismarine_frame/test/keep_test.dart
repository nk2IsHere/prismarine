import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

void main() {
  group('SkinSources', () {
    test('appends each source once, 4-byte aligned, and grows', () {
      final s = SkinSources(8);
      expect(s.add(Uint8List.fromList([1, 2, 3])), 0);
      final first = s.view;
      expect(s.add(Uint8List.fromList([4, 5, 6, 7, 8])), 4);
      expect(s.length, 12);
      expect(s.bytes.length, greaterThanOrEqualTo(12));
      expect(s.view.sublist(0, 9), [1, 2, 3, 0, 4, 5, 6, 7, 8]);
      // A new view whenever the sources grew, so a codec sends them again.
      expect(identical(first, s.view), isFalse);
    });
  });

  group('SkinGroups', () {
    test('gives each mesh whole 64-thread groups', () {
      final g = SkinGroups();
      expect(g.add(0, 64), 0);
      expect(g.add(1, 65), 1);
      expect(g.add(2, 1), 3);
      expect(g.count, 4);
      expect(g.table.sublist(0, 4), [0, 1, 1, 2]);
    });

    test('keeps its bytes view while its count holds', () {
      final g = SkinGroups()..add(0, 100);
      final a = g.bytes;
      expect(a.length, 8);
      g
        ..clear()
        ..add(3, 100);
      expect(identical(g.bytes, a), isTrue);
      expect(a.buffer.asUint32List(0, 2), [3, 3]);
      g.add(4, 1);
      expect(g.bytes.length, 12);
    });
  });

  group('SkinDispatch', () {
    test('keeps the dispatch while its groups and sources hold', () {
      final d = SkinDispatch();
      final sources = Uint8List(4);
      expect(d.kept(2, sources), isNull);
      final plan = DispatchPlan('skin', 'p', const [2, 1, 1], StageResources());
      d.keep(plan, 2, sources);
      expect(identical(d.kept(2, sources), plan), isTrue);
      expect(d.kept(3, sources), isNull);
      expect(d.kept(2, Uint8List(4)), isNull);
    });
  });

  group('BlockRing', () {
    test(
      'gives the same block while the bytes hold and turns once a frame',
      () {
        final r = BlockRing();
        final a = r.give(Uint8List.fromList([1, 2]), 0)!;
        expect(identical(r.give(Uint8List.fromList([1, 2]), 0), a), isTrue);
        final b = r.give(Uint8List.fromList([3, 4]), 1)!;
        expect(identical(a, b), isFalse);
        expect(b, [3, 4]);
        // A second change in the same frame: written again, or none.
        expect(r.give(Uint8List.fromList([5, 6]), 1, overwrite: false), isNull);
        expect(identical(r.give(Uint8List.fromList([5, 6]), 1), b), isTrue);
        expect(a, [1, 2]);
      },
    );
  });

  group('keptRowSet', () {
    test('gives the same set while its lists hold', () {
      final plan = DrawPlan(
        label: 'a',
        vertex: 'v',
        pixel: 'p',
        geometry: const ScreenGeometry(3),
        state: const DrawState(),
        viewport: [0, 0, 64, 64, 0, 1],
        vertexResources: StageResources(),
        pixelResources: StageResources(),
      );
      final a = keptRowSet('test pass', [1, 2], [plan, plan]);
      final b = keptRowSet('test pass', [1, 2], [plan, plan]);
      expect(identical(a, b), isTrue);
      final c = keptRowSet('test pass', [1, 3], [plan, plan]);
      expect(identical(a, c), isFalse);
    });
  });
}
