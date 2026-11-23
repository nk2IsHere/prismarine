import 'dart:math' as math;
import 'dart:typed_data';

/// The bytes of one vertex in a prepared glTF: position, normal, tangent and
/// the first UV set, as 12 floats.
const preparedStride = 48;

/// Returns a normal per vertex, the sum of the normals of the triangles in
/// [indices] that use it, weighted by their area.
Float32List vertexNormals(Float32List positions, Uint32List indices) {
  final n = Float32List(positions.length);
  for (var t = 0; t + 2 < indices.length; t += 3) {
    final a = indices[t] * 3, b = indices[t + 1] * 3, c = indices[t + 2] * 3;
    final ux = positions[b] - positions[a],
        uy = positions[b + 1] - positions[a + 1],
        uz = positions[b + 2] - positions[a + 2];
    final vx = positions[c] - positions[a],
        vy = positions[c + 1] - positions[a + 1],
        vz = positions[c + 2] - positions[a + 2];
    final nx = uy * vz - uz * vy,
        ny = uz * vx - ux * vz,
        nz = ux * vy - uy * vx;
    for (final v in [a, b, c]) {
      n[v] += nx;
      n[v + 1] += ny;
      n[v + 2] += nz;
    }
  }
  _normalize3(n);
  return n;
}

/// Returns a tangent per vertex with its handedness in w, from the UV
/// gradients of the triangles in [indices] and orthogonal to [normals]. A
/// vertex without usable UVs gets any tangent orthogonal to its normal.
Float32List vertexTangents(
  Float32List positions,
  Float32List normals,
  Float32List uvs,
  Uint32List indices,
) {
  final count = positions.length ~/ 3;
  final t = Float64List(count * 3), b = Float64List(count * 3);
  for (var i = 0; i + 2 < indices.length; i += 3) {
    final i0 = indices[i], i1 = indices[i + 1], i2 = indices[i + 2];
    final e1x = positions[i1 * 3] - positions[i0 * 3],
        e1y = positions[i1 * 3 + 1] - positions[i0 * 3 + 1],
        e1z = positions[i1 * 3 + 2] - positions[i0 * 3 + 2];
    final e2x = positions[i2 * 3] - positions[i0 * 3],
        e2y = positions[i2 * 3 + 1] - positions[i0 * 3 + 1],
        e2z = positions[i2 * 3 + 2] - positions[i0 * 3 + 2];
    final du1 = uvs[i1 * 2] - uvs[i0 * 2],
        dv1 = uvs[i1 * 2 + 1] - uvs[i0 * 2 + 1];
    final du2 = uvs[i2 * 2] - uvs[i0 * 2],
        dv2 = uvs[i2 * 2 + 1] - uvs[i0 * 2 + 1];
    final det = du1 * dv2 - du2 * dv1;
    if (det.abs() < 1e-20) continue;
    final r = 1 / det;
    final tx = (e1x * dv2 - e2x * dv1) * r,
        ty = (e1y * dv2 - e2y * dv1) * r,
        tz = (e1z * dv2 - e2z * dv1) * r;
    final bx = (e2x * du1 - e1x * du2) * r,
        by = (e2y * du1 - e1y * du2) * r,
        bz = (e2z * du1 - e1z * du2) * r;
    for (final v in [i0, i1, i2]) {
      t[v * 3] += tx;
      t[v * 3 + 1] += ty;
      t[v * 3 + 2] += tz;
      b[v * 3] += bx;
      b[v * 3 + 1] += by;
      b[v * 3 + 2] += bz;
    }
  }
  final out = Float32List(count * 4);
  for (var v = 0; v < count; v++) {
    final nx = normals[v * 3], ny = normals[v * 3 + 1], nz = normals[v * 3 + 2];
    var tx = t[v * 3], ty = t[v * 3 + 1], tz = t[v * 3 + 2];
    // Gram-Schmidt against the normal.
    final d = nx * tx + ny * ty + nz * tz;
    tx -= nx * d;
    ty -= ny * d;
    tz -= nz * d;
    var len = math.sqrt(tx * tx + ty * ty + tz * tz);
    if (len < 1e-12) {
      // Any direction orthogonal to the normal.
      if (nx.abs() < 0.9) {
        tx = 0;
        ty = -nz;
        tz = ny;
      } else {
        tx = nz;
        ty = 0;
        tz = -nx;
      }
      len = math.sqrt(tx * tx + ty * ty + tz * tz);
    }
    out[v * 4] = tx / len;
    out[v * 4 + 1] = ty / len;
    out[v * 4 + 2] = tz / len;
    // The bitangent of the UVs against cross(n, t) gives the handedness.
    final cx = ny * tz - nz * ty,
        cy = nz * tx - nx * tz,
        cz = nx * ty - ny * tx;
    final w = cx * b[v * 3] + cy * b[v * 3 + 1] + cz * b[v * 3 + 2];
    out[v * 4 + 3] = w < 0 ? -1 : 1;
  }
  return out;
}

