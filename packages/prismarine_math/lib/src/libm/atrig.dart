part of '../../libm.dart';

// ------------------------------------------------------------ atan / atan2

const _atanHi = [
  4.63647609000806093515e-01,
  7.85398163397448278999e-01,
  9.82793723247329054082e-01,
  1.57079632679489655800e+00,
];
const _atanLo = [
  2.26987774529616870924e-17,
  3.06161699786838301793e-17,
  1.39033110312309984516e-17,
  6.12323399573676603587e-17,
];
const _at = [
  3.33333333333329318027e-01,
  -1.99999999998764832476e-01,
  1.42857142725034663711e-01,
  -1.11111104054623557880e-01,
  9.09088713343650656196e-02,
  -7.69187620504482999495e-02,
  6.66107313738753120669e-02,
  -5.83357013379057348645e-02,
  4.97687799461593236017e-02,
  -3.65315727442169155270e-02,
  1.62858201153657823623e-02,
];

double atan(double x) {
  var ix = _hi(x);
  final sign = ix >> 31;
  ix &= 0x7fffffff;
  if (ix >= 0x44100000) {
    if (x.isNaN) return x;
    final z = _atanHi[3] + _fromWords(0x03800000, 0);
    return sign != 0 ? -z : z;
  }
  int id;
  if (ix < 0x3fdc0000) {
    if (ix < 0x3e400000) return x;
    id = -1;
  } else {
    x = x.abs();
    if (ix < 0x3ff30000) {
      if (ix < 0x3fe60000) {
        x = (2.0 * x - 1.0) / (2.0 + x);
        id = 0;
      } else {
        x = (x - 1.0) / (x + 1.0);
        id = 1;
      }
    } else if (ix < 0x40038000) {
      x = (x - 1.5) / (1.0 + 1.5 * x);
      id = 2;
    } else {
      x = -1.0 / x;
      id = 3;
    }
  }
  final z = x * x;
  final w = z * z;
  final s1 =
      z *
      (_at[0] +
          w *
              (_at[2] +
                  w * (_at[4] + w * (_at[6] + w * (_at[8] + w * _at[10])))));
  final s2 =
      w * (_at[1] + w * (_at[3] + w * (_at[5] + w * (_at[7] + w * _at[9]))));
  if (id < 0) return x - x * (s1 + s2);
  final r = _atanHi[id] - (x * (s1 + s2) - _atanLo[id] - x);
  return sign != 0 ? -r : r;
}

const _pi = 3.1415926535897931160E+00;
const _piLo = 1.2246467991473531772E-16;

double atan2(double y, double x) {
  if (x.isNaN || y.isNaN) return x + y;
  var ix = _hi(x);
  final lx = _lo(x);
  var iy = _hi(y);
  final ly = _lo(y);
  if ((_u32(ix - 0x3ff00000) | lx) == 0) return atan(y);
  final m = ((iy >> 31) & 1) | ((ix >> 30) & 2);
  ix &= 0x7fffffff;
  iy &= 0x7fffffff;
  if ((iy | ly) == 0) {
    switch (m) {
      case 0:
      case 1:
        return y;
      case 2:
        return _pi;
      default:
        return -_pi;
    }
  }
  if ((ix | lx) == 0) return m & 1 != 0 ? -_pi / 2.0 : _pi / 2.0;
  if (ix == 0x7ff00000) {
    if (iy == 0x7ff00000) {
      switch (m) {
        case 0:
          return _pi / 4.0;
        case 1:
          return -_pi / 4.0;
        case 2:
          return 3.0 * _pi / 4.0;
        default:
          return -3.0 * _pi / 4.0;
      }
    } else {
      switch (m) {
        case 0:
          return 0.0;
        case 1:
          return -0.0;
        case 2:
          return _pi;
        default:
          return -_pi;
      }
    }
  }
  if (_u32(ix + (64 << 20)) < iy || iy == 0x7ff00000) {
    return m & 1 != 0 ? -_pi / 2.0 : _pi / 2.0;
  }
  final z = (m & 2 != 0) && _u32(iy + (64 << 20)) < ix
      ? 0.0
      : atan((y / x).abs());
  switch (m) {
    case 0:
      return z;
    case 1:
      return -z;
    case 2:
      return _pi - (z - _piLo);
    default:
      return (z - _piLo) - _pi;
  }
}
// ------------------------------------------------------------- asin / acos

const _pio2Hi = 1.57079632679489655800e+00;
const _pio2Lo = 6.12323399573676603587e-17;
const _pS0 = 1.66666666666666657415e-01;
const _pS1 = -3.25565818622400915405e-01;
const _pS2 = 2.01212532134862925881e-01;
const _pS3 = -4.00555345006794114027e-02;
const _pS4 = 7.91534994289814532176e-04;
const _pS5 = 3.47933107596021167570e-05;
const _qS1 = -2.40339491173441421878e+00;
const _qS2 = 2.02094576023350569471e+00;
const _qS3 = -6.88283971605453293030e-01;
const _qS4 = 7.70381505559019352791e-02;

/// 0x1p-120.
final _x1p120neg = _fromWords(0x38700000, 0);

double _asinR(double z) {
  final p =
      z * (_pS0 + z * (_pS1 + z * (_pS2 + z * (_pS3 + z * (_pS4 + z * _pS5)))));
  final q = 1.0 + z * (_qS1 + z * (_qS2 + z * (_qS3 + z * _qS4)));
  return p / q;
}

double asin(double x) {
  final hx = _hi(x);
  final ix = hx & 0x7fffffff;
  if (ix >= 0x3ff00000) {
    if ((_u32(ix - 0x3ff00000) | _lo(x)) == 0) return x * _pio2Hi + _x1p120neg;
    return 0.0 / (x - x);
  }
  if (ix < 0x3fe00000) {
    if (ix >= 0x00100000 && ix < 0x3e500000) return x;
    return x + x * _asinR(x * x);
  }
  final z = (1.0 - x.abs()) * 0.5;
  final s = math.sqrt(z);
  final r = _asinR(z);
  if (ix >= 0x3fef3333) {
    x = _pio2Hi - (2.0 * (s + s * r) - _pio2Lo);
  } else {
    final f = _zeroLow(s);
    final c = (z - f * f) / (s + f);
    x =
        0.5 * _pio2Hi -
        (2.0 * s * r - (_pio2Lo - 2.0 * c) - (0.5 * _pio2Hi - 2.0 * f));
  }
  return hx >> 31 != 0 ? -x : x;
}

double acos(double x) {
  final hx = _hi(x);
  final ix = hx & 0x7fffffff;
  if (ix >= 0x3ff00000) {
    if ((_u32(ix - 0x3ff00000) | _lo(x)) == 0) {
      if (hx >> 31 != 0) return 2.0 * _pio2Hi + _x1p120neg;
      return 0.0;
    }
    return 0.0 / (x - x);
  }
  if (ix < 0x3fe00000) {
    if (ix <= 0x3c600000) return _pio2Hi + _x1p120neg;
    return _pio2Hi - (x - (_pio2Lo - x * _asinR(x * x)));
  }
  if (hx >> 31 != 0) {
    final z = (1.0 + x) * 0.5;
    final s = math.sqrt(z);
    final w = _asinR(z) * s - _pio2Lo;
    return 2.0 * (_pio2Hi - (s + w));
  }
  final z = (1.0 - x) * 0.5;
  final s = math.sqrt(z);
  final df = _zeroLow(s);
  final c = (z - df * df) / (s + df);
  final w = _asinR(z) * s + c;
  return 2.0 * (df + w);
}
