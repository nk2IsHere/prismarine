import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

import 'gi_volume.dart';

/// The cells of the voxel copy while it is built: the sums of the samples
/// of each cell, then the distances and the solid cells.
class VoxelGrid {
  VoxelGrid(this.origin, this.cell, this.nx, this.ny, this.nz)
    : _sums = Float32List(nx * ny * nz * _fields),
      distance = Uint8List(nx * ny * nz);

  final Vector3 origin;
  final double cell;
  final int nx, ny, nz;

  /// The bounds of the scenes, inside the grid.
  final sceneMin = Vector3.zero(), sceneMax = Vector3.zero();

  // Per cell the weight, the weighted red, green and blue, the weighted
  // normal and the weight of double-sided samples.
  static const _fields = 8;
  final Float32List _sums;

  /// The Chebyshev distance of each cell to the next marked or solid cell
  /// in cells, up to 255.
  final Uint8List distance;

  /// The cells inside closed parts, such as walls.
  late final solid = Uint8List(nx * ny * nz);

  int get count => nx * ny * nz;

  bool marked(int i) => _sums[i * _fields] > 0;

  void add(
    double x,
    double y,
    double z,
    double w,
    double r,
    double g,
    double b,
    Vector3 n,
    bool twoSided,
  ) {
    final cx = ((x - origin.x) / cell).floor();
    final cy = ((y - origin.y) / cell).floor();
    final cz = ((z - origin.z) / cell).floor();
    if (cx < 0 || cy < 0 || cz < 0 || cx >= nx || cy >= ny || cz >= nz) {
      return;
    }
    final at = (cx + nx * (cy + ny * cz)) * _fields;
    final s = _sums;
    s[at] += w;
    s[at + 1] += w * r;
    s[at + 2] += w * g;
    s[at + 3] += w * b;
    s[at + 4] += w * n.x;
    s[at + 5] += w * n.y;
    s[at + 6] += w * n.z;
    if (twoSided) s[at + 7] += w;
  }

  /// The distance in cells from the point [p] to the next marked or solid
  /// cell, 255 outside the grid.
  int clearance(Vector3 p) {
    final cx = ((p.x - origin.x) / cell).floor();
    final cy = ((p.y - origin.y) / cell).floor();
    final cz = ((p.z - origin.z) / cell).floor();
    if (cx < 0 || cy < 0 || cz < 0 || cx >= nx || cy >= ny || cz >= nz) {
      return 255;
    }
    return distance[cx + nx * (cy + ny * cz)];
  }

  /// The share of [rays] rays from [p] in a spherical Fibonacci pattern
  /// that hit the back of a surface or a solid cell, as from a point inside
  /// a part of the scene.
  double backShare(Vector3 p, int rays) {
    var back = 0;
    final sx = (p.x - origin.x) / cell, sy = (p.y - origin.y) / cell;
    final sz = (p.z - origin.z) / cell;
    for (var r = 0; r < rays; r++) {
      final phi = 2 * math.pi * ((r * 0.6180339887) % 1);
      final dy = 1 - (2 * r + 1) / rays;
      final rr = math.sqrt(math.max(1 - dy * dy, 0));
      final dx = rr * math.cos(phi), dz = rr * math.sin(phi);
      var t = 0.0;
      for (var step = 0; step < 512; step++) {
        final px = sx + dx * t, py = sy + dy * t, pz = sz + dz * t;
        final cx = px.floor(), cy = py.floor(), cz = pz.floor();
        if (cx < 0 || cy < 0 || cz < 0 || cx >= nx || cy >= ny || cz >= nz) {
          break;
        }
        final i = cx + nx * (cy + ny * cz);
        final d = distance[i];
        if (d == 0) {
          if (solid[i] != 0) {
            back++;
          } else {
            final at = i * _fields;
            final w = _sums[at];
            final facing =
                _sums[at + 4] * dx + _sums[at + 5] * dy + _sums[at + 6] * dz;
            if (_sums[at + 7] <= 0.5 * w && facing > 0) back++;
          }
          break;
        }
        if (d > 1) {
          t += d - 1;
        } else {
          double next(double pos, int c, double dir) => dir > 0
              ? (c + 1 - pos) / dir
              : dir < 0
              ? (c - pos) / dir
              : double.infinity;
          t +=
              math.max(
                math.min(
                  next(px, cx, dx),
                  math.min(next(py, cy, dy), next(pz, cz, dz)),
                ),
                0,
              ) +
              1e-3;
        }
      }
    }
    return back / rays;
  }

