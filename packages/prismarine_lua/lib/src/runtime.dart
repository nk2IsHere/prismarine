// The C library under a Lua build, with the number text of printf, the
// widths of `long` and `size_t`, `%p`, strftime and gmtime. Ported from the
// behaviour of the C library that Lua 5.2.3 lobject.c, lstrlib.c and
// loslib.c call (MIT, see LICENSE-lua).

import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;

import 'number.dart';

final _bits = ByteData(8);

bool _signBit(double v) {
  _bits.setFloat64(0, v);
  return _bits.getUint8(0) & 0x80 != 0;
}

/// The C runtime of a Lua build. The default is the C library of a 64-bit
/// POSIX system. A subclass overrides the members in which another C library
/// differs.
class LuaCRuntime {
  const LuaCRuntime();

  /// Rounds the digits that printf drops half to even on the exact value.
  /// False rounds half up on the digit string.
  bool get halfEven => true;

  /// The least number of exponent digits of `%e`.
  int get exponentDigits => 2;

  /// The decimal exponent that `%g` takes for zero.
  int get zeroExponent => 0;

  /// The decimal digits of a finite non-zero [v] that printf works from,
  /// with value = 0.`digits` × 10^`point` and without leading or trailing
  /// zeros.
  (String, int) digits(double v) => exactDigits(v);

  /// The text of inf or NaN for `%e`, `%f`, `%g` and `%a`.
  String nonFiniteText(double v, {bool upper = false}) {
    final neg = _signBit(v);
    final s = v.isNaN ? (neg ? '-nan' : 'nan') : (neg ? '-inf' : 'inf');
    return upper ? s.toUpperCase() : s;
  }

  /// The whole text of inf or NaN for the conversion [conv] (`e`, `f` or
  /// `g`) at precision [prec], or null for [nonFiniteText].
  String? specialText(
    double v,
    int prec,
    int conv, {
    bool upper = false,
    bool alt = false,
  }) => null;

  /// The text [s] of inf or NaN for the `#` flag at precision 0 of `%e` and
  /// `%f`.
  String pointNonFinite(String s) => s;

  /// The `0` flag also pads inf and NaN text with zeros.
  bool get zeroPadsNonFinite => false;

  /// The C library has `%a`.
  bool get hexFloat => false;

  /// `%a` of [v], or null where the C library has no `%a`.
  String? formatA(double v, int prec, {bool upper = false, bool alt = false}) =>
      null;

  /// C `(long)n` as `%d` takes it.
  int toLong(double n) {
    if (n.isNaN) return 0;
    if (n >= 9223372036854775807.0) return 0x7FFFFFFFFFFFFFFF;
    if (n <= -9223372036854775808.0) return -0x8000000000000000;
    return n.truncate();
  }

  /// C `(unsigned long)n` as `%x` takes it, as a non-negative double.
  double toULong(double n) {
    if (n.isNaN || n <= 0) return 0;
    if (n >= 18446744073709551616.0) return 18446744073709551615.0;
    return n.truncateToDouble();
  }

  /// `MAXSIZE`, the largest string length.
  int get sizeMax => 0x7FFFFFFFFFFFFFFF;

  /// The text of `%p` for the object with [id].
  String pointerText(int id) => '0x${id.toRadixString(16).padLeft(8, '0')}';

  /// `os.date` accepts the POSIX conversions with the `E` and `O` modifiers.
  /// False accepts the ANSI C conversions only.
  bool get posixDate => true;

  /// `gmtime` rounds a negative time down to its day.
  bool get gmtimeFloors => false;

  /// `gmtime` accepts the time [t].
  bool gmtimeAccepts(int t) => true;

  /// `powf`, the single-precision `pow`.
  double powf(double a, double b) => f32(libm.dpow(a, b));

  /// `lua_number2str`, the C `"%.14g"`.
  String numberToString(double n) {
    if (n == n.truncateToDouble() && n.abs() < 1e14) {
      if (n == 0) return _signBit(n) ? '-0' : '0';
      return n.toInt().toString();
    }
    return formatG(n, 14);
  }

  String _sign(double v, bool plus, bool space) => _signBit(v)
      ? '-'
      : plus
      ? '+'
      : space
      ? ' '
      : '';

  /// C `%.<prec>e` without width. The exponent has at least
  /// [exponentDigits] digits.
  String formatE(
    double v,
    int prec, {
    bool upper = false,
    bool alt = false,
    bool plus = false,
    bool space = false,
  }) {
    if (!v.isFinite) {
      final sp = specialText(v, prec, 0x65, upper: upper, alt: alt);
      if (sp != null) return sp;
      return nonFiniteText(v, upper: upper);
    }
    String r;
    int x;
    if (v == 0) {
      r = '';
      x = 0;
    } else {
      final (d, point) = digits(v);
      final (rr, carry) = roundDigits(d, prec + 1, halfEven);
      r = carry == 1 ? rr.substring(0, prec + 1) : rr;
      x = point - 1 + carry;
    }
    r = r.padRight(prec + 1, '0');
    final mant = prec > 0 || alt ? '${r[0]}.${r.substring(1)}' : r[0];
    final ex = x.abs().toString().padLeft(exponentDigits, '0');
    return '${_sign(v, plus, space)}$mant${upper ? 'E' : 'e'}${x < 0 ? '-' : '+'}$ex';
  }

