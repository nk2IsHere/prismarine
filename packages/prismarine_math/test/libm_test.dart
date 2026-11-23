// Checks lib/libm.dart against the Rust libm crate 0.2.16. The checksums are
// those of the same sweeps over the Rust crate.
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'package:test/test.dart';

/// The checksum of the sweep over sin, cos, exp, log, pow, dpow and atan2.
const libmSweep = 0x06f90047c6d9745b;

/// The checksum of the sweep over tan, asin, acos and atan.
const simSweep = 0xaa1dd63e80aaa7f4;

final _b = ByteData(8);

int _bitsOf(double v) {
  // Every NaN counts as one (x86 and ARM make different default NaNs).
  if (v.isNaN) return 0x7ff8000000000000;
  _b.setFloat64(0, v, Endian.little);
  return _b.getInt64(0, Endian.little);
}

int _h = 0;
void _fnv(double v) {
  final b = _bitsOf(v);
  for (var i = 0; i < 8; i++) {
    _h ^= (b >>> (8 * i)) & 0xff;
    _h *= 0x100000001b3;
  }
}

/// xorshift64*, the generator of the sweeps over the Rust crate.
class _Rng {
  int s;
  _Rng(this.s);
  int next() {
    s ^= s >>> 12;
    s ^= s << 25;
    s ^= s >>> 27;
    return s * 0x2545F4914F6CDD1D;
  }

  double any() {
    _b.setInt64(0, next(), Endian.little);
    return _b.getFloat64(0, Endian.little);
  }

  double range(double lo, double hi) =>
      lo + (hi - lo) * ((next() >>> 11).toDouble() / (1 << 53).toDouble());
}

int sweep() {
  final r = _Rng(0x9E3779B97F4A7C15);
  _h = 0xcbf29ce484222325;
  const n = 100000;
  for (var i = 0; i < n; i++) {
    final x = r.any();
    _fnv(libm.sin(x));
    _fnv(libm.cos(x));
    _fnv(libm.exp(x));
    _fnv(libm.log(x));
    final y = r.any();
    _fnv(libm.pow(x, y));
    _fnv(libm.atan2(x, y));
  }
  for (var i = 0; i < n; i++) {
    final a = r.range(-10, 10);
    final w = r.range(-1e6, 1e6);
    _fnv(libm.sin(a));
    _fnv(libm.cos(a));
    _fnv(libm.sin(w));
    _fnv(libm.cos(w));
    _fnv(libm.exp(a * 70.0));
    _fnv(libm.log(a.abs()));
    _fnv(libm.log(w.abs()));
    final b = r.range(0, 100);
    final e = r.range(-40, 40);
    _fnv(libm.dpow(b, e));
    _fnv(libm.dpow(10, e));
    _fnv(libm.dpow(-b, e.roundToDouble()));
    _fnv(libm.atan2(a, r.range(-10, 10)));
  }
  return _h;
}

int simSweepOf() {
  final r = _Rng(0xD1B54A32D192ED03);
  _h = 0xcbf29ce484222325;
  for (var i = 0; i < 100000; i++) {
    final x = r.any();
    _fnv(libm.tan(x));
    _fnv(libm.asin(x));
    _fnv(libm.acos(x));
    _fnv(libm.atan(x));
    final a = r.range(-10, 10);
    final w = r.range(-1e6, 1e6);
    final u = r.range(-1.1, 1.1);
    _fnv(libm.tan(a));
    _fnv(libm.tan(w));
    _fnv(libm.asin(u));
    _fnv(libm.acos(u));
    _fnv(libm.atan(a));
    _fnv(libm.atan(w));
  }
  return _h;
}

void main() {
  test('tan, asin, acos and atan match the Rust libm crate', () {
    final h = simSweepOf();
    expect(h, simSweep, reason: h.toUnsigned(64).toRadixString(16));
  });
  test('libm.dart matches the Rust libm crate bit for bit', () {
    final h = sweep();
    expect(h, libmSweep, reason: h.toUnsigned(64).toRadixString(16));
  });
}
