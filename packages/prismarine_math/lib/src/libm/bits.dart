// A double's 32-bit words and scalbn, shared by the functions below.
part of '../../libm.dart';

// A double's two 32-bit words through views of one 8-byte buffer, as the
// ByteData accessors with an explicit endianness cost a call each in AOT
// code. Every target is little-endian: word 0 is the low half; a
// big-endian host would read the words swapped, so it is refused.
final _f64 = Float64List(1);
final _w32 = () {
  if (Endian.host != Endian.little) {
    throw UnsupportedError(
      'prismarine_math libm: a little-endian host is assumed',
    );
  }
  return Uint32List.view(_f64.buffer);
}();

@pragma('vm:prefer-inline')
int _hi(double x) {
  _f64[0] = x;
  return _w32[1];
}

@pragma('vm:prefer-inline')
int _lo(double x) {
  _f64[0] = x;
  return _w32[0];
}

@pragma('vm:prefer-inline')
double _fromWords(int hi, int lo) {
  _w32[1] = hi & 0xffffffff;
  _w32[0] = lo & 0xffffffff;
  return _f64[0];
}

@pragma('vm:prefer-inline')
double _withHi(double x, int hi) => _fromWords(hi, _lo(x));
@pragma('vm:prefer-inline')
double _withLo(double x, int lo) => _fromWords(_hi(x), lo);

@pragma('vm:prefer-inline')
int _i32(int v) => v.toSigned(32);
@pragma('vm:prefer-inline')
int _u32(int v) => v.toUnsigned(32);

/// 2^e for a biased exponent e in 1..2046.
@pragma('vm:prefer-inline')
double _pow2(int biased) => _fromWords(biased << 20, 0);

// ------------------------------------------------------------------ scalbn

double scalbn(double x, int n) {
  // libm's generic scalbn for f64.
  const expMax = 1023, expMin = -1022;
  final fExpMax = _pow2(2046); // 0x1p1023
  final mul = _pow2(1) * _pow2(53 + 1023); // 0x1p-1022 * 0x1p53
  const add = -expMin - 53;
  if (n > expMax) {
    x *= fExpMax;
    n -= expMax;
    if (n > expMax) {
      x *= fExpMax;
      n -= expMax;
      if (n > expMax) n = expMax;
    }
  } else if (n < expMin) {
    x *= mul;
    n += add;
    if (n < expMin) {
      x *= mul;
      n += add;
      if (n < expMin) n = expMin;
    }
  }
  return x * _pow2(1023 + n);
}
