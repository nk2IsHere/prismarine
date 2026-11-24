import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';

/// Sorts the triangles of each primitive of [doc] along a Morton curve
/// through the centers of the triangles, in place in the buffers of [doc].
/// Runs of consecutive triangles then cover small parts of a mesh, which
/// lets a renderer cull them on their own. Returns the number of index
/// accessors sorted.
///
/// A primitive with [minTriangles] triangles or fewer keeps its order, as
/// does each primitive whose material blends, since its order changes its
/// picture. Only triangle lists with 16-bit indices are sorted.
int sortTrianglesForRuns(GltfDocument doc, {int minTriangles = 4096}) {
  final materials = doc.list('materials');
  final blended = <int>{}, candidates = <int, int>{};
  for (final mesh in doc.list('meshes')) {
    for (final prim in (mesh['primitives'] as List)) {
      final p = prim as Map<String, Object?>;
      final idx = p['indices'] as int?;
      if (idx == null) continue;
      final m = p['material'] as int?;
      if ((m != null && materials[m]['alphaMode'] == 'BLEND') ||
          ((p['mode'] as int?) ?? 4) != 4) {
        blended.add(idx);
        continue;
      }
      candidates[idx] = (p['attributes'] as Map)['POSITION'] as int;
    }
  }
  var sorted = 0;
  for (final MapEntry(key: idx, value: pos) in candidates.entries) {
    if (blended.contains(idx)) continue;
    final a = doc.accessor(idx);
    final view = a['bufferView'] as int?;
    if (a['componentType'] != 5123 || view == null || a['sparse'] != null) {
      continue;
    }
    final count = doc.count(idx);
    if (count ~/ 3 <= minTriangles) continue;
    final v = doc.list('bufferViews')[view];
    final at =
        ((v['byteOffset'] as int?) ?? 0) + ((a['byteOffset'] as int?) ?? 0);
    final bytes = ByteData.sublistView(doc.buffers[v['buffer'] as int], at);
    final indices = doc.uints(idx);
    final order = mortonOrder(indices, doc.floats(pos));
    for (var t = 0; t < order.length; t++) {
      final src = order[t] * 3;
      for (var k = 0; k < 3; k++) {
        bytes.setUint16((t * 3 + k) * 2, indices[src + k], Endian.little);
      }
    }
    sorted++;
  }
  return sorted;
}

/// Returns the triangles of [indices] into [positions], three floats per
/// vertex, in the order of the Morton codes of their centers in the box of
/// the centers. Triangles with the same code keep their order.
Uint32List mortonOrder(Uint32List indices, Float32List positions) {
  final n = indices.length ~/ 3;
  final centers = Float32List(n * 3);
  final lo = Float64List(3)..fillRange(0, 3, double.infinity);
  final hi = Float64List(3)..fillRange(0, 3, -double.infinity);
  for (var t = 0; t < n; t++) {
    for (var k = 0; k < 3; k++) {
      final c =
          (positions[indices[t * 3] * 3 + k] +
              positions[indices[t * 3 + 1] * 3 + k] +
              positions[indices[t * 3 + 2] * 3 + k]) /
          3;
      centers[t * 3 + k] = c;
      if (c < lo[k]) lo[k] = c;
      if (c > hi[k]) hi[k] = c;
    }
  }
  var keys = Uint32List(n), order = Uint32List(n);
  for (var t = 0; t < n; t++) {
    var key = 0;
    for (var k = 0; k < 3; k++) {
      final size = hi[k] - lo[k];
      final q = size > 0
          ? ((centers[t * 3 + k] - lo[k]) / size * 1023).round()
          : 0;
      key |= _spread(q) << k;
    }
    keys[t] = key;
    order[t] = t;
  }
  // A radix sort of the 30-bit codes in three passes of 10 bits.
  var keys2 = Uint32List(n), order2 = Uint32List(n);
  final counts = Int32List(1025);
  for (var shift = 0; shift < 30; shift += 10) {
    counts.fillRange(0, counts.length, 0);
    for (var t = 0; t < n; t++) {
      counts[((keys[t] >> shift) & 1023) + 1]++;
    }
    for (var b = 1; b < counts.length; b++) {
      counts[b] += counts[b - 1];
    }
    for (var t = 0; t < n; t++) {
      final to = counts[(keys[t] >> shift) & 1023]++;
      keys2[to] = keys[t];
      order2[to] = order[t];
    }
    (keys, keys2) = (keys2, keys);
    (order, order2) = (order2, order);
  }
  return order;
}

/// Spreads the 10 bits of [v] to every third bit.
int _spread(int v) {
  var x = v & 0x3ff;
  x = (x | (x << 16)) & 0x030000ff;
  x = (x | (x << 8)) & 0x0300f00f;
  x = (x | (x << 4)) & 0x030c30c3;
  x = (x | (x << 2)) & 0x09249249;
  return x;
}
