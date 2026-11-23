// Argument reduction by pi/2 for sin, cos and tan.
part of '../../libm.dart';

const _toInt = 1.5 / 2.2204460492503131e-16;
const _invPio2 = 6.36619772367581382433e-01;
const _pio2_1 = 1.57079632673412561417e+00;
const _pio2_1t = 6.07710050650619224932e-11;
const _pio2_2 = 6.07710050630396597660e-11;
const _pio2_2t = 2.02226624879595063154e-21;
const _pio2_3 = 2.02226624871116645580e-21;
const _pio2_3t = 8.47842766036889956997e-32;

// rem_pio2's result: n, y0, y1.
int _n = 0;
double _y0 = 0, _y1 = 0;

void _medium(double x, int ix) {
  final tmp = x * _invPio2 + _toInt;
  final fN = tmp - _toInt;
  final n = fN.toInt();
  var r = x - fN * _pio2_1;
  var w = fN * _pio2_1t;
  var y0 = r - w;
  var ey = (_hi(y0) >> 20) & 0x7ff;
  final ex = ix >> 20;
  if (ex - ey > 16) {
    var t = r;
    w = fN * _pio2_2;
    r = t - w;
    w = fN * _pio2_2t - ((t - r) - w);
    y0 = r - w;
    ey = (_hi(y0) >> 20) & 0x7ff;
    if (ex - ey > 49) {
      t = r;
      w = fN * _pio2_3;
      r = t - w;
      w = fN * _pio2_3t - ((t - r) - w);
      y0 = r - w;
    }
  }
  _n = n;
  _y0 = y0;
  _y1 = (r - y0) - w;
}

void _set(int n, double y0, double y1) {
  _n = n;
  _y0 = y0;
  _y1 = y1;
}

void _remPio2(double x) {
  final x1p24 = _pow2(1023 + 24);
  final sign = _hi(x) >> 31;
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x400f6a7a) {
    if ((ix & 0xfffff) == 0x921fb) return _medium(x, ix);
    if (ix <= 0x4002d97c) {
      if (sign == 0) {
        final z = x - _pio2_1;
        final y0 = z - _pio2_1t;
        return _set(1, y0, (z - y0) - _pio2_1t);
      } else {
        final z = x + _pio2_1;
        final y0 = z + _pio2_1t;
        return _set(-1, y0, (z - y0) + _pio2_1t);
      }
    } else if (sign == 0) {
      final z = x - 2.0 * _pio2_1;
      final y0 = z - 2.0 * _pio2_1t;
      return _set(2, y0, (z - y0) - 2.0 * _pio2_1t);
    } else {
      final z = x + 2.0 * _pio2_1;
      final y0 = z + 2.0 * _pio2_1t;
      return _set(-2, y0, (z - y0) + 2.0 * _pio2_1t);
    }
  }
  if (ix <= 0x401c463b) {
    if (ix <= 0x4015fdbc) {
      if (ix == 0x4012d97c) return _medium(x, ix);
      if (sign == 0) {
        final z = x - 3.0 * _pio2_1;
        final y0 = z - 3.0 * _pio2_1t;
        return _set(3, y0, (z - y0) - 3.0 * _pio2_1t);
      } else {
        final z = x + 3.0 * _pio2_1;
        final y0 = z + 3.0 * _pio2_1t;
        return _set(-3, y0, (z - y0) + 3.0 * _pio2_1t);
      }
    } else {
      if (ix == 0x401921fb) return _medium(x, ix);
      if (sign == 0) {
        final z = x - 4.0 * _pio2_1;
        final y0 = z - 4.0 * _pio2_1t;
        return _set(4, y0, (z - y0) - 4.0 * _pio2_1t);
      } else {
        final z = x + 4.0 * _pio2_1;
        final y0 = z + 4.0 * _pio2_1t;
        return _set(-4, y0, (z - y0) + 4.0 * _pio2_1t);
      }
    }
  }
  if (ix < 0x413921fb) return _medium(x, ix);
  if (ix >= 0x7ff00000) {
    final y0 = x - x;
    return _set(0, y0, y0);
  }
  // Large arguments: z = scalbn(|x|, -ilogb(x) + 23).
  var z = _fromWords((_hi(x) & 0x000fffff) | ((0x3ff + 23) << 20), _lo(x));
  final tx = Float64List(3);
  for (var i = 0; i < 2; i++) {
    tx[i] = z.toInt().toDouble();
    z = (z - tx[i]) * x1p24;
  }
  tx[2] = z;
  var i = 2;
  while (i != 0 && tx[i] == 0.0) {
    i--;
  }
  final ty = Float64List(3);
  final n = _remPio2Large(tx, i + 1, ty, (ix >> 20) - (0x3ff + 23), 1);
  if (sign != 0) return _set(-n, -ty[0], -ty[1]);
  _set(n, ty[0], ty[1]);
}

const _initJk = [3, 4, 4, 6];

