import 'dart:typed_data';

/// Returns the column-major matrix of the translation [t] and the unit
/// quaternion [q] in x, y, z, w order.
Float64List mat4Compose(List<double> t, List<double> q) {
  final x = q[0], y = q[1], z = q[2], w = q[3];
  return Float64List.fromList([
    1 - 2 * (y * y + z * z),
    2 * (x * y + z * w),
    2 * (x * z - y * w),
    0,
    2 * (x * y - z * w),
    1 - 2 * (x * x + z * z),
    2 * (y * z + x * w),
    0,
    2 * (x * z + y * w),
    2 * (y * z - x * w),
    1 - 2 * (x * x + y * y),
    0,
    t[0],
    t[1],
    t[2],
    1,
  ]);
}

/// Returns the product [a] times [b] of two column-major matrices.
Float64List mat4Mul(Float64List a, Float64List b) {
  final o = Float64List(16);
  for (var c = 0; c < 4; c++) {
    for (var r = 0; r < 4; r++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[k * 4 + r] * b[c * 4 + k];
      }
      o[c * 4 + r] = s;
    }
  }
  return o;
}

/// Returns the inverse of an affine matrix [m] of rotation, scale and
/// translation.
Float64List mat4InvertAffine(Float64List m) {
  final a = m[0],
      b = m[4],
      c = m[8],
      d = m[1],
      e = m[5],
      f = m[9],
      g = m[2],
      h = m[6],
      i = m[10];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final inv = [
    (e * i - f * h) / det,
    -(b * i - c * h) / det,
    (b * f - c * e) / det,
    -(d * i - f * g) / det,
    (a * i - c * g) / det,
    -(a * f - c * d) / det,
    (d * h - e * g) / det,
    -(a * h - b * g) / det,
    (a * e - b * d) / det,
  ];
  final tx = m[12], ty = m[13], tz = m[14];
  return Float64List.fromList([
    inv[0],
    inv[3],
    inv[6],
    0,
    inv[1],
    inv[4],
    inv[7],
    0,
    inv[2],
    inv[5],
    inv[8],
    0,
    -(inv[0] * tx + inv[1] * ty + inv[2] * tz),
    -(inv[3] * tx + inv[4] * ty + inv[5] * tz),
    -(inv[6] * tx + inv[7] * ty + inv[8] * tz),
    1,
  ]);
}
