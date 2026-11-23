// Ported from Lua 5.2.3 lstrlib.c (MIT; see LICENSE-lua). `format` follows C
// printf in the VM's C runtime.

import 'dart:typed_data';

import '../codec.dart';
import '../number.dart';
import '../runtime.dart';
import '../state.dart';
import '../table.dart';
import '../value.dart';
import '../vm.dart' show isFalse;
import 'lpattern.dart';

int _posrelat(int pos, int len) {
  if (pos >= 0) return pos;
  if (-pos > len) return 0;
  return len + pos + 1;
}

int _len(LuaThread L) {
  L.push(L.checkString(1).length.toDouble());
  return 1;
}

int _sub(LuaThread L) {
  final s = L.checkString(1);
  final l = s.length;
  var start = _posrelat(L.checkInteger(2), l);
  var end = _posrelat(L.optInteger(3, -1), l);
  if (start < 1) start = 1;
  if (end > l) end = l;
  L.push(start <= end ? s.substring(start - 1, end) : '');
  return 1;
}

int _reverse(LuaThread L) {
  final s = L.checkString(1);
  L.push(String.fromCharCodes(s.codeUnits.reversed));
  return 1;
}

int _lower(LuaThread L) {
  L.push(String.fromCharCodes(L.checkString(1).codeUnits.map(cToLower)));
  return 1;
}

int _upper(LuaThread L) {
  L.push(String.fromCharCodes(L.checkString(1).codeUnits.map(cToUpper)));
  return 1;
}

int _rep(LuaThread L) {
  final s = L.checkString(1);
  final n = L.checkInt(2);
  final sep = L.optString(3, '')!;
  final maxSize = L.vm.runtime.sizeMax;
  if (n <= 0) {
    L.push('');
  } else if (s.length + sep.length >= maxSize ~/ n) {
    L.luaError('resulting string too large');
  } else {
    final sb = StringBuffer();
    for (var i = n; i > 1; i--) {
      sb
        ..write(s)
        ..write(sep);
    }
    sb.write(s);
    L.push(sb.toString());
  }
  return 1;
}

int _byte(LuaThread L) {
  final s = L.checkString(1);
  final l = s.length;
  var posi = _posrelat(L.optInteger(2, 1), l);
  var pose = _posrelat(L.optInteger(3, posi), l);
  if (posi < 1) posi = 1;
  if (pose > l) pose = l;
  if (posi > pose) return 0;
  final n = pose - posi + 1;
  L.checkStack(n);
  for (var i = 0; i < n; i++) {
    L.push(s.codeUnitAt(posi + i - 1).toDouble());
  }
  return n;
}

int _char(LuaThread L) {
  final n = L.getTop();
  final codes = <int>[];
  for (var i = 1; i <= n; i++) {
    final c = L.checkInt(i);
    if ((c & 0xFF) != c) L.argError(i, 'value out of range');
    codes.add(c);
  }
  L.push(String.fromCharCodes(codes));
  return 1;
}

int _dump(LuaThread L) {
  L.checkType(1, 'function');
  L.setTop(1);
  final f = L.arg(1);
  if (f is! LuaClosure) L.luaError('unable to dump given function');
  L.push(
    String.fromCharCodes(
      dumpLua(f.p, sizeT: L.vm.config.chunkSizeT, float32: L.vm.float32),
    ),
  );
  return 1;
}

bool _noSpecials(String p) {
  for (final c in p.codeUnits) {
    if (specials.codeUnits.contains(c)) return false;
  }
  return true;
}

int _findAux(LuaThread L, bool find) {
  final s = L.checkString(1);
  final p = L.checkString(2);
  final ls = s.length;
  var init = _posrelat(L.optInteger(3, 1), ls);
  if (init < 1) {
    init = 1;
  } else if (init > ls + 1) {
    L.push(null);
    return 1;
  }
  if (find && (!isFalse(L.arg(4)) || _noSpecials(p))) {
    final at = s.indexOf(p, init - 1);
    if (at >= 0) {
      L.push((at + 1).toDouble());
      L.push((at + p.length).toDouble());
      return 2;
    }
  } else {
    final anchor = p.isNotEmpty && p.codeUnitAt(0) == 0x5E;
    final ms = MatchState(L, s, anchor ? p.substring(1) : p);
    var s1 = init - 1;
    do {
      ms.level = 0;
      final res = ms.match(s1, 0);
      if (res != -1) {
        if (find) {
          L.push((s1 + 1).toDouble());
          L.push(res.toDouble());
          return ms.pushCaptures(-1, 0) + 2;
        }
        return ms.pushCaptures(s1, res);
      }
    } while (s1++ < ms.srcEnd && !anchor);
  }
  L.push(null);
  return 1;
}

