// Ported from Lua 5.2.3 lbaselib.c (MIT; see LICENSE-lua).

import 'dart:typed_data';

import '../number.dart';
import '../proto.dart';
import '../state.dart';
import '../table.dart';
import '../value.dart';
import '../vm.dart' show isFalse;

int _print(LuaThread L) {
  final n = L.getTop();
  L.getGlobal('tostring');
  final tostring = L.arg(-1);
  L.pop();
  final sb = StringBuffer();
  for (var i = 1; i <= n; i++) {
    L.push(tostring);
    L.pushValue(i);
    L.call(1, 1);
    final s = L.toStr(-1);
    if (s == null) L.luaError("'tostring' must return a string to 'print'");
    if (i > 1) sb.write('\t');
    sb.write(s);
    L.pop();
  }
  sb.write('\n');
  L.vm.host.write(sb.toString());
  return 0;
}

bool _isSpaceChar(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D);
bool _isAlnum(int c) =>
    (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A);

int _tonumber(LuaThread L) {
  if (L.arg(2) == null) {
    final n = L.toNumber(1);
    if (n != null) {
      L.push(n);
      return 1;
    }
    L.checkAny(1);
  } else {
    final s = L.checkString(1);
    final base = L.checkInt(2);
    if (!(2 <= base && base <= 36)) L.argError(2, 'base out of range');
    final mode = L.vm.numberMode;
    var i = 0;
    while (i < s.length && _isSpaceChar(s.codeUnitAt(i))) {
      i++;
    }
    var neg = false;
    if (i < s.length && s.codeUnitAt(i) == 0x2D) {
      i++;
      neg = true;
    } else if (i < s.length && s.codeUnitAt(i) == 0x2B) {
      i++;
    }
    if (i < s.length && _isAlnum(s.codeUnitAt(i))) {
      var n = 0.0;
      do {
        final c = s.codeUnitAt(i);
        final digit = c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10;
        if (digit >= base) break;
        n = baseStep(n, base, digit, mode);
        i++;
      } while (i < s.length && _isAlnum(s.codeUnitAt(i)));
      while (i < s.length && _isSpaceChar(s.codeUnitAt(i))) {
        i++;
      }
      if (i == s.length) {
        L.push(neg ? -n : n);
        return 1;
      }
    }
  }
  L.push(null);
  return 1;
}

int _error(LuaThread L) {
  final level = L.optInt(2, 1);
  L.setTop(1);
  final v = L.arg(1);
  if ((v is String || v is double) && level > 0) {
    L.set(1, '${L.where(level)}${L.toStr(1)}');
  }
  return L.error();
}

int _getmetatable(LuaThread L) {
  L.checkAny(1);
  final mt = L.vm.metatableOf(L.arg(1));
  if (mt == null) {
    L.push(null);
    return 1;
  }
  final protected = mt.get('__metatable');
  L.push(protected ?? mt);
  return 1;
}

int _setmetatable(LuaThread L) {
  final t = L.arg(2);
  L.checkType(1, 'table');
  if (!(t == null || t is LuaTable)) L.argError(2, 'nil or table expected');
  if (L.getMetaField(1, '__metatable') != null) {
    L.luaError('cannot change a protected metatable');
  }
  L.setTop(2);
  (L.arg(1) as LuaTable).metatable = t as LuaTable?;
  L.setTop(1);
  return 1;
}

int _rawequal(LuaThread L) {
  L.checkAny(1);
  L.checkAny(2);
  L.push(luaRawEquals(L.arg(1), L.arg(2)));
  return 1;
}

int _rawlen(LuaThread L) {
  final v = L.arg(1);
  if (v is LuaTable) {
    L.push(v.length().toDouble());
  } else if (v is String) {
    L.push(v.length.toDouble());
  } else {
    L.argError(1, 'table or string expected');
  }
  return 1;
}

int _rawget(LuaThread L) {
  L.checkType(1, 'table');
  L.checkAny(2);
  L.setTop(2);
  L.push((L.arg(1) as LuaTable).get(L.arg(2)));
  return 1;
}

