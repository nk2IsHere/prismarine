import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_scene/model.dart';

/// A triangle of side 1 at x, y and z.
List<double> _tri(double x, double y, double z) => [
  x, y, z, x + 1, y, z, x, y + 1, z, //
];

void main() {
  test('triangles come in Morton order of their centers', () {
    // Triangles at the far corner, the near corner, along x and along y.
    final pos = Float32List.fromList([
      ..._tri(10, 10, 10),
      ..._tri(0, 0, 0),
      ..._tri(10, 0, 0),
      ..._tri(0, 10, 0),
    ]);
    final idx = Uint32List.fromList([for (var i = 0; i < 12; i++) i]);
    expect(mortonOrder(idx, pos), [1, 2, 3, 0]);
  });

  test('the indices of a large primitive are sorted in place', () {
    final b = GltfBuilder();
    // Triangles that alternate between two corners of their box.
    final pos = b.addFloatAccessor(
      Float32List.fromList([
        for (var t = 0; t < 8; t++)
          ..._tri(
            t.isEven ? 0 : 100,
            (t.isEven ? 0 : 100) + t * 0.1,
            t.isEven ? 0 : 100,
          ),
      ]),
      'VEC3',
      minMax: true,
    );
    final idx = b.addIndexAccessor(
      Uint16List.fromList([for (var i = 0; i < 24; i++) i]),
    );
    final mesh = b.addMesh('m', [
      {
        'attributes': {'POSITION': pos},
        'indices': idx,
      },
    ]);
    b.setScene([
      b.addNode({'mesh': mesh}),
    ]);
    final glb = readGlb(b.toGlb());
    final doc = GltfDocument(glb.json, [glb.bin]);
    expect(sortTrianglesForRuns(doc, minTriangles: 4), 1);
    final first = [for (final i in doc.uints(idx)) i ~/ 3].toSet().toList();
    expect(first, [0, 2, 4, 6, 1, 3, 5, 7]);
    expect(sortTrianglesForRuns(doc, minTriangles: 8), 0);
  });
}