// The first 66 words of 2/pi: all a double's reduction reads.
const _ipio2 = [
  0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62, 0x95993C, //
  0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A, 0x424DD2, 0xE00649,
  0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129, 0xA73EE8, 0x8235F5, 0x2EBB44,
  0x84E99C, 0x7026B4, 0x5F7E41, 0x3991D6, 0x398353, 0x39F49C, 0x845F8B,
  0xBDF928, 0x3B1FF8, 0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D,
  0x367ECF, 0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
  0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08, 0x560330,
  0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3, 0x91615E, 0xE61B08,
  0x659985, 0x5F14A0, 0x68408D, 0xFFD880, 0x4D7327, 0x310606, 0x1556CA,
  0x73A8C9, 0x60E27B, 0xC08C6B,
];

const _pio2 = [
  1.57079625129699707031e+00,
  7.54978941586159635335e-08,
  5.39030252995776476554e-15,
  3.28200341580791294123e-22,
  1.27065575308067607349e-29,
  1.22933308981111328932e-36,
  2.73370053816464559624e-44,
  2.16741683877804819444e-51,
];

int _remPio2Large(Float64List x, int nx, Float64List y, int e0, int prec) {
  final x1p24 = _pow2(1023 + 24);
  final x1p_24 = _pow2(1023 - 24);
  double fw;
  int n, ih;
  double z;
  final f = Float64List(20), fq = Float64List(20), q = Float64List(20);
  final iq = Int32List(20);
  final jk = _initJk[prec];
  final jp = jk;
  final jx = nx - 1;
  var jv = (e0 - 3) ~/ 24;
  if (jv < 0) jv = 0;
  var q0 = e0 - 24 * (jv + 1);
  var j = jv - jx;
  final m = jx + jk;
  for (var i = 0; i <= m; i++) {
    f[i] = j < 0 ? 0.0 : _ipio2[j].toDouble();
    j++;
  }
  for (var i = 0; i <= jk; i++) {
    fw = 0.0;
    for (var j = 0; j <= jx; j++) {
      fw += x[j] * f[jx + i - j];
    }
    q[i] = fw;
  }
  var jz = jk;
  while (true) {
    var i = 0;
    z = q[jz];
    for (var j = jz; j >= 1; j--) {
      fw = (x1p_24 * z).toInt().toDouble();
      iq[i] = (z - x1p24 * fw).toInt();
      z = q[j - 1] + fw;
      i++;
    }
    z = scalbn(z, q0);
    z -= 8.0 * (z * 0.125).floorToDouble();
    n = z.toInt();
    z -= n.toDouble();
    ih = 0;
    if (q0 > 0) {
      i = iq[jz - 1] >> (24 - q0);
      n += i;
      iq[jz - 1] -= i << (24 - q0);
      ih = iq[jz - 1] >> (23 - q0);
    } else if (q0 == 0) {
      ih = iq[jz - 1] >> 23;
    } else if (z >= 0.5) {
      ih = 2;
    }
    if (ih > 0) {
      n += 1;
      var carry = 0;
      for (var i = 0; i < jz; i++) {
        final j = iq[i];
        if (carry == 0) {
          if (j != 0) {
            carry = 1;
            iq[i] = 0x1000000 - j;
          }
        } else {
          iq[i] = 0xffffff - j;
        }
      }
      if (q0 > 0) {
        if (q0 == 1) {
          iq[jz - 1] &= 0x7fffff;
        } else if (q0 == 2) {
          iq[jz - 1] &= 0x3fffff;
        }
      }
      if (ih == 2) {
        z = 1.0 - z;
        if (carry != 0) z -= scalbn(1.0, q0);
      }
    }
    if (z == 0.0) {
      var j = 0;
      for (var i = jz - 1; i >= jk; i--) {
        j |= iq[i];
      }
      if (j == 0) {
        var k = 1;
        while (iq[jk - k] == 0) {
          k++;
        }
        for (var i = jz + 1; i <= jz + k; i++) {
          f[jx + i] = _ipio2[jv + i].toDouble();
          fw = 0.0;
          for (var j = 0; j <= jx; j++) {
            fw += x[j] * f[jx + i - j];
          }
          q[i] = fw;
        }
        jz += k;
        continue;
      }
    }
    break;
  }
  if (z == 0.0) {
    jz -= 1;
    q0 -= 24;
    while (iq[jz] == 0) {
      jz -= 1;
      q0 -= 24;
    }
  } else {
    z = scalbn(z, -q0);
    if (z >= x1p24) {
      fw = (x1p_24 * z).toInt().toDouble();
      iq[jz] = (z - x1p24 * fw).toInt();
      jz += 1;
      q0 += 24;
      iq[jz] = fw.toInt();
    } else {
      iq[jz] = z.toInt();
    }
  }
  fw = scalbn(1.0, q0);
  for (var i = jz; i >= 0; i--) {
    q[i] = fw * iq[i].toDouble();
    fw *= x1p_24;
  }
  for (var i = jz; i >= 0; i--) {
    fw = 0.0;
    var k = 0;
    while (k <= jp && k <= jz - i) {
      fw += _pio2[k] * q[i + k];
      k++;
    }
    fq[jz - i] = fw;
  }
  // prec 1 (the only one sin and cos use).
  fw = 0.0;
  for (var i = jz; i >= 0; i--) {
    fw += fq[i];
  }
  y[0] = ih == 0 ? fw : -fw;
  fw = fq[0] - fw;
  for (var i = 1; i <= jz; i++) {
    fw += fq[i];
  }
  y[1] = ih == 0 ? fw : -fw;
  return n & 7;
}
