import 'dart:typed_data';

/// Returns true when [a] and [b] hold the same float32 bits, where −0 is not
/// 0 and a NaN equals itself. It allocates nothing. Both lists are copied
/// into scratch lists of one class and compared as integers.
bool sameFloat32Bits(Float32List? a, Float32List b) {
  if (a == null || a.length != b.length) return false;
  final n = a.length;
  if (n > _x.length) _grow(n);
  _x.setRange(0, n, a);
  _y.setRange(0, n, b);
  final xi = _xi, yi = _yi;
  for (var i = 0; i < n; i++) {
    if (xi[i] != yi[i]) return false;
  }
  return true;
}

/// Returns the floats of [w] in a scratch list of one class, valid until the
/// next call. Reading many of them from it boxes no double.
Float32List scratchFloats(Float32List w) {
  if (w.length > _w.length) _w = Float32List(w.length * 2);
  return _w..setRange(0, w.length, w);
}

var _x = Float32List(64), _y = Float32List(64), _w = Float32List(64);
var _xi = Int32List.view(_x.buffer), _yi = Int32List.view(_y.buffer);

void _grow(int n) {
  _x = Float32List(n * 2);
  _y = Float32List(n * 2);
  _xi = Int32List.view(_x.buffer);
  _yi = Int32List.view(_y.buffer);
}
