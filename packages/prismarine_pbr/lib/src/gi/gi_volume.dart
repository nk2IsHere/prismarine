import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:vector_math/vector_math_64.dart';

import 'gi_voxelize.dart';

/// The voxel copy of static scenes and the irradiance probes over it, as
/// the GI of the renderer reads them.
///
/// A cell holds two words in [voxels]. Word 0 has the red, green and blue of
/// the base colour as the square root of the linear value in bytes 0 to 2
/// and the Chebyshev distance to the next marked cell in byte 3, 0 for a
/// marked or solid cell. Word 1 has the normal in octahedral form as two
/// signed bytes and the flags [doubleSided] and [solid] in byte 2.
class GiVolume {
  GiVolume({
    required this.origin,
    required this.cell,
    required this.nx,
    required this.ny,
    required this.nz,
    required this.voxels,
    required this.probeOrigin,
    required this.spacing,
    required this.px,
    required this.py,
    required this.pz,
    required this.probes,
    required this.activeCount,
  });

  /// The flags of word 1 of a cell.
  static const doubleSided = 1, solid = 2;

  /// The corner of the grid with the smallest coordinates and the side of a
  /// cell in world units.
  final Vector3 origin;
  final double cell;
  final int nx, ny, nz;
  final Uint32List voxels;

  /// The place of the first probe before its move and the distance between
  /// two probes.
  final Vector3 probeOrigin;
  final double spacing;
  final int px, py, pz;

  /// Four floats per probe, the move from its place on the grid and 1 when
  /// it is on, else 0. Then four floats per probe that is on, its index in
  /// the first.
  final Float32List probes;

  /// The number of probes that are on.
  final int activeCount;

  int get probeCount => px * py * pz;

  /// The distance byte of cell [x], [y], [z].
  int distanceAt(int x, int y, int z) =>
      voxels[2 * (x + nx * (y + ny * z))] >> 24;

  /// The flags of cell [x], [y], [z].
  int flagsAt(int x, int y, int z) =>
      (voxels[2 * (x + nx * (y + ny * z)) + 1] >> 16) & 0xff;
}

/// Reads the glTF files at [paths] in an isolate and builds their
/// [GiVolume] with [buildGiVolume].
Future<GiVolume> loadGiVolume(
  List<String> paths, {
  Vector3? probeMin,
  Vector3? probeMax,
  int maxCells = 2000000,
  int maxProbes = 4096,
}) => Isolate.run(
  () => buildGiVolume(
    [for (final p in paths) GltfDocument.open(p)],
    probeMin: probeMin,
    probeMax: probeMax,
    maxCells: maxCells,
    maxProbes: maxProbes,
  ),
);

/// Builds the voxel copy of the scenes of [docs] with about [maxCells]
/// cells and a grid of at most [maxProbes] probes over [probeMin] to
/// [probeMax], by default the bounds of the scenes. Blended materials are
/// left out.
GiVolume buildGiVolume(
  List<GltfDocument> docs, {
  Vector3? probeMin,
  Vector3? probeMax,
  int maxCells = 2000000,
  int maxProbes = 4096,
}) {
  final grid = voxelize(docs, maxCells);
  final lo = probeMin ?? grid.sceneMin, hi = probeMax ?? grid.sceneMax;
  final size = hi - lo;
  final volume =
      math.max(size.x, 1e-3) * math.max(size.y, 1e-3) * math.max(size.z, 1e-3);
  var spacing = math.pow(volume / maxProbes, 1 / 3).toDouble();
  int count(double s) => math.max(2, (s / spacing).floor() + 1);
  while (count(size.x) * count(size.y) * count(size.z) > maxProbes) {
    spacing *= 1.02;
  }
  final px = count(size.x), py = count(size.y), pz = count(size.z);
  final probeOrigin = Vector3(
    lo.x + (size.x - (px - 1) * spacing) / 2,
    lo.y + (size.y - (py - 1) * spacing) / 2,
    lo.z + (size.z - (pz - 1) * spacing) / 2,
  );
  final n = px * py * pz;
  final moves = Float32List(n * 4);
  final active = <int>[];
  final at = Vector3.zero();
  for (var i = 0; i < n; i++) {
    final x = i % px, y = (i ~/ px) % py, z = i ~/ (px * py);
    var best = 0, bx = 0.0, by = 0.0, bz = 0.0;
    // Candidate 0 is the place on the grid, then the 26 around it. A probe
    // two cells or more from a surface stays in its place.
    for (var k = 0; k < 27; k++) {
      final c = k == 0 ? 13 : (k <= 13 ? k - 1 : k);
      final ox = ((c % 3) - 1) * 0.3 * spacing;
      final oy = ((c ~/ 3) % 3 - 1) * 0.3 * spacing;
      final oz = (c ~/ 9 - 1) * 0.3 * spacing;
      at.setValues(
        probeOrigin.x + x * spacing + ox,
        probeOrigin.y + y * spacing + oy,
        probeOrigin.z + z * spacing + oz,
      );
      final d = grid.clearance(at);
      if (d > best) {
        best = d;
        bx = ox;
        by = oy;
        bz = oz;
      }
      if (k == 0 && d >= 2) break;
    }
    if (best > 0) {
      moves
        ..[i * 4] = bx
        ..[i * 4 + 1] = by
        ..[i * 4 + 2] = bz
        ..[i * 4 + 3] = 1;
      active.add(i);
    }
  }
  final probes = Float32List(n * 4 + active.length * 4)..setAll(0, moves);
  for (var j = 0; j < active.length; j++) {
    probes[n * 4 + j * 4] = active[j].toDouble();
  }
  return GiVolume(
    origin: grid.origin,
    cell: grid.cell,
    nx: grid.nx,
    ny: grid.ny,
    nz: grid.nz,
    voxels: grid.pack(),
    probeOrigin: probeOrigin,
    spacing: spacing,
    px: px,
    py: py,
    pz: pz,
    probes: probes,
    activeCount: active.length,
  );
}
