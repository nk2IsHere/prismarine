// pow, and dpow on top of it.
part of '../../libm.dart';

// --------------------------------------------------------------------- pow

const _bp = [1.0, 1.5];
const _dpH = [0.0, 5.84962487220764160156e-01];
const _dpL = [0.0, 1.35003920212974897128e-08];
const _two53 = 9007199254740992.0;
const _huge = 1.0e300;
const _tiny = 1.0e-300;
const _l1 = 5.99999999999994648725e-01;
const _l2 = 4.28571428578550184252e-01;
const _l3 = 3.33333329818377432918e-01;
const _l4 = 2.72728123808534006489e-01;
const _l5 = 2.30660745775561754067e-01;
const _l6 = 2.06975017800338417784e-01;
const _lg2c = 6.93147180559945286227e-01;
const _lg2H = 6.93147182464599609375e-01;
const _lg2L = -1.90465429995776804525e-09;
const _ovt = 8.0085662595372944372e-017;
const _cp = 9.61796693925975554329e-01;
const _cpH = 9.61796700954437255859e-01;
const _cpL = -7.02846165095275826516e-09;
const _ivln2 = 1.44269504088896338700e+00;
const _ivln2H = 1.44269502162933349609e+00;
const _ivln2L = 1.92596299112661746887e-08;