void _normalize3(Float32List n) {
  for (var v = 0; v + 2 < n.length; v += 3) {
    final len = math.sqrt(
      n[v] * n[v] + n[v + 1] * n[v + 1] + n[v + 2] * n[v + 2],
    );
    if (len > 1e-20) {
      n[v] /= len;
      n[v + 1] /= len;
      n[v + 2] /= len;
    } else {
      n[v + 2] = 1;
    }
  }
}

/// A part of a primitive with at most 65,535 vertices: the vertices of the
/// primitive that it uses, in order, and its triangles with 16-bit indices
/// into them.
class GeometryChunk {
  GeometryChunk(this.vertices, this.indices);
  final Uint32List vertices;
  final Uint16List indices;
}

/// Splits the triangles in [indices] over [vertexCount] vertices into chunks
/// of at most [maxVertices] vertices each, in the order of the triangles.
List<GeometryChunk> splitChunks(
  Uint32List indices,
  int vertexCount, {
  int maxVertices = 65535,
}) {
  final chunks = <GeometryChunk>[];
  final local = Int32List(vertexCount)..fillRange(0, vertexCount, -1);
  final stamp = Int32List(vertexCount)..fillRange(0, vertexCount, -1);
  var used = <int>[];
  var tris = <int>[];
  var chunk = 0;
  void close() {
    if (tris.isEmpty) return;
    chunks.add(
      GeometryChunk(Uint32List.fromList(used), Uint16List.fromList(tris)),
    );
    used = <int>[];
    tris = <int>[];
    chunk++;
  }

  for (var t = 0; t + 2 < indices.length; t += 3) {
    var fresh = 0;
    for (var k = 0; k < 3; k++) {
      if (stamp[indices[t + k]] != chunk) fresh++;
    }
    if (used.length + fresh > maxVertices) close();
    for (var k = 0; k < 3; k++) {
      final v = indices[t + k];
      if (stamp[v] != chunk) {
        stamp[v] = chunk;
        local[v] = used.length;
        used.add(v);
      }
      tris.add(local[v]);
    }
  }
  close();
  return chunks;
}

/// Interleaves the vertices [chunk] uses into [preparedStride]-byte
/// vertices. Returns the bytes and the minimum and maximum position.
(Uint8List, List<double>, List<double>) interleave(
  GeometryChunk chunk,
  Float32List positions,
  Float32List normals,
  Float32List tangents,
  Float32List uvs,
) {
  final n = chunk.vertices.length;
  final out = Float32List(n * 12);
  final lo = [double.infinity, double.infinity, double.infinity];
  final hi = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < n; i++) {
    final v = chunk.vertices[i];
    final o = i * 12;
    for (var k = 0; k < 3; k++) {
      final p = positions[v * 3 + k];
      out[o + k] = p;
      if (p < lo[k]) lo[k] = p;
      if (p > hi[k]) hi[k] = p;
      out[o + 3 + k] = normals[v * 3 + k];
    }
    for (var k = 0; k < 4; k++) {
      out[o + 6 + k] = tangents[v * 4 + k];
    }
    out[o + 10] = uvs[v * 2];
    out[o + 11] = uvs[v * 2 + 1];
  }
  return (out.buffer.asUint8List(), lo, hi);
}
