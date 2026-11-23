// sin, cos and tan with their kernels.
part of '../../libm.dart';

// --------------------------------------------------------------- sin / cos

const _s1 = -1.66666666666666324348e-01;
const _s2 = 8.33333333332248946124e-03;
const _s3 = -1.98412698298579493134e-04;
const _s4 = 2.75573137070700676789e-06;
const _s5 = -2.50507602534068634195e-08;
const _s6 = 1.58969099521155010221e-10;

double _kSin(double x, double y, int iy) {
  final z = x * x;
  final w = z * z;
  final r = _s2 + z * (_s3 + z * _s4) + z * w * (_s5 + z * _s6);
  final v = z * x;
  if (iy == 0) return x + v * (_s1 + z * r);
  return x - ((z * (0.5 * y - v * r) - y) - v * _s1);
}

const _c1 = 4.16666666666666019037e-02;
const _c2 = -1.38888888888741095749e-03;
const _c3 = 2.48015872894767294178e-05;
const _c4 = -2.75573143513906633035e-07;
const _c5 = 2.08757232129817482790e-09;
const _c6 = -1.13596475577881948265e-11;

double _kCos(double x, double y) {
  final z = x * x;
  var w = z * z;
  final r =
      z * (_c1 + z * (_c2 + z * _c3)) + w * w * (_c4 + z * (_c5 + z * _c6));
  final hz = 0.5 * z;
  w = 1.0 - hz;
  return w + (((1.0 - w) - hz) + (z * r - x * y));
}

double sin(double x) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x3fe921fb) {
    if (ix < 0x3e500000) return x;
    return _kSin(x, 0.0, 0);
  }
  if (ix >= 0x7ff00000) return x - x;
  _remPio2(x);
  switch (_n & 3) {
    case 0:
      return _kSin(_y0, _y1, 1);
    case 1:
      return _kCos(_y0, _y1);
    case 2:
      return -_kSin(_y0, _y1, 1);
    default:
      return -_kCos(_y0, _y1);
  }
}

double cos(double x) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x3fe921fb) {
    if (ix < 0x3e46a09e) {
      if (x.toInt() == 0) return 1.0;
    }
    return _kCos(x, 0.0);
  }
  if (ix >= 0x7ff00000) return x - x;
  _remPio2(x);
  switch (_n & 3) {
    case 0:
      return _kCos(_y0, _y1);
    case 1:
      return -_kSin(_y0, _y1, 1);
    case 2:
      return -_kCos(_y0, _y1);
    default:
      return _kSin(_y0, _y1, 1);
  }
}
// ---------------------------------------------------------------------- tan

const _tanT = [
  3.33333333333334091986e-01,
  1.33333333333201242699e-01,
  5.39682539762260521377e-02,
  2.18694882948595424599e-02,
  8.86323982359930005737e-03,
  3.59207910759131235356e-03,
  1.45620945432529025516e-03,
  5.88041240820264096874e-04,
  2.46463134818469906812e-04,
  7.81794442939557092300e-05,
  7.14072491382608190305e-05,
  -1.85586374855275456654e-05,
  2.59073051863633712884e-05,
];
const _pio4 = 7.85398163397448278999e-01;
const _pio4Lo = 3.06161699786838301793e-17;

@pragma('vm:prefer-inline')
double _zeroLow(double x) => _withLo(x, 0);

double _kTan(double x, double y, int odd) {
  final hx = _hi(x);
  final big = (hx & 0x7fffffff) >= 0x3FE59428;
  if (big) {
    if (hx >> 31 != 0) {
      x = -x;
      y = -y;
    }
    x = (_pio4 - x) + (_pio4Lo - y);
    y = 0.0;
  }
  final z = x * x;
  var w = z * z;
  var r =
      _tanT[1] +
      w *
          (_tanT[3] +
              w * (_tanT[5] + w * (_tanT[7] + w * (_tanT[9] + w * _tanT[11]))));
  var v =
      z *
      (_tanT[2] +
          w *
              (_tanT[4] +
                  w *
                      (_tanT[6] +
                          w * (_tanT[8] + w * (_tanT[10] + w * _tanT[12])))));
  var s = z * x;
  r = y + z * (s * (r + v) + y) + s * _tanT[0];
  w = x + r;
  if (big) {
    s = 1.0 - 2.0 * odd.toDouble();
    v = s - 2.0 * (x + (r - w * w / (w + s)));
    return hx >> 31 != 0 ? -v : v;
  }
  if (odd == 0) return w;
  final w0 = _zeroLow(w);
  v = r - (w0 - x);
  final a = -1.0 / w;
  final a0 = _zeroLow(a);
  return a0 + a * (1.0 + a0 * w0 + a0 * v);
}

double tan(double x) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x3fe921fb) {
    if (ix < 0x3e400000) return x;
    return _kTan(x, 0.0, 0);
  }
  if (ix >= 0x7ff00000) return x - x;
  _remPio2(x);
  return _kTan(_y0, _y1, _n & 1);
}