  /// Sets [distance] from the marked and solid cells with two passes of a
  /// 3 by 3 by 3 mask, which give the Chebyshev distance exactly.
  void measure() {
    final d = distance;
    for (var i = 0; i < count; i++) {
      d[i] = marked(i) || solid[i] != 0 ? 0 : 255;
    }
    for (final dir in const [1, -1]) {
      final z0 = dir > 0 ? 0 : nz - 1, y0 = dir > 0 ? 0 : ny - 1;
      final x0 = dir > 0 ? 0 : nx - 1;
      for (var z = z0; z >= 0 && z < nz; z += dir) {
        for (var y = y0; y >= 0 && y < ny; y += dir) {
          for (var x = x0; x >= 0 && x < nx; x += dir) {
            final i = x + nx * (y + ny * z);
            var m = d[i];
            if (m == 0) continue;
            // The 13 neighbours that come earlier in this scan.
            for (var k = 0; k < 13; k++) {
              final ox = (k % 3 - 1) * dir;
              final oy = ((k ~/ 3) % 3 - 1) * dir;
              final oz = (k ~/ 9 - 1) * dir;
              final qx = x + ox, qy = y + oy, qz = z + oz;
              if (qx < 0 || qy < 0 || qz < 0 || qx >= nx || qy >= ny) {
                continue;
              }
              if (qz >= nz) continue;
              final v = d[qx + nx * (qy + ny * qz)] + 1;
              if (v < m) m = v;
            }
            d[i] = m;
          }
        }
      }
    }
  }

  /// Marks the empty cells that a flood from the faces of the grid does not
  /// reach as solid, unless a cell of their part is at least [room] cells
  /// from a surface, as in a closed room.
  void fillSolid(int room) {
    final state = Uint8List(count);
    final queue = Int32List(count);
    var head = 0, tail = 0;
    void push(int i) {
      if (state[i] != 0 || marked(i)) return;
      state[i] = 1;
      queue[tail++] = i;
    }

    for (var z = 0; z < nz; z++) {
      for (var y = 0; y < ny; y++) {
        for (var x = 0; x < nx; x++) {
          final face = x == 0 || y == 0 || z == 0 || x == nx - 1;
          if (face || y == ny - 1 || z == nz - 1) push(x + nx * (y + ny * z));
        }
      }
    }
    void flood() {
      while (head < tail) {
        final i = queue[head++];
        final x = i % nx, y = (i ~/ nx) % ny, z = i ~/ (nx * ny);
        if (x > 0) push(i - 1);
        if (x < nx - 1) push(i + 1);
        if (y > 0) push(i - nx);
        if (y < ny - 1) push(i + nx);
        if (z > 0) push(i - nx * ny);
        if (z < nz - 1) push(i + nx * ny);
      }
    }

    flood();
    for (var i = 0; i < count; i++) {
      if (state[i] != 0 || marked(i)) continue;
      // One part of the cells that the flood did not reach.
      final start = tail;
      push(i);
      flood();
      var far = 0;
      for (var j = start; j < tail; j++) {
        far = math.max(far, distance[queue[j]]);
      }
      if (far >= room) continue;
      for (var j = start; j < tail; j++) {
        solid[queue[j]] = 1;
      }
    }
  }

  /// Returns the two words of each cell, as [GiVolume.voxels] has them.
  Uint32List pack() {
    final out = Uint32List(count * 2);
    final s = _sums;
    for (var i = 0; i < count; i++) {
      final w = s[i * _fields];
      var word0 = distance[i] << 24, word1 = 0;
      if (solid[i] != 0) {
        word1 = GiVolume.solid << 16;
      } else if (w > 0) {
        int c(double v) => (math.sqrt(v.clamp(0, 1)) * 255).round();
        word0 |=
            c(s[i * _fields + 1] / w) |
            c(s[i * _fields + 2] / w) << 8 |
            c(s[i * _fields + 3] / w) << 16;
        final x = s[i * _fields + 4], y = s[i * _fields + 5];
        final z = s[i * _fields + 6];
        final len = math.sqrt(x * x + y * y + z * z);
        final (ox, oy) = _octahedral(x, y, z, len);
        var flags = 0;
        // Opposed normals in one cell, as on both faces of a thin part.
        if (s[i * _fields + 7] > 0.5 * w || len < 0.5 * w) {
          flags |= GiVolume.doubleSided;
        }
        word1 = (ox & 0xff) | (oy & 0xff) << 8 | flags << 16;
      }
      out[i * 2] = word0;
      out[i * 2 + 1] = word1;
    }
    return out;
  }