int _rawset(LuaThread L) {
  L.checkType(1, 'table');
  L.checkAny(2);
  L.checkAny(3);
  L.setTop(3);
  final key = L.arg(2);
  if (key == null) L.runError('table index is nil');
  if (key is double && key.isNaN) L.runError('table index is NaN');
  (L.arg(1) as LuaTable).set(key, L.arg(3));
  L.setTop(1);
  return 1;
}

const _gcOptions = [
  'stop', 'restart', 'collect', 'count', 'step', 'setpause', 'setstepmul',
  'setmajorinc', 'isrunning', 'generational', 'incremental', //
];

/// Memory is Dart's: no GC introspection (a ruling).
int _collectgarbage(LuaThread L) {
  final o = _gcOptions[L.checkOption(1, 'collect', _gcOptions)];
  L.optInt(2, 0);
  switch (o) {
    case 'count':
      L.push(0.0);
      L.push(0.0);
      return 2;
    case 'step':
      L.push(false);
      return 1;
    case 'isrunning':
      L.push(true);
      return 1;
    case 'setpause':
    case 'setstepmul':
      L.push(200.0);
      return 1;
    default:
      L.push(0.0);
      return 1;
  }
}

int _type(LuaThread L) {
  L.checkAny(1);
  L.push(luaTypeName(L.arg(1)));
  return 1;
}

int _next(LuaThread L) {
  L.checkType(1, 'table');
  L.setTop(2);
  if (!(L.arg(1) as LuaTable).nextInto(L.arg(2))) {
    L.push(null);
    return 1;
  }
  // Out of the statics at once; cleared so they hold no value alive.
  final k = LuaTable.nextKey, v = LuaTable.nextValue;
  LuaTable.nextKey = LuaTable.nextValue = null;
  L.push(k);
  L.push(v);
  return 2;
}

final _nextNative = LuaNative(_next, 'next');

/// The natives shared by every Lua state (made once per process), by name
/// (a snapshot names them so).
Map<String, LuaNative> get luaSharedNatives => {
  'next': _nextNative,
  'ipairs_aux': _ipairsAuxNative,
};

int _pairsMeta(LuaThread L, String method, bool isZero, LuaNative iter) {
  final mm = L.getMetaField(1, method);
  if (mm == null) {
    L.checkType(1, 'table');
    L.push(iter);
    L.pushValue(1);
    L.push(isZero ? 0.0 : null);
  } else {
    L.push(mm);
    L.pushValue(1);
    L.call(1, 3);
  }
  return 3;
}

int _pairs(LuaThread L) => _pairsMeta(L, '__pairs', false, _nextNative);

int _ipairsAux(LuaThread L) {
  final i = L.checkInt(2) + 1;
  L.checkType(1, 'table');
  L.push(i.toDouble());
  final v = (L.arg(1) as LuaTable).getInt(i);
  L.push(v);
  return v == null ? 1 : 2;
}

final _ipairsAuxNative = LuaNative(_ipairsAux, 'ipairs_aux');

int _ipairs(LuaThread L) => _pairsMeta(L, '__ipairs', true, _ipairsAuxNative);

/// `load_aux`.
int _loadAux(LuaThread L, LuaClosure? f, String? err, int envIdx) {
  if (f != null) {
    if (envIdx != 0 && f.upvals.isNotEmpty) f.upvals[0].v = L.arg(envIdx);
    L.push(f);
    return 1;
  }
  L.push(null);
  L.push(err);
  return 2;
}

/// `luaD_protectedparser` from Dart: a loaded function, or the error text.
(LuaClosure?, String?) loadBytes(
  LuaThread L,
  Uint8List chunk,
  String name,
  String? mode,
) {
  final binary = chunk.isNotEmpty && chunk[0] == 0x1B;
  final kind = binary ? 'binary' : 'text';
  if (mode != null && !mode.contains(kind[0])) {
    return (null, "attempt to load a $kind chunk (mode is '$mode')");
  }
  try {
    return (L.vm.load(chunk, name), null);
  } on LuaLoadError catch (e) {
    return (null, e.message);
  }
}

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

