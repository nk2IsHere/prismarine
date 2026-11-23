part of '../../libm.dart';

// --------------------------------------------------------------------- exp

const _half = [0.5, -0.5];
const _ln2hi = 6.93147180369123816490e-01;
const _ln2lo = 1.90821492927058770002e-10;
const _invln2 = 1.44269504088896338700e+00;
const _p1 = 1.66666666666666019037e-01;
const _p2 = -2.77777777770155933842e-03;
const _p3 = 6.61375632143793436117e-05;
const _p4 = -1.65339022054652515390e-06;
const _p5 = 4.13813679705723846039e-08;

double exp(double x) {
  final x1p1023 = _pow2(2046);
  double hi, lo;
  int k;
  var hx = _hi(x);
  final sign = hx >> 31;
  hx &= 0x7fffffff;
  if (hx >= 0x4086232b) {
    if (x.isNaN) return x;
    if (x > 709.782712893383973096) {
      x *= x1p1023;
      return x;
    }
    if (x < -708.39641853226410622) {
      if (x < -745.13321910194110842) return 0.0;
    }
  }
  if (hx > 0x3fd62e42) {
    if (hx >= 0x3ff0a2b2) {
      k = (_invln2 * x + _half[sign]).toInt();
    } else {
      k = 1 - sign - sign;
    }
    hi = x - k.toDouble() * _ln2hi;
    lo = k.toDouble() * _ln2lo;
    x = hi - lo;
  } else if (hx > 0x3e300000) {
    k = 0;
    hi = x;
    lo = 0.0;
  } else {
    return 1.0 + x;
  }
  final xx = x * x;
  final c = x - xx * (_p1 + xx * (_p2 + xx * (_p3 + xx * (_p4 + xx * _p5))));
  final y = 1.0 + (x * c / (2.0 - c) - lo + hi);
  return k == 0 ? y : scalbn(y, k);
}

// --------------------------------------------------------------------- log

const _lg1 = 6.666666666666735130e-01;
const _lg2 = 3.999999999940941908e-01;
const _lg3 = 2.857142874366239149e-01;
const _lg4 = 2.222219843214978396e-01;
const _lg5 = 1.818357216161805012e-01;
const _lg6 = 1.531383769920937332e-01;
const _lg7 = 1.479819860511658591e-01;

/// Returns the natural logarithm of [x].
double log(double x) {
  final x1p54 = _pow2(1023 + 54);
  var hx = _hi(x);
  var lo = _lo(x);
  var k = 0;
  if (hx < 0x00100000 || (hx >> 31) != 0) {
    if (((hx & 0x7fffffff) | lo) == 0) return -1.0 / (x * x);
    if (hx >> 31 != 0) return (x - x) / 0.0;
    k -= 54;
    x *= x1p54;
    hx = _hi(x);
    lo = _lo(x);
  } else if (hx >= 0x7ff00000) {
    return x;
  } else if (hx == 0x3ff00000 && lo == 0) {
    return 0.0;
  }
  hx = _u32(hx + (0x3ff00000 - 0x3fe6a09e));
  k += (hx >> 20) - 0x3ff;
  hx = (hx & 0x000fffff) + 0x3fe6a09e;
  x = _fromWords(hx, lo);
  final f = x - 1.0;
  final hfsq = 0.5 * f * f;
  final s = f / (2.0 + f);
  final z = s * s;
  final w = z * z;
  final t1 = w * (_lg2 + w * (_lg4 + w * _lg6));
  final t2 = z * (_lg1 + w * (_lg3 + w * (_lg5 + w * _lg7)));
  final r = t2 + t1;
  final dk = k.toDouble();
  return s * (hfsq + r) + dk * _ln2lo - hfsq + f + dk * _ln2hi;
}