  static (int, int) _octahedral(double x, double y, double z, double len) {
    if (len <= 0) return (0, 127);
    final l1 = x.abs() + y.abs() + z.abs();
    var u = x / l1, v = z / l1;
    if (y < 0) {
      final pu = (1 - v.abs()) * (u >= 0 ? 1 : -1);
      final pv = (1 - u.abs()) * (v >= 0 ? 1 : -1);
      u = pu;
      v = pv;
    }
    return ((u * 127).round(), (v * 127).round());
  }
}

/// The base colour texture of a material at a small mip level, in linear
/// light.
class _Texture {
  _Texture(this.width, this.height, this.rgba);
  final int width, height;
  final Float32List rgba;

  static _Texture? read(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final k = readKtx2(file.readAsBytesSync());
    if (k.format != Ktx2Format.rgba8 && k.format != Ktx2Format.rgba8Srgb) {
      return null;
    }
    var level = 0, w = k.width, h = k.height;
    while (level + 1 < k.levels.length && math.max(w, h) > 64) {
      level++;
      w = math.max(1, w >> 1);
      h = math.max(1, h >> 1);
    }
    final bytes = k.levels[level];
    final out = Float32List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      for (var c = 0; c < 3; c++) {
        out[i * 4 + c] = _linear[bytes[i * 4 + c]];
      }
      out[i * 4 + 3] = bytes[i * 4 + 3] / 255;
    }
    return _Texture(w, h, out);
  }

  /// The texel at [u], [v] with wrapping, its first channel at the index
  /// that it returns.
  int at(double u, double v) {
    var x = (u * width).floor() % width;
    var y = (v * height).floor() % height;
    if (x < 0) x += width;
    if (y < 0) y += height;
    return (x + y * width) * 4;
  }

  static final _linear = Float32List.fromList([
    for (var i = 0; i < 256; i++)
      i / 255 <= 0.04045
          ? i / 255 / 12.92
          : math.pow((i / 255 + 0.055) / 1.055, 2.4).toDouble(),
  ]);
}

/// Marks the cells of a grid of about [maxCells] cells around the draws of
/// [docs] with their base colours and normals. Then measures the distances
/// and fills the closed parts.
VoxelGrid voxelize(List<GltfDocument> docs, int maxCells) {
  final lo = Vector3.all(double.infinity), hi = Vector3.all(-double.infinity);
  final models = [for (final d in docs) GltfModel.read(d)];
  for (final m in models) {
    Vector3.min(lo, m.min, lo);
    Vector3.max(hi, m.max, hi);
  }
  final size = hi - lo;
  final volume =
      math.max(size.x, 1e-3) * math.max(size.y, 1e-3) * math.max(size.z, 1e-3);
  final cell = math.pow(volume / maxCells, 1 / 3).toDouble();
  // One empty cell on each side lets the flood reach around the scene.
  int cells(double s) => (s / cell).ceil() + 2;
  final grid = VoxelGrid(
    lo - Vector3.all(cell),
    cell,
    cells(size.x),
    cells(size.y),
    cells(size.z),
  );
  grid.sceneMin.setFrom(lo);
  grid.sceneMax.setFrom(hi);
  for (final (i, doc) in docs.indexed) {
    _addDocument(grid, doc, models[i]);
  }
  grid.measure();
  // A closed part with a cell 0.75 m or more from its surfaces is a room.
  grid.fillSolid((0.75 / cell).ceil());
  grid.measure();
  return grid;
}