int _load(LuaThread L) {
  final s = L.toStr(1);
  final mode = L.optString(3, 'bt');
  final env = L.isNone(4) ? 0 : 4;
  String chunk;
  String name;
  if (s != null) {
    chunk = s;
    name = L.optString(2, s)!;
  } else {
    name = L.optString(2, '=(load)')!;
    L.checkType(1, 'function');
    final sb = StringBuffer();
    while (true) {
      L.pushValue(1);
      L.call(0, 1);
      final piece = L.arg(-1);
      if (piece == null) {
        L.pop();
        break;
      }
      if (piece is! String && piece is! double) {
        L.luaError('reader function must return a string');
      }
      final str = L.toStr(-1)!;
      L.pop();
      if (str.isEmpty) break;
      sb.write(str);
    }
    chunk = sb.toString();
  }
  final (f, err) = loadBytes(L, _bytes(chunk), name, mode);
  return _loadAux(L, f, err, env);
}

/// Stock `loadfile`/`dofile` read through the host as files; the exe reads
/// resources (its replacements: see formats/telltale/lua-runtime.md,
/// "Environment patches at boot"; the messages are [INF]).
(LuaClosure?, String?) _loadFile(LuaThread L, String? fname, String? mode) {
  if (fname == null) return (null, 'cannot read stdin');
  final bytes = L.vm.host.readResource(fname);
  if (bytes == null) {
    return (null, L.vm.config.missingFileText(fname));
  }
  return loadBytes(L, bytes, '@$fname', mode);
}

int _loadfile(LuaThread L) {
  final fname = L.optString(1, null);
  final mode = L.optString(2, null);
  final env = L.isNone(3) ? 0 : 3;
  final (f, err) = _loadFile(L, fname, mode);
  return _loadAux(L, f, err, env);
}

int _dofile(LuaThread L) {
  final fname = L.optString(1, null);
  L.setTop(1);
  final (f, err) = _loadFile(L, fname, null);
  if (f == null) {
    L.push(err);
    return L.error();
  }
  L.push(f);
  L.call(0, luaMultRet);
  return L.getTop() - 1;
}

int _assert(LuaThread L) {
  if (isFalse(L.arg(1))) L.luaError(L.optString(2, 'assertion failed!')!);
  return L.getTop();
}

int _select(LuaThread L) {
  final n = L.getTop();
  final first = L.arg(1);
  if (first is String && first.startsWith('#')) {
    L.push((n - 1).toDouble());
    return 1;
  }
  var i = L.checkInt(1);
  if (i < 0) {
    i = n + i;
  } else if (i > n) {
    i = n;
  }
  if (!(1 <= i)) L.argError(1, 'index out of range');
  return n - i;
}

int _finishPcall(LuaThread L, bool ok) {
  L.push(ok);
  L.replace(1);
  return L.getTop();
}

int _pcall(LuaThread L) {
  L.checkAny(1);
  L.push(null);
  L.insert(1);
  final status = L.pcall(L.getTop() - 2, luaMultRet, 0);
  return _finishPcall(L, status == luaOk);
}

int _xpcall(LuaThread L) {
  final n = L.getTop();
  if (n < 2) L.argError(2, 'value expected');
  L.pushValue(1);
  L.copy(2, 1);
  L.replace(2);
  final status = L.pcall(n - 2, luaMultRet, 1);
  return _finishPcall(L, status == luaOk);
}

int _tostring(LuaThread L) {
  L.checkAny(1);
  L.toLString(1);
  return 1;
}

/// `luaopen_base` into the globals, then the profile's overrides.
void openBase(LuaVm vm) {
  final g = vm.globals;
  g.set('_G', g);
  final funcs = <(String, LuaCFunction)>[
    ('assert', _assert),
    ('collectgarbage', _collectgarbage),
    ('dofile', _dofile),
    ('error', _error),
    ('getmetatable', _getmetatable),
    ('ipairs', _ipairs),
    ('loadfile', _loadfile),
    ('load', _load),
    ('next', _next),
    ('pairs', _pairs),
    ('pcall', _pcall),
    ('print', _print),
    ('rawequal', _rawequal),
    ('rawlen', _rawlen),
    ('rawget', _rawget),
    ('rawset', _rawset),
    ('select', _select),
    ('setmetatable', _setmetatable),
    ('tonumber', _tonumber),
    ('tostring', _tostring),
    ('type', _type),
    ('xpcall', _xpcall),
  ];
  for (final (name, f) in funcs) {
    g.set(name, name == 'next' ? _nextNative : LuaNative(f, name));
  }
  g.set('_VERSION', 'Lua 5.2');
}
