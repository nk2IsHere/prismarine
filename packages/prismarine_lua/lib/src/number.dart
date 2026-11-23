// Ported from `luaO_str2d` and `lua_strx2number` of Lua 5.2.3 lobject.c and
// the number macros of luaconf.h and llimits.h (MIT, see LICENSE-lua), for
// the three number modes of config.dart.

import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;

import 'config.dart';

final _f32 = Float32List(1);

/// The NaN that an invalid operation gives on x86-64, quiet with the sign
/// set. Every NaN result of a mode without NaN pass-through is this one.
final double luaNaN = (ByteData(
  8,
)..setUint64(0, 0xFFF8000000000000)).getFloat64(0);

/// The VMs of this isolate have float numbers, or doubles when false. The
/// first VM sets it. Null before the first VM.
bool? luaIsolateFloat32;

/// Integer table keys beyond 2^24 are float values in this isolate.
bool luaFloatKeys = false;

/// Records the numbers of a VM in [mode] for the isolate. Fails when another
/// VM of this isolate has float numbers and [mode] has doubles, or the
/// reverse.
void luaClaimNumberMode(LuaNumberMode mode) {
  final f = luaIsolateFloat32 ??= mode.isFloat32;
  if (f != mode.isFloat32) {
    throw StateError(
      'a Lua VM in $mode mode in an isolate whose VMs have '
      '${f ? 'float' : 'double'} numbers',
    );
  }
  luaFloatKeys = f;
}

/// Rounds [x] to the nearest float32, as a store to a C `float` does, with
/// the canonical NaN.
@pragma('vm:prefer-inline')
double f32(double x) {
  _f32[0] = x;
  final r = _f32[0];
  return r.isNaN ? luaNaN : r;
}

/// Rounds [x] to the nearest float32 and keeps the bits of a NaN, which the
/// conversion makes quiet.
@pragma('vm:prefer-inline')
double r32(double x) {
  _f32[0] = x;
  return _f32[0];
}

/// [x] with the canonical NaN.
@pragma('vm:prefer-inline')
double f64(double x) => x.isNaN ? luaNaN : x;

/// The C double result [x] as a `lua_Number`, a float when [float32].
@pragma('vm:prefer-inline')
double luaNumber(double x, bool float32) => float32 ? f32(x) : f64(x);

/// `luai_nummod` in the float32 mode. The quotient is in double and its
/// floor is stored as a float. The product and the difference are in double,
/// and the result is stored as a float.
double luaMod(double a, double b) => f32(a - f32((a / b).floorToDouble()) * b);

/// `luai_numpow` in the float32 mode, the double `pow` stored as a float.
double luaPow(double a, double b) => f32(libm.dpow(a, b));

/// `luai_nummod` in the float64 mode.
double luaMod64(double a, double b) => f64(a - (a / b).floorToDouble() * b);

/// `luai_numpow` in the float64 mode.
double luaPow64(double a, double b) => f64(libm.dpow(a, b));

/// The NaN result of a single-precision operation on [a] and [b]. Returns
/// the first NaN operand made quiet, else the canonical NaN.
double nanResult(double a, double b) => a.isNaN
    ? r32(a)
    : b.isNaN
    ? r32(b)
    : luaNaN;

/// [r], the result of a single-precision operation on [a] and [b].
@pragma('vm:prefer-inline')
double singleOp(double r, double a, double b) =>
    r.isNaN ? nanResult(a, b) : r32(r);

/// `luai_nummod` in the float32Single mode, `a - floorf(a / b) * b` with
/// every operation in float.
double luaModSingle(double a, double b) {
  final q = singleOp(a / b, a, b);
  // A NaN quotient is already quiet, which floorf keeps.
  final f = q.isNaN ? q : q.floorToDouble();
  final m = singleOp(f * b, f, b);
  return singleOp(a - m, a, m);
}

/// The digit step `n = n * base + d` of `tonumber(s, base)` in [mode].
double baseStep(double n, int base, int digit, LuaNumberMode mode) =>
    switch (mode) {
      LuaNumberMode.float64 => n * base + digit,
      LuaNumberMode.float32 => f32(n * base + digit),
      LuaNumberMode.float32Single => f32(f32(base.toDouble() * n) + digit),
    };

/// `lua_pushinteger` of a 64-bit value in a float mode. Rounds once to
/// float, as `cvtsi2ss` does.
double int64ToF32(int v) {
  if (v == -0x8000000000000000) return -9223372036854775808.0;
  final m = v.abs();
  if (m < 0x20000000000000) return f32(v.toDouble());
  final shift = m.bitLength - 24;
  final dropped = m & ((1 << shift) - 1);
  final half = 1 << (shift - 1);
  var keep = m >> shift;
  if (dropped > half || (dropped == half && keep.isOdd)) keep++;
  final r = keep.toDouble() * (1 << shift).toDouble();
  return v < 0 ? -r : r;
}

/// Lua's `lisspace` in the C locale.
bool luaIsSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D);
bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

int _hexValue(int c) {
  if (_isDigit(c)) return c - 0x30;
  return (c | 0x20) - 0x61 + 10;
}

bool _isHex(int c) => _isDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);