/// libm's pow.
double pow(double x, double y) {
  double t1, t2;
  final hx = _i32(_hi(x)), lx = _lo(x);
  final hy = _i32(_hi(y)), ly = _lo(y);
  var ix = hx & 0x7fffffff;
  final iy = hy & 0x7fffffff;
  if ((iy | ly) == 0) return 1.0;
  if (hx == 0x3ff00000 && lx == 0) return 1.0;
  if (ix > 0x7ff00000 ||
      (ix == 0x7ff00000 && lx != 0) ||
      iy > 0x7ff00000 ||
      (iy == 0x7ff00000 && ly != 0)) {
    return x + y;
  }
  var yisint = 0;
  int k, j;
  if (hx < 0) {
    if (iy >= 0x43400000) {
      yisint = 2;
    } else if (iy >= 0x3ff00000) {
      k = (iy >> 20) - 0x3ff;
      if (k > 20) {
        j = _i32(ly >> (52 - k));
        if (_i32(j << (52 - k)) == _i32(ly)) yisint = 2 - (j & 1);
      } else if (ly == 0) {
        j = iy >> (20 - k);
        if ((j << (20 - k)) == iy) yisint = 2 - (j & 1);
      }
    }
  }
  if (ly == 0) {
    if (iy == 0x7ff00000) {
      if (((ix - 0x3ff00000) | _i32(lx)) == 0) return 1.0;
      if (ix >= 0x3ff00000) return hy >= 0 ? y : 0.0;
      return hy >= 0 ? 0.0 : -y;
    }
    if (iy == 0x3ff00000) return hy >= 0 ? x : 1.0 / x;
    if (hy == 0x40000000) return x * x;
    if (hy == 0x3fe00000) {
      if (hx >= 0) return math.sqrt(x);
    }
  }
  var ax = x.abs();
  if (lx == 0) {
    if (ix == 0x7ff00000 || ix == 0 || ix == 0x3ff00000) {
      var z = ax;
      if (hy < 0) z = 1.0 / z;
      if (hx < 0) {
        if (((ix - 0x3ff00000) | yisint) == 0) {
          z = (z - z) / (z - z);
        } else if (yisint == 1) {
          z = -z;
        }
      }
      return z;
    }
  }
  var s = 1.0;
  if (hx < 0) {
    if (yisint == 0) return (x - x) / (x - x);
    if (yisint == 1) s = -1.0;
  }
  if (iy > 0x41e00000) {
    if (iy > 0x43f00000) {
      if (ix <= 0x3fefffff) return hy < 0 ? _huge * _huge : _tiny * _tiny;
      if (ix >= 0x3ff00000) return hy > 0 ? _huge * _huge : _tiny * _tiny;
    }
    if (ix < 0x3fefffff) {
      return hy < 0 ? s * _huge * _huge : s * _tiny * _tiny;
    }
    if (ix > 0x3ff00000) {
      return hy > 0 ? s * _huge * _huge : s * _tiny * _tiny;
    }
    final t = ax - 1.0;
    final w = (t * t) * (0.5 - t * (0.3333333333333333333333 - t * 0.25));
    final u = _ivln2H * t;
    final v = t * _ivln2L - w * _ivln2;
    t1 = _withLo(u + v, 0);
    t2 = v - (t1 - u);
  } else {
    var n = 0;
    if (ix < 0x00100000) {
      ax *= _two53;
      n -= 53;
      ix = _hi(ax);
    }
    n += (ix >> 20) - 0x3ff;
    j = ix & 0x000fffff;
    int k;
    ix = j | 0x3ff00000;
    if (j <= 0x3988E) {
      k = 0;
    } else if (j < 0xBB67A) {
      k = 1;
    } else {
      k = 0;
      n += 1;
      ix -= 0x00100000;
    }
    ax = _withHi(ax, ix);
    final u = ax - _bp[k];
    final v = 1.0 / (ax + _bp[k]);
    final ss = u * v;
    final sH = _withLo(ss, 0);
    var tH = _fromWords(((ix >> 1) | 0x20000000) + 0x00080000 + (k << 18), 0);
    var tL = ax - (tH - _bp[k]);
    final sL = v * ((u - sH * tH) - sH * tL);
    var s2 = ss * ss;
    var r =
        s2 *
        s2 *
        (_l1 + s2 * (_l2 + s2 * (_l3 + s2 * (_l4 + s2 * (_l5 + s2 * _l6)))));
    r += sL * (sH + ss);
    s2 = sH * sH;
    tH = _withLo(3.0 + s2 + r, 0);
    tL = r - ((tH - 3.0) - s2);
    final u2 = sH * tH;
    final v2 = sL * tH + tL * ss;
    final pH = _withLo(u2 + v2, 0);
    final pL = v2 - (pH - u2);
    final zH = _cpH * pH;
    final zL = _cpL * pH + pL * _cp + _dpL[k];
    final t = n.toDouble();
    t1 = _withLo(((zH + zL) + _dpH[k]) + t, 0);
    t2 = zL - (((t1 - t) - _dpH[k]) - zH);
  }
  final y1 = _withLo(y, 0);
  final pL = (y - y1) * t1 + y * t2;
  var pH = y1 * t1;
  var z = pL + pH;
  j = _i32(_hi(z));
  final i0 = _i32(_lo(z));
  if (j >= 0x40900000) {
    if (((j - 0x40900000) | i0) != 0) return s * _huge * _huge;
    if (pL + _ovt > z - pH) return s * _huge * _huge;
  } else if ((j & 0x7fffffff) >= 0x4090cc00) {
    if (((_u32(j) - 0xc090cc00) | _u32(i0)) != 0) return s * _tiny * _tiny;
    if (pL <= z - pH) return s * _tiny * _tiny;
  }
  final i = j & 0x7fffffff;
  k = (i >> 20) - 0x3ff;
  var n = 0;
  if (i > 0x3fe00000) {
    n = _i32(j + (0x00100000 >> (k + 1)));
    k = ((n & 0x7fffffff) >> 20) - 0x3ff;
    final t = _fromWords(n & ~(0x000fffff >> k), 0);
    n = ((n & 0x000fffff) | 0x00100000) >> (20 - k);
    if (j < 0) n = -n;
    pH -= t;
  }
  final t = _withLo(pL + pH, 0);
  final u = t * _lg2H;
  final v = (pL - (t - pH)) * _lg2c + t * _lg2L;
  z = u + v;
  final w = v - (z - u);
  final tt = z * z;
  final t1b = z - tt * (_p1 + tt * (_p2 + tt * (_p3 + tt * (_p4 + tt * _p5))));
  final r = (z * t1b) / (t1b - 2.0) - (w + z * w);
  z = 1.0 - (r - z);
  j = _i32(_hi(z));
  j = _i32(j + (n << 20));
  if ((j >> 20) <= 0) {
    z = scalbn(z, n);
  } else {
    z = _withHi(z, j);
  }
  return s * z;
}

/// dart:math's `pow` on doubles (the VM's fast paths: native/mixer's
/// `dpow`), with libm's pow behind them.
double dpow(double b, double e) {
  if (e == 0.0) return 1.0;
  if (!e.isNaN) {
    if (e == 1.0) return b;
    if (e == 2.0) return b * b;
    if (e == 3.0) return b * b * b;
  }
  if (b.isNaN) return double.nan;
  if (b == 1.0) return 1.0;
  if (e.isNaN) return double.nan;
  if (b != double.negativeInfinity && e == 0.5) {
    if (b == 0.0) return 0.0;
    return math.sqrt(b);
  }
  return pow(b, e);
}
