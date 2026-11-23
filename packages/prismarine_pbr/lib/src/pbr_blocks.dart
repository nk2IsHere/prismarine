import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

/// The bytes of the `Frame` block of the shaders in the std140 layout,
/// written in place. Offsets count floats.
class FrameBlock {
  /// Two matrices, six vectors, two arrays of 16 vectors and one vector.
  static const floatCount = 32 + 24 + 128 + 4;

  final bytes = Uint8List(floatCount * 4);
  late final _f = bytes.buffer.asFloat32List();

  void matrix(int at, Matrix4 m) {
    final s = m.storage;
    for (var i = 0; i < 16; i++) {
      _f[at + i] = s[i];
    }
  }

  void vec(int at, Vector3 v, double w) => floats(at, v.x, v.y, v.z, w);

  void floats(int at, double x, double y, double z, double w) {
    _f[at] = x;
    _f[at + 1] = y;
    _f[at + 2] = z;
    _f[at + 3] = w;
  }
}

/// Returns the bytes of the `Draw` block of a draw with world matrix
/// [world] and material [m].
Uint8List drawBlock(Matrix4 world, ModelMaterial m) {
  final f = Float32List(44);
  for (var i = 0; i < 16; i++) {
    f[i] = world.storage[i];
  }
  // The inverse transpose of the upper 3 by 3 part turns normals.
  final n = Matrix3.zero()..copyNormalMatrix(world);
  for (var c = 0; c < 3; c++) {
    for (var r = 0; r < 3; r++) {
      f[16 + c * 4 + r] = n.entry(r, c);
    }
  }
  f[31] = 1;
  for (var i = 0; i < 4; i++) {
    f[32 + i] = m.baseColorFactor[i];
  }
  f
    ..[36] = m.metallic
    ..[37] = m.roughness
    ..[38] = m.alphaMode == AlphaMode.mask ? m.alphaCutoff : 0
    ..[39] = m.normalScale;
  for (var i = 0; i < 3; i++) {
    f[40 + i] = m.emissive[i];
  }
  return f.buffer.asUint8List();
}

/// Sets [out] to a perspective projection with depth from 0 at [near] to 1
/// at [far], for a camera that looks along negative z.
void perspective(
  Matrix4 out,
  double yfov,
  double aspect,
  double near,
  double far,
) {
  final f = 1 / libm.tan(yfov / 2);
  out
    ..setZero()
    ..setEntry(0, 0, f / aspect)
    ..setEntry(1, 1, f)
    ..setEntry(2, 2, far / (near - far))
    ..setEntry(2, 3, near * far / (near - far))
    ..setEntry(3, 2, -1);
}

/// Sets [out] to an orthographic projection of half width [halfWidth] and
/// half height [halfHeight] with depth from 0 at the eye to 1 at [depth].
void orthographic(
  Matrix4 out,
  double halfWidth,
  double halfHeight,
  double depth,
) {
  out
    ..setZero()
    ..setEntry(0, 0, 1 / halfWidth)
    ..setEntry(1, 1, 1 / halfHeight)
    ..setEntry(2, 2, -1 / depth)
    ..setEntry(3, 3, 1);
}

final _axis = Vector3.zero();

/// Sets [out] to the view matrix of an eye at [eye] that looks along
/// [forward] with [up] as the up direction. Neither vector needs unit
/// length. [up] must not be parallel to [forward].
void lookAlong(Matrix4 out, Vector3 eye, Vector3 forward, Vector3 up) {
  var fl = forward.length;
  final fx = forward.x / fl, fy = forward.y / fl, fz = forward.z / fl;
  // The right axis is forward times up, the true up is right times forward.
  var rx = fy * up.z - fz * up.y,
      ry = fz * up.x - fx * up.z,
      rz = fx * up.y - fy * up.x;
  fl = (_axis..setValues(rx, ry, rz)).length;
  rx /= fl;
  ry /= fl;
  rz /= fl;
  final ux = ry * fz - rz * fy, uy = rz * fx - rx * fz, uz = rx * fy - ry * fx;
  final s = out.storage;
  s[0] = rx;
  s[4] = ry;
  s[8] = rz;
  s[1] = ux;
  s[5] = uy;
  s[9] = uz;
  s[2] = -fx;
  s[6] = -fy;
  s[10] = -fz;
  s[3] = 0;
  s[7] = 0;
  s[11] = 0;
  s[12] = -(rx * eye.x + ry * eye.y + rz * eye.z);
  s[13] = -(ux * eye.x + uy * eye.y + uz * eye.z);
  s[14] = fx * eye.x + fy * eye.y + fz * eye.z;
  s[15] = 1;
}