int _find(LuaThread L) => _findAux(L, true);
int _match(LuaThread L) => _findAux(L, false);

int _gmatch(LuaThread L) {
  final s = L.checkString(1);
  final p = L.checkString(2);
  L.setTop(2);
  var pos = 0;
  L.push(
    LuaNative((L) {
      final ms = MatchState(L, s, p);
      for (var src = pos; src <= ms.srcEnd; src++) {
        ms.level = 0;
        final e = ms.match(src, 0);
        if (e != -1) {
          var newStart = e;
          if (e == src) newStart++;
          pos = newStart;
          return ms.pushCaptures(src, e);
        }
      }
      return 0;
    }, 'gmatch_aux'),
  );
  return 1;
}

void _addS(MatchState ms, StringBuffer b, int s0, int e, String news) {
  final L = ms.L;
  final l = news.length;
  for (var i = 0; i < l; i++) {
    final c = news.codeUnitAt(i);
    if (c != 0x25) {
      b.writeCharCode(c);
    } else {
      i++;
      final d = i < l ? news.codeUnitAt(i) : 0;
      if (!cIsDigit(d)) {
        if (d != 0x25) L.luaError("invalid use of '%' in replacement string");
        b.writeCharCode(d);
      } else if (d == 0x30) {
        b.write(ms.src.substring(s0, e));
      } else {
        final v = ms.capture(d - 0x31, s0, e);
        b.write(v is double ? L.vm.runtime.numberToString(v) : v as String);
      }
    }
  }
}

void _addValue(MatchState ms, StringBuffer b, int s0, int e, Object? repl) {
  final L = ms.L;
  if (repl is LuaFunction) {
    L.push(repl);
    final n = ms.pushCaptures(s0, e);
    L.call(n, 1);
  } else if (repl is LuaTable) {
    L.push(ms.capture(0, s0, e));
    L.getTableAt(3);
  } else {
    _addS(ms, b, s0, e, L.toStr(3)!);
    return;
  }
  final v = L.arg(-1);
  if (isFalse(v)) {
    L.pop();
    b.write(ms.src.substring(s0, e));
    return;
  }
  if (v is! String && v is! double) {
    L.luaError('invalid replacement value (a ${luaTypeName(v)})');
  }
  b.write(L.toStr(-1));
  L.pop();
}

int _gsub(LuaThread L) {
  final src = L.checkString(1);
  var p = L.checkString(2);
  final tr = L.arg(3);
  final maxS = L.optInteger(4, src.length + 1);
  final anchor = p.isNotEmpty && p.codeUnitAt(0) == 0x5E;
  if (!(tr is double || tr is String || tr is LuaFunction || tr is LuaTable)) {
    L.argError(3, 'string/function/table expected');
  }
  if (anchor) p = p.substring(1);
  final ms = MatchState(L, src, p);
  final b = StringBuffer();
  var s = 0;
  var n = 0;
  while (n < maxS) {
    ms.level = 0;
    final e = ms.match(s, 0);
    if (e != -1) {
      n++;
      _addValue(ms, b, s, e, tr);
    }
    if (e != -1 && e > s) {
      s = e;
    } else if (s < ms.srcEnd) {
      b.writeCharCode(src.codeUnitAt(s++));
    } else {
      break;
    }
    if (anchor) break;
  }
  b.write(src.substring(s));
  L.push(b.toString());
  L.push(n.toDouble());
  return 2;
}

// --- format -------------------------------------------------------------------

const _flags = '-+ #0';

String _pad(
  String body,
  int width,
  bool left, {
  String sign = '',
  String zeros = '',
}) {
  final len = sign.length + body.length;
  if (width <= len) return sign + body;
  if (left) return '$sign$body${' ' * (width - len)}';
  if (zeros.isNotEmpty) return '$sign${'0' * (width - len)}$body';
  return '${' ' * (width - len)}$sign$body';
}