/// `luaO_str2d`. Returns [s] as a number of [mode], or null unless all of
/// [s] is a number. Spaces around it are allowed.
double? parseLuaNumber(String s, LuaNumberMode mode) {
  final f = mode.isFloat32;
  if (s.contains('n') || s.contains('N')) return null;
  final len = s.length;
  var i = 0;
  double r;
  int end;
  if (s.contains('x') || s.contains('X')) {
    // lua_strx2number, hexadecimal and accumulated in lua_Number.
    while (i < len && luaIsSpace(s.codeUnitAt(i))) {
      i++;
    }
    var neg = false;
    if (i < len && s.codeUnitAt(i) == 0x2D) {
      neg = true;
      i++;
    } else if (i < len && s.codeUnitAt(i) == 0x2B) {
      i++;
    }
    if (!(i + 1 < len &&
        s.codeUnitAt(i) == 0x30 &&
        (s.codeUnitAt(i + 1) | 0x20) == 0x78)) {
      return null;
    }
    i += 2;
    var acc = 0.0;
    var nInt = 0, e = 0;
    while (i < len && _isHex(s.codeUnitAt(i))) {
      acc = luaNumber(acc * 16 + _hexValue(s.codeUnitAt(i)), f);
      nInt++;
      i++;
    }
    if (i < len && s.codeUnitAt(i) == 0x2E) {
      i++;
      while (i < len && _isHex(s.codeUnitAt(i))) {
        acc = luaNumber(acc * 16 + _hexValue(s.codeUnitAt(i)), f);
        e++;
        i++;
      }
    }
    if (nInt == 0 && e == 0) return null;
    e *= -4;
    end = i;
    if (i < len && (s.codeUnitAt(i) | 0x20) == 0x70) {
      var j = i + 1;
      var neg1 = false;
      if (j < len && s.codeUnitAt(j) == 0x2D) {
        neg1 = true;
        j++;
      } else if (j < len && s.codeUnitAt(j) == 0x2B) {
        j++;
      }
      if (j < len && _isDigit(s.codeUnitAt(j))) {
        var exp1 = 0;
        while (j < len && _isDigit(s.codeUnitAt(j))) {
          exp1 = exp1 * 10 + s.codeUnitAt(j) - 0x30;
          j++;
        }
        e += neg1 ? -exp1 : exp1;
        end = j;
      }
    }
    if (neg) acc = -acc;
    r = luaNumber(acc * libm.dpow(2.0, e.toDouble()), f);
  } else {
    // strtod, decimal.
    while (i < len && luaIsSpace(s.codeUnitAt(i))) {
      i++;
    }
    final start = i;
    if (i < len && (s.codeUnitAt(i) == 0x2D || s.codeUnitAt(i) == 0x2B)) i++;
    var digits = 0;
    while (i < len && _isDigit(s.codeUnitAt(i))) {
      i++;
      digits++;
    }
    if (i < len && s.codeUnitAt(i) == 0x2E) {
      i++;
      while (i < len && _isDigit(s.codeUnitAt(i))) {
        i++;
        digits++;
      }
    }
    if (digits == 0) return null;
    if (i < len && (s.codeUnitAt(i) | 0x20) == 0x65) {
      var j = i + 1;
      if (j < len && (s.codeUnitAt(j) == 0x2D || s.codeUnitAt(j) == 0x2B)) j++;
      if (j < len && _isDigit(s.codeUnitAt(j))) {
        while (j < len && _isDigit(s.codeUnitAt(j))) {
          j++;
        }
        i = j;
      }
    }
    end = i;
    var tok = s.substring(start, end);
    if (tok.endsWith('.')) tok = '${tok}0';
    if (tok.startsWith('.') || tok.startsWith('-.') || tok.startsWith('+.')) {
      tok = tok.replaceFirst('.', '0.');
    }
    r = luaNumber(double.parse(tok), f);
  }
  while (end < len && luaIsSpace(s.codeUnitAt(end))) {
    end++;
  }
  return end == len ? r : null;
}

/// `lua_number2int`, a truncation. A NaN or a value outside int32 gives
/// 0x80000000, as the x86 conversion instructions do.
int luaToInt32(double n) {
  if (n.isNaN || n >= 2147483648.0 || n < -2147483648.0) return -2147483648;
  return n.truncate();
}

/// `lua_number2integer`, a truncation to the `lua_Integer` of 64 bits when
/// [integer64], else of 32 bits. A NaN or a value outside the range gives
/// the smallest integer.
int luaToInteger(double n, bool integer64) {
  if (!integer64) return luaToInt32(n);
  if (n.isNaN || n >= 9223372036854775808.0 || n < -9223372036854775808.0) {
    return -0x8000000000000000;
  }
  return n.truncate();
}

/// `luaL_checkint`: `(int)` of the `lua_Integer`, which keeps the low 32
/// bits of a 64-bit one.
int luaToCInt(double n, bool integer64) =>
    integer64 ? luaToInteger(n, true).toSigned(32) : luaToInt32(n);

/// `lua_number2unsigned` with the `SUPUNSIGNED` formula of llimits.h. Returns
/// the low 32 bits of n − floor(n / 2³²) · 2³² truncated to 64 bits.
int numberToUnsigned(double n) {
  if (!n.isFinite) return 0;
  final r = n - (n / 4294967296.0).floorToDouble() * 4294967296.0;
  return r.truncate() & 0xFFFFFFFF;
}

/// C `frexp`. Returns m and e with [x] = m·2^e and 0.5 ≤ |m| < 1, or m = x
/// and e = 0 for 0, inf and NaN.
@pragma('vm:prefer-inline')
(double, int) frexp(double x) {
  if (x == 0 || !x.isFinite) return (x, 0);
  // One shared 8-byte buffer. Lua hashes every number key with it.
  _frexpF[0] = x;
  final bits = _frexpBits[0];
  final exp = (bits >> 52) & 0x7FF;
  if (exp == 0) return _frexpSubnormal(x);
  _frexpBits[0] = (bits & ~(0x7FF << 52)) | (1022 << 52);
  return (_frexpF[0], exp - 1022);
}

(double, int) _frexpSubnormal(double x) {
  final (m, e) = frexp(x * 18014398509481984.0); // 2^54
  return (m, e - 54);
}

final _frexpF = Float64List(1);
final _frexpBits = Int64List.view(_frexpF.buffer);
