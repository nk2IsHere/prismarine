import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_pbr/builder.dart';
import 'package:vector_math/vector_math_64.dart';

/// The 12 triangles of the box from [lo] to [hi], their fronts outwards.
(List<double>, List<int>) _box(Vector3 lo, Vector3 hi, int first) {
  final p = <double>[
    for (var i = 0; i < 8; i++) ...[
      i & 1 == 0 ? lo.x : hi.x,
      i & 2 == 0 ? lo.y : hi.y,
      i & 4 == 0 ? lo.z : hi.z,
    ],
  ];
  const faces = [
    [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], //
    [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
  ];
  final idx = <int>[
    for (final f in faces) ...[f[0], f[1], f[2], f[0], f[2], f[3]],
  ];
  return (p, [for (final i in idx) i + first]);
}

/// A closed room of 6 by 4 by 6 m with a wall of 0.6 m in its middle that
/// does not reach the far side, in a red material.
GltfDocument _room() {
  final (room, ri) = _box(Vector3(0, 0, 0), Vector3(6, 4, 6), 0);
  final (wall, wi) = _box(Vector3(2.7, 0, 0), Vector3(3.3, 4, 4), 8);
  final b = GltfBuilder();
  final pos = b.addFloatAccessor(
    Float32List.fromList([...room, ...wall]),
    'VEC3',
    minMax: true,
  );
  final idx = b.addIndexAccessor(Uint16List.fromList([...ri, ...wi]));
  final mesh = b.addMesh('room', [
    {
      'attributes': {'POSITION': pos},
      'indices': idx,
      'material': b.addMaterial({
        'name': 'red',
        'pbrMetallicRoughness': {
          'baseColorFactor': [0.25, 0.04, 0.01, 1],
        },
      }),
    },
  ]);
  b.setScene([
    b.addNode({'mesh': mesh}),
  ]);
  final glb = readGlb(b.toGlb());
  return GltfDocument(glb.json, [glb.bin]);
}

void main() {
  final v = buildGiVolume([_room()], maxCells: 30000, maxProbes: 200);

  int cellOf(double x, double y, double z) =>
      ((x - v.origin.x) / v.cell).floor() +
      v.nx *
          (((y - v.origin.y) / v.cell).floor() +
              v.ny * ((z - v.origin.z) / v.cell).floor());

  (int, int, int) xyz(double x, double y, double z) => (
    ((x - v.origin.x) / v.cell).floor(),
    ((y - v.origin.y) / v.cell).floor(),
    ((z - v.origin.z) / v.cell).floor(),
  );

  test('the grid has about the asked number of cells', () {
    expect(v.nx * v.ny * v.nz, inInclusiveRange(30000, 45000));
    expect(v.cell, closeTo(0.169, 0.001));
  });

  test('a cell of the floor holds the base colour and the normal', () {
    final i = cellOf(1.05, 0.01, 1.05);
    final w0 = v.voxels[i * 2], w1 = v.voxels[i * 2 + 1];
    expect(w0 >> 24, 0);
    // The square roots of 0.25, 0.04 and 0.01 in bytes.
    expect(w0 & 0xff, 128);
    expect((w0 >> 8) & 0xff, 51);
    expect((w0 >> 16) & 0xff, 26);
    // The floor faces down, out of the box. Down is the lower half of the
    // octahedron, at a corner.
    final ox = (w1 & 0xff).toSigned(8), oy = ((w1 >> 8) & 0xff).toSigned(8);
    expect(ox.abs() + oy.abs(), greaterThan(250));
  });

  test('the inside of the wall is solid and the room is not', () {
    final (wx, wy, wz) = xyz(3.0, 2.0, 2.0);
    expect(v.flagsAt(wx, wy, wz) & GiVolume.solid, GiVolume.solid);
    expect(v.distanceAt(wx, wy, wz), 0);
    final (rx, ry, rz) = xyz(1.4, 2.0, 3.0);
    expect(v.flagsAt(rx, ry, rz), 0);
    expect(v.distanceAt(rx, ry, rz), greaterThanOrEqualTo(5));
    final (ox, oy, oz) = xyz(-0.1, 2.0, 3.0);
    expect(v.distanceAt(ox, oy, oz), greaterThan(0));
  });

  test('probes are on only out of the surfaces and the wall', () {
    expect(v.probeCount, lessThanOrEqualTo(200));
    expect(v.activeCount, greaterThan(0));
    expect(v.probes.length, v.probeCount * 4 + v.activeCount * 4);
    for (var j = 0; j < v.activeCount; j++) {
      final i = v.probes[v.probeCount * 4 + j * 4].toInt();
      expect(v.probes[i * 4 + 3], 1);
      final x = i % v.px, y = (i ~/ v.px) % v.py, z = i ~/ (v.px * v.py);
      final (cx, cy, cz) = xyz(
        v.probeOrigin.x + x * v.spacing + v.probes[i * 4],
        v.probeOrigin.y + y * v.spacing + v.probes[i * 4 + 1],
        v.probeOrigin.z + z * v.spacing + v.probes[i * 4 + 2],
      );
      expect(v.distanceAt(cx, cy, cz), greaterThan(0));
    }
  });
}