class _Spec {
  final flags = <int>{};
  int width = -1;
  int precision = -1;
  bool has(String f) => flags.contains(f.codeUnitAt(0));
}

String _fmtInteger(_Spec sp, String digits, bool neg, int conv, bool isZero) {
  var d = digits;
  if (sp.precision >= 0) {
    if (sp.precision == 0 && isZero) d = '';
    if (d.length < sp.precision) d = '0' * (sp.precision - d.length) + d;
  }
  var prefix = '';
  if (sp.has('#')) {
    if (conv == 0x6F && !d.startsWith('0')) d = '0$d';
    if ((conv == 0x78 || conv == 0x58) && !isZero) {
      prefix = conv == 0x78 ? '0x' : '0X';
    }
  }
  var sign = '';
  if (conv == 0x64 || conv == 0x69) {
    sign = neg
        ? '-'
        : sp.has('+')
        ? '+'
        : sp.has(' ')
        ? ' '
        : '';
  }
  final zeroPad = sp.has('0') && !sp.has('-') && sp.precision < 0;
  return _pad(
    d,
    sp.width,
    sp.has('-'),
    sign: sign + prefix,
    zeros: zeroPad ? '0' : '',
  );
}

String _fmtFloat(_Spec sp, double v, int conv, LuaCRuntime rt) {
  final prec = sp.precision < 0 ? (conv | 0x20 == 0x61 ? -1 : 6) : sp.precision;
  final upper = conv == 0x45 || conv == 0x47 || conv == 0x41;
  final alt = sp.has('#');
  var s = switch (conv) {
    0x65 || 0x45 => rt.formatE(v, prec, upper: upper, alt: alt),
    0x66 => rt.formatF(v, prec, alt: alt),
    0x61 || 0x41 => rt.formatA(v, prec, upper: upper, alt: alt)!,
    _ => rt.formatG(v, prec, upper: upper, alt: alt),
  };
  final pointed = conv | 0x20 == 0x65 || conv == 0x66;
  if (!v.isFinite && alt && prec == 0 && pointed) s = rt.pointNonFinite(s);
  var sign = '';
  if (s.startsWith('-')) {
    sign = '-';
    s = s.substring(1);
  } else if (sp.has('+')) {
    sign = '+';
  } else if (sp.has(' ')) {
    sign = ' ';
  }
  // Hex floats get their zeros after the 0x.
  final zeroPad =
      sp.has('0') && !sp.has('-') && (v.isFinite || rt.zeroPadsNonFinite);
  if (zeroPad && v.isFinite && conv | 0x20 == 0x61) {
    sign = '$sign${s.substring(0, 2)}';
    s = s.substring(2);
  }
  return _pad(s, sp.width, sp.has('-'), sign: sign, zeros: zeroPad ? '0' : '');
}

void _addQuoted(LuaThread L, StringBuffer b, int arg) {
  final s = L.checkString(arg);
  b.writeCharCode(0x22);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x22 || c == 0x5C || c == 0x0A) {
      b
        ..writeCharCode(0x5C)
        ..writeCharCode(c);
    } else if (c == 0 || cIsCntrl(c)) {
      final next = i + 1 < s.length ? s.codeUnitAt(i + 1) : 0;
      b.write(cIsDigit(next) ? '\\${c.toString().padLeft(3, '0')}' : '\\$c');
    } else {
      b.writeCharCode(c);
    }
  }
  b.writeCharCode(0x22);
}