void _addDocument(VoxelGrid grid, GltfDocument doc, GltfModel model) {
  final images = doc.list('images');
  final textures = <int, _Texture?>{};
  _Texture? texture(int? image) {
    if (image == null || image >= images.length) return null;
    return textures.putIfAbsent(image, () {
      final uri = images[image]['uri'];
      if (uri is! String || !uri.endsWith('.ktx2')) return null;
      return _Texture.read('${doc.dir}/${Uri.decodeComponent(uri)}');
    });
  }

  final floats = <int, Float32List>{};
  final indices = <int, Uint32List>{};
  final meshes = doc.list('meshes');
  final a = Vector3.zero(), b = Vector3.zero(), c = Vector3.zero();
  final e1 = Vector3.zero(), e2 = Vector3.zero(), n = Vector3.zero();
  for (final root in importSceneNodes(doc)) {
    root.walk((node) {
      final mesh = node.mesh;
      if (mesh == null) return;
      final world = node.world;
      for (final prim
          in (meshes[mesh]['primitives'] as List)
              .cast<Map<String, Object?>>()) {
        if (((prim['mode'] as int?) ?? 4) != 4) continue;
        final attrs = (prim['attributes'] as Map).cast<String, int>();
        final posAt = attrs['POSITION'];
        if (posAt == null) continue;
        final material = prim['material'] as int?;
        final m = material == null || material >= model.materials.length
            ? ModelMaterial.fallback()
            : model.materials[material];
        if (m.alphaMode == AlphaMode.blend) continue;
        final pos = floats[posAt] ??= doc.floats(posAt);
        final uvAt = attrs['TEXCOORD_0'];
        final uv = uvAt == null ? null : floats[uvAt] ??= doc.floats(uvAt);
        final idxAt = prim['indices'] as int?;
        final idx = idxAt == null
            ? Uint32List.fromList([for (var i = 0; i < pos.length ~/ 3; i++) i])
            : indices[idxAt] ??= doc.uints(idxAt);
        final tex = texture(m.baseColor);
        final f = m.baseColorFactor;
        final masked = m.alphaMode == AlphaMode.mask;
        for (var t = 0; t + 2 < idx.length; t += 3) {
          final i0 = idx[t], i1 = idx[t + 1], i2 = idx[t + 2];
          a.setValues(pos[i0 * 3], pos[i0 * 3 + 1], pos[i0 * 3 + 2]);
          b.setValues(pos[i1 * 3], pos[i1 * 3 + 1], pos[i1 * 3 + 2]);
          c.setValues(pos[i2 * 3], pos[i2 * 3 + 1], pos[i2 * 3 + 2]);
          world
            ..transform3(a)
            ..transform3(b)
            ..transform3(c);
          e1
            ..setFrom(b)
            ..sub(a);
          e2
            ..setFrom(c)
            ..sub(a);
          e1.crossInto(e2, n);
          final area = n.length * 0.5;
          if (area <= 0) continue;
          n.scale(0.5 / area);
          final edge = math.max(
            e1.length,
            math.max(e2.length, b.distanceTo(c)),
          );
          final steps = math.max(1, (edge / (grid.cell * 0.5)).ceil());
          final samples = (steps + 1) * (steps + 2) ~/ 2;
          final w = steps == 1 ? area : area / samples;
          for (var si = 0; si <= steps; si++) {
            for (var sj = 0; sj + si <= steps; sj++) {
              // The centre of the triangle for a triangle of one step.
              final s = steps == 1 ? 1 / 3 : si / steps;
              final r = steps == 1 ? 1 / 3 : sj / steps;
              var red = f[0], green = f[1], blue = f[2];
              if (tex != null && uv != null) {
                final u =
                    uv[i0 * 2] +
                    (uv[i1 * 2] - uv[i0 * 2]) * s +
                    (uv[i2 * 2] - uv[i0 * 2]) * r;
                final v =
                    uv[i0 * 2 + 1] +
                    (uv[i1 * 2 + 1] - uv[i0 * 2 + 1]) * s +
                    (uv[i2 * 2 + 1] - uv[i0 * 2 + 1]) * r;
                final at = tex.at(u, v);
                final px = tex.rgba;
                if (masked && px[at + 3] * f[3] < m.alphaCutoff) continue;
                red *= px[at];
                green *= px[at + 1];
                blue *= px[at + 2];
              }
              grid.add(
                a.x + e1.x * s + e2.x * r,
                a.y + e1.y * s + e2.y * r,
                a.z + e1.z * s + e2.z * r,
                w,
                red,
                green,
                blue,
                n,
                m.doubleSided,
              );
              if (steps == 1) break;
            }
            if (steps == 1) break;
          }
        }
      }
    });
  }
}
