import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'package:vector_math/vector_math_64.dart';

/// The bytes of the `Indirect` block of the shaders in the std140 layout,
/// written in place. Offsets count floats.
class IndirectBlock {
  /// Two matrices and 17 vectors.
  static const floatCount = 32 + 17 * 4;

  final bytes = Uint8List(floatCount * 4);
  late final _f = bytes.buffer.asFloat32List();

  /// Offsets of the rows that the builder writes.
  static const inverseViewProjection = 0,
      previousViewProjection = 16,
      view = 32,
      switches = 36,
      probeOrigin = 40,
      probeCounts = 44,
      atlas = 48,
      trace = 52,
      rayRotation = 56,
      voxelOrigin = 68,
      voxelCounts = 72,
      skyParams = 76,
      probeParams = 80,
      aoParams = 84,
      ssrParams = 88,
      misc = 92,
      cameraForward = 96;

  void matrix(int at, Matrix4 m) {
    final s = m.storage;
    for (var i = 0; i < 16; i++) {
      _f[at + i] = s[i];
    }
  }

  void floats(int at, double x, double y, double z, double w) {
    _f[at] = x;
    _f[at + 1] = y;
    _f[at + 2] = z;
    _f[at + 3] = w;
  }

  /// Writes the rows of a rotation for frame [frame] at [rayRotation], by
  /// three hashed angles about z, y and x.
  void rotation(int frame) {
    final a = 2 * math.pi * _hash(frame * 3);
    final b = 2 * math.pi * _hash(frame * 3 + 1);
    final c = 2 * math.pi * _hash(frame * 3 + 2);
    final ca = libm.cos(a), sa = libm.sin(a);
    final cb = libm.cos(b), sb = libm.sin(b);
    final cc = libm.cos(c), sc = libm.sin(c);
    floats(
      rayRotation,
      ca * cb,
      ca * sb * sc - sa * cc,
      ca * sb * cc + sa * sc,
      0,
    );
    floats(
      rayRotation + 4,
      sa * cb,
      sa * sb * sc + ca * cc,
      sa * sb * cc - ca * sc,
      0,
    );
    floats(rayRotation + 8, -sb, cb * sc, cb * cc, 0);
  }

  /// A value from 0 to 1 for [i], from an integer hash.
  static double _hash(int i) {
    var h = (i * 0x9E3779B1) & 0xffffffff;
    h ^= h >> 15;
    h = (h * 0x85EBCA77) & 0xffffffff;
    h ^= h >> 13;
    h = (h * 0xC2B2AE3D) & 0xffffffff;
    h ^= h >> 16;
    return h / 4294967296.0;
  }
}