int _format(LuaThread L) {
  final top = L.getTop();
  var arg = 1;
  final f = L.checkString(arg);
  final rt = L.vm.runtime;
  final float32 = L.vm.float32;
  final b = StringBuffer();
  var i = 0;
  int at(int k) => k < f.length ? f.codeUnitAt(k) : 0;
  while (i < f.length) {
    final c = f.codeUnitAt(i);
    if (c != 0x25) {
      b.writeCharCode(c);
      i++;
      continue;
    }
    i++;
    if (at(i) == 0x25) {
      b.writeCharCode(0x25);
      i++;
      continue;
    }
    if (++arg > top) L.argError(arg, 'no value');
    // scanformat
    final sp = _Spec();
    final start = i;
    while (at(i) != 0 && _flags.codeUnits.contains(at(i))) {
      sp.flags.add(at(i));
      i++;
    }
    if (i - start >= _flags.length + 1) {
      L.luaError('invalid format (repeated flags)');
    }
    var w = '';
    if (cIsDigit(at(i))) w += String.fromCharCode(at(i++));
    if (cIsDigit(at(i))) w += String.fromCharCode(at(i++));
    if (w.isNotEmpty) sp.width = int.parse(w);
    if (at(i) == 0x2E) {
      i++;
      var pr = '';
      if (cIsDigit(at(i))) pr += String.fromCharCode(at(i++));
      if (cIsDigit(at(i))) pr += String.fromCharCode(at(i++));
      sp.precision = pr.isEmpty ? 0 : int.parse(pr);
    }
    if (cIsDigit(at(i))) {
      L.luaError('invalid format (width or precision too long)');
    }
    final hasDot = f.substring(start, i).contains('.');
    final conv = at(i);
    i++;
    switch (conv) {
      case 0x63: // c
        final ch = String.fromCharCode(L.checkInteger(arg) & 0xFF);
        b.write(_pad(ch, sp.width, sp.has('-')));
      case 0x64 || 0x69: // d i
        final n = L.checkNumber(arg);
        final ni = rt.toLong(n);
        final diff = n - luaNumber(ni.toDouble(), float32);
        if (!(-1 < diff && diff < 1)) {
          L.argError(arg, 'not a number in proper range');
        }
        b.write(_fmtInteger(sp, ni.abs().toString(), ni < 0, conv, ni == 0));
      case 0x6F || 0x75 || 0x78 || 0x58: // o u x X
        final n = L.checkNumber(arg);
        final ni = rt.toULong(n);
        final diff = n - luaNumber(ni, float32);
        if (!(-1 < diff && diff < 1)) {
          L.argError(arg, 'not a non-negative number in proper range');
        }
        final big = BigInt.parse(ni.toStringAsFixed(0));
        final digits = switch (conv) {
          0x6F => big.toRadixString(8),
          0x75 => big.toString(),
          0x78 => big.toRadixString(16),
          _ => big.toRadixString(16).toUpperCase(),
        };
        b.write(_fmtInteger(sp, digits, false, conv, ni == 0));
      case 0x65 || 0x45 || 0x66 || 0x67 || 0x47: // e E f g G
        b.write(_fmtFloat(sp, L.checkNumber(arg), conv, rt));
      case 0x61 || 0x41 when rt.hexFloat: // a A (C99 builds)
        b.write(_fmtFloat(sp, L.checkNumber(arg), conv, rt));
      case 0x71: // q
        _addQuoted(L, b, arg);
      case 0x73: // s
        final s = L.toLString(arg) ?? '';
        if (!hasDot && s.length >= 100) {
          b.write(s);
        } else {
          // sprintf("%s") stops at the first NUL.
          final nul = s.indexOf('\u0000');
          final c = nul >= 0 ? s.substring(0, nul) : s;
          final t = sp.precision >= 0 && c.length > sp.precision
              ? c.substring(0, sp.precision)
              : c;
          b.write(_pad(t, sp.width, sp.has('-')));
        }
        L.pop();
      default:
        L.luaError(
          "invalid option '%${String.fromCharCode(conv)}' to 'format'",
        );
    }
  }
  L.push(b.toString());
  return 1;
}

/// `luaopen_string`: the library table (in `strlib` order) and the string
/// metatable (`__index` = the table).
LuaTable openString(LuaVm vm, LuaTable t) {
  for (final (name, f) in <(String, LuaCFunction)>[
    ('byte', _byte),
    ('char', _char),
    ('dump', _dump),
    ('find', _find),
    ('format', _format),
    ('gmatch', _gmatch),
    ('gsub', _gsub),
    ('len', _len),
    ('lower', _lower),
    ('match', _match),
    ('rep', _rep),
    ('reverse', _reverse),
    ('sub', _sub),
    ('upper', _upper),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  vm.typeMetatables['string'] = LuaTable(0, 1)..set('__index', t);
  return t;
}

/// Byte strings for natives that build chunks.
Uint8List stringBytes(String s) => Uint8List.fromList(s.codeUnits);
