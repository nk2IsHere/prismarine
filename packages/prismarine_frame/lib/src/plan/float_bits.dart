import 'dart:typed_data';

/// Whether [a] and [b] hold the same float32 bits (−0 is not 0, a NaN is
/// itself), allocating nothing: both are copied into scratch lists of one
/// class and compared as integers. Reading a [Float32List] whose class the
/// compiler can't tell (a list or a view) is a dispatched call that boxes
/// each double in AOT, and views of the bits are objects of their own.
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

/// [w]'s floats in a scratch list of one class (valid until the next
/// call), for reading many of them without a boxed double each.
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