  /// C `%.<prec>f` without width.
  String formatF(
    double v,
    int prec, {
    bool alt = false,
    bool plus = false,
    bool space = false,
    bool upper = false,
  }) {
    if (!v.isFinite) {
      final sp = specialText(v, prec, 0x66, upper: upper, alt: alt);
      if (sp != null) return sp;
      return nonFiniteText(v, upper: upper);
    }
    String s; // the digits of round(|v| × 10^prec), with `point` integer digits
    int point;
    if (v == 0) {
      s = '';
      point = 0;
    } else {
      final (d, pt) = digits(v);
      final (r, carry) = roundDigits(d, pt + prec, halfEven);
      s = r;
      point = pt + carry;
    }
    final total = point + prec;
    if (total > 0) s = s.padRight(total, '0');
    String ip, fp;
    if (point > 0) {
      ip = s.substring(0, point);
      fp = s.substring(point);
    } else {
      ip = '0';
      fp = ('0' * -point + s);
      fp = fp.length > prec ? fp.substring(0, prec) : fp.padRight(prec, '0');
    }
    final frac = prec > 0 || alt ? '.$fp' : '';
    return '${_sign(v, plus, space)}$ip$frac';
  }

  /// C `%.<prec>g` without width.
  String formatG(
    double v,
    int prec, {
    bool upper = false,
    bool alt = false,
    bool plus = false,
    bool space = false,
  }) {
    final pp = prec == 0 ? 1 : prec;
    if (!v.isFinite) {
      final sp = specialText(v, pp, 0x67, upper: upper, alt: alt);
      if (sp != null) return sp;
      return nonFiniteText(v, upper: upper);
    }
    int x;
    if (v == 0) {
      x = zeroExponent;
    } else {
      final (d, point) = digits(v);
      final (_, carry) = roundDigits(d, pp, halfEven);
      x = point - 1 + carry;
    }
    String s;
    if (pp > x && x >= -4) {
      s = formatF(v, pp - 1 - x, alt: alt, plus: plus, space: space);
      if (!alt) s = stripZeros(s);
    } else {
      s = formatE(v, pp - 1, upper: upper, alt: alt, plus: plus, space: space);
      if (!alt) {
        final ei = s.indexOf(upper ? 'E' : 'e');
        s = stripZeros(s.substring(0, ei)) + s.substring(ei);
      }
    }
    return s;
  }
}

/// Drops the trailing zeros of the fraction of [s], and its point when no
/// digit follows it.
String stripZeros(String s) {
  if (!s.contains('.')) return s;
  var end = s.length;
  while (s.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (s.codeUnitAt(end - 1) == 0x2E) end--;
  return s.substring(0, end);
}

/// The exact decimal digits of a finite non-zero [v], with value =
/// 0.`digits` × 10^`point` and without leading or trailing zeros.
(String, int) exactDigits(double v) {
  _bits.setFloat64(0, v.abs());
  final bits = _bits.getUint64(0);
  final exp = (bits >> 52) & 0x7FF;
  var mant = bits & 0xFFFFFFFFFFFFF;
  int e;
  if (exp == 0) {
    e = -1074;
  } else {
    mant |= 1 << 52;
    e = exp - 1075;
  }
  while (mant & 1 == 0 && e < 0) {
    mant >>= 1;
    e++;
  }
  String d;
  int point;
  if (e >= 0) {
    d = (BigInt.from(mant) << e).toString();
    point = d.length;
  } else {
    d = (BigInt.from(mant) * BigInt.from(5).pow(-e)).toString();
    point = d.length + e;
  }
  var end = d.length;
  while (end > 1 && d.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  return (d.substring(0, end), point);
}

/// Keeps the first [keep] digits of [d], which may be 0 or less, and rounds
/// the rest half to even on the exact value when [halfEven], else half up on
/// the digit string. Returns the kept digits and 1 when a carry added a
/// leading digit.
(String, int) roundDigits(String d, int keep, bool halfEven) {
  if (keep >= d.length) return (d, 0);
  bool up;
  if (keep < 0) {
    up = false;
  } else {
    final c = d.codeUnitAt(keep) - 0x30;
    if (c != 5) {
      up = c > 5;
    } else if (!halfEven) {
      up = true;
    } else {
      var rest = false;
      for (var i = keep + 1; i < d.length; i++) {
        if (d.codeUnitAt(i) != 0x30) {
          rest = true;
          break;
        }
      }
      up = rest || (keep > 0 && (d.codeUnitAt(keep - 1) - 0x30).isOdd);
    }
  }
  final kept = keep <= 0 ? '' : d.substring(0, keep);
  if (!up) return (kept, 0);
  if (kept.isEmpty) return ('1', 1);
  final cs = kept.codeUnits.toList();
  var i = cs.length - 1;
  while (i >= 0 && cs[i] == 0x39) {
    cs[i] = 0x30;
    i--;
  }
  if (i < 0) return ('1${String.fromCharCodes(cs)}', 1);
  cs[i]++;
  return (String.fromCharCodes(cs), 0);
}
