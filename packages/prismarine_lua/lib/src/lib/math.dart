// Ported from Lua 5.2.3 lmathlib.c (MIT; see LICENSE-lua). `math.random`
// draws from the VM's xorshift128 generator (docs/formats/lua-runtime.md,
// "`math.random`"). Results are rounded to the VM's number mode.

import 'dart:math' as m;

import 'package:prismarine_math/libm.dart' as libm;
import '../number.dart';
import '../state.dart';
import '../table.dart';

typedef _F1 = double Function(double);

LuaCFunction _f1(_F1 f) => (L) {
  L.push(L.number(f(L.checkNumber(1))));
  return 1;
};

double _sinh(double x) => (libm.exp(x) - libm.exp(-x)) / 2;
double _cosh(double x) => (libm.exp(x) + libm.exp(-x)) / 2;
double _tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final e2 = libm.exp(2 * x);
  return (e2 - 1) / (e2 + 1);
}

double _fmod(double a, double b) {
  if (b == 0 || a.isInfinite || a.isNaN || b.isNaN) return double.nan;
  if (b.isInfinite) return a;
  return a.remainder(b);
}

const _piDouble = 3.1415926535897932384626433832795;
final double _pi = f32(_piDouble);
final double _radiansPerDegree = f32(_pi / 180.0);
const _radiansPerDegree64 = _piDouble / 180.0;

double _perDegree(LuaThread L) =>
    L.vm.float32 ? _radiansPerDegree : _radiansPerDegree64;

int _fmodN(LuaThread L) {
  L.push(L.number(_fmod(L.checkNumber(1), L.checkNumber(2))));
  return 1;
}

int _modf(LuaThread L) {
  final x = L.checkNumber(1);
  final ip = x.isInfinite ? x : x.truncateToDouble();
  final fp = x.isInfinite ? 0.0 : L.number(x - ip);
  L.push(L.number(ip));
  L.push(fp);
  return 2;
}

int _pow(LuaThread L) {
  final x = L.checkNumber(1);
  final y = L.checkNumber(2);
  L.push(L.vm.float32 ? luaPow(x, y) : luaPow64(x, y));
  return 1;
}

int _log(LuaThread L) {
  final x = L.checkNumber(1);
  double res;
  if (L.arg(2) == null) {
    res = libm.log(x);
  } else {
    final base = L.checkNumber(2);
    res = base == 10.0 ? libm.log(x) / m.ln10 : libm.log(x) / libm.log(base);
  }
  L.push(L.number(res));
  return 1;
}

int _deg(LuaThread L) {
  L.push(L.number(L.checkNumber(1) / _perDegree(L)));
  return 1;
}

int _rad(LuaThread L) {
  L.push(L.number(L.checkNumber(1) * _perDegree(L)));
  return 1;
}

int _frexp(LuaThread L) {
  final (mm, e) = frexp(L.checkNumber(1));
  L.push(L.number(mm));
  L.push(e.toDouble());
  return 2;
}

int _ldexp(LuaThread L) {
  final x = L.checkNumber(1);
  final e = L.checkInt(2);
  L.push(L.number(x * libm.dpow(2.0, e.toDouble())));
  return 1;
}

int _min(LuaThread L) {
  final n = L.getTop();
  var d = L.checkNumber(1);
  for (var i = 2; i <= n; i++) {
    final v = L.checkNumber(i);
    if (v < d) d = v;
  }
  L.push(d);
  return 1;
}

int _max(LuaThread L) {
  final n = L.getTop();
  var d = L.checkNumber(1);
  for (var i = 2; i <= n; i++) {
    final v = L.checkNumber(i);
    if (v > d) d = v;
  }
  L.push(d);
  return 1;
}

/// `math.random` on the VM's xorshift128 generator (see
/// formats/telltale/lua-runtime.md, "`math.random`").
int _random(LuaThread L) {
  final rng = L.vm.rng;
  switch (L.getTop()) {
    case 0:
      L.push(L.number(rng.next() / 4294967296.0));
    case 1:
      final n = L.checkInteger(1);
      if (n < 1) L.argError(1, 'interval is empty');
      L.push(L.number((rng.next() % n + 1).toDouble()));
    case 2:
      final lo = L.checkInteger(1);
      final hi = L.checkInteger(2);
      if (lo > hi) L.argError(2, 'interval is empty');
      final d = (hi - lo + 1) & 0xFFFFFFFF;
      final r = rng.next();
      final v = (d == 0 ? r : r % d) + lo;
      L.push(L.number(v.toSigned(32).toDouble()));
    default:
      L.luaError('wrong number of arguments');
  }
  return 1;
}

/// `math.randomseed`: 0 resets the default state (see
/// formats/telltale/lua-runtime.md, "Seeding").
int _randomseed(LuaThread L) {
  final n = L.checkUnsigned(1);
  if (n == 0) {
    L.vm.rng.reset();
  } else {
    L.vm.rng.seed(n);
  }
  return 0;
}

/// `luaopen_math` into [t] (`mathlib` order, then pi and huge) for [vm].
/// [random] and [randomseed] replace the functions on the VM's generator.
///
/// The libm functions are called from closures, never torn off: a tear-off
/// keeps the compiler from passing their double argument unboxed at every
/// other call site (the chore engine's slerps called them with a boxed
/// double each; perf).
LuaTable openStandardMath(
  LuaVm vm,
  LuaTable t, {
  LuaCFunction? random,
  LuaCFunction? randomseed,
}) {
  for (final (name, f) in <(String, LuaCFunction)>[
    ('abs', _f1((x) => x.abs())),
    ('acos', _f1((x) => libm.acos(x))),
    ('asin', _f1((x) => libm.asin(x))),
    (
      'atan2',
      (L) {
        L.push(L.number(libm.atan2(L.checkNumber(1), L.checkNumber(2))));
        return 1;
      },
    ),
    ('atan', _f1((x) => libm.atan(x))),
    ('ceil', _f1((x) => x.ceilToDouble())),
    ('cosh', _f1(_cosh)),
    ('cos', _f1((x) => libm.cos(x))),
    ('deg', _deg),
    ('exp', _f1((x) => libm.exp(x))),
    ('floor', _f1((x) => x.floorToDouble())),
    ('fmod', _fmodN),
    ('frexp', _frexp),
    ('ldexp', _ldexp),
    ('log', _log),
    ('max', _max),
    ('min', _min),
    ('modf', _modf),
    ('pow', _pow),
    ('rad', _rad),
    ('random', random ?? _random),
    ('randomseed', randomseed ?? _randomseed),
    ('sinh', _f1(_sinh)),
    ('sin', _f1((x) => libm.sin(x))),
    ('sqrt', _f1(m.sqrt)),
    ('tanh', _f1(_tanh)),
    ('tan', _f1((x) => libm.tan(x))),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  t
    ..set('pi', vm.float32 ? _pi : _piDouble)
    ..set('huge', double.infinity);
  return t;
}
