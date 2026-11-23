// Ported from Lua 5.2.3 ldblib.c and `findlocal` of ldebug.c (MIT, see
// LICENSE-lua). Hooks are not supported, and `sethook` does nothing.

import '../debug.dart';
import '../state.dart';
import '../table.dart';
import '../value.dart';

/// `findlocal`. Returns the name and the stack index of local [n] of the
/// frame at [ciIdx].
(String, int)? _findLocal(LuaThread th, int ciIdx, int n) {
  final ci = th.cis[ciIdx];
  String? name;
  int base;
  if (ci.isLua) {
    if (n < 0) {
      final nparams = ci.cl!.p.numParams;
      if (n >= ci.base - ci.func - nparams) return null;
      return ('(*vararg)', ci.func + nparams + (-n));
    }
    base = ci.base;
    name = ci.cl!.p.localName(n, ci.savedPc - 1);
  } else {
    base = ci.func + 1;
  }
  if (name == null) {
    final limit = ciIdx == th.ciIndex ? th.top : th.cis[ciIdx + 1].func;
    if (limit - base >= n && n > 0) {
      name = '(*temporary)';
    } else {
      return null;
    }
  }
  return (name, base + (n - 1));
}

/// The thread and the index of the first argument of a function with an
/// optional thread argument.
(LuaThread, int) _thread(LuaThread L) {
  final t = L.arg(1);
  if (t is LuaThread) return (t, 1);
  return (L, 0);
}

int _getinfo(LuaThread L) {
  final (th, arg) = _thread(L);
  final options = L.optString(arg + 2, 'flnStu')!;
  for (final c in options.codeUnits) {
    if (!'SlnutfL'.codeUnits.contains(c)) L.argError(arg + 2, 'invalid option');
  }
  LuaDebugInfo? ar;
  final target = L.arg(arg + 1);
  if (target is double ||
      (target is String && double.tryParse(target) != null)) {
    ar = getStackInfo(th, L.checkInt(arg + 1));
    if (ar == null) {
      L.push(null);
      return 1;
    }
  } else if (target is LuaFunction) {
    ar = getFunctionInfo(target);
  } else {
    L.argError(arg + 1, 'function or level expected');
  }
  final t = LuaTable(0, 2);
  if (options.contains('S')) {
    t
      ..set('source', ar.source)
      ..set('short_src', ar.shortSrc)
      ..set('linedefined', ar.lineDefined.toDouble())
      ..set('lastlinedefined', ar.lastLineDefined.toDouble())
      ..set('what', ar.what);
  }
  if (options.contains('l')) t.set('currentline', ar.currentLine.toDouble());
  if (options.contains('u')) {
    t
      ..set('nups', ar.nups.toDouble())
      ..set('nparams', ar.nparams.toDouble())
      ..set('isvararg', ar.isVararg);
  }
  if (options.contains('n')) {
    t
      ..set('name', ar.name)
      ..set('namewhat', ar.nameWhat);
  }
  if (options.contains('t')) t.set('istailcall', ar.isTailCall);
  if (options.contains('L')) {
    final f = ar.func;
    if (f is LuaClosure) {
      final lines = LuaTable();
      for (final l in f.p.lineInfo) {
        lines.set(l.toDouble(), true);
      }
      t.set('activelines', lines);
    } else {
      t.set('activelines', null);
    }
  }
  if (options.contains('f')) t.set('func', ar.func);
  L.push(t);
  return 1;
}

int _getlocal(LuaThread L) {
  final (th, arg) = _thread(L);
  final n = L.checkInt(arg + 2);
  final f = L.arg(arg + 1);
  if (f is LuaFunction) {
    L.push(f is LuaClosure ? f.p.localName(n, 0) : null);
    return 1;
  }
  final level = L.checkInt(arg + 1);
  final idx = th.ciIndex - level;
  if (level < 0 || idx <= 0) L.argError(arg + 1, 'level out of range');
  final r = _findLocal(th, idx, n);
  if (r == null) {
    L.push(null);
    return 1;
  }
  L.push(r.$1);
  L.push(th.stack[r.$2]);
  return 2;
}

int _setlocal(LuaThread L) {
  final (th, arg) = _thread(L);
  final level = L.checkInt(arg + 1);
  final idx = th.ciIndex - level;
  if (level < 0 || idx <= 0) L.argError(arg + 1, 'level out of range');
  L.checkAny(arg + 3);
  L.setTop(arg + 3);
  final r = _findLocal(th, idx, L.checkInt(arg + 2));
  if (r != null) th.stack[r.$2] = L.arg(arg + 3);
  L.push(r?.$1);
  return 1;
}

(String, UpVal)? _upvalue(Object? f, int n) {
  if (f is! LuaClosure) return null;
  if (!(1 <= n && n <= f.p.upvalues.length)) return null;
  return (f.p.upvalues[n - 1].name ?? '', f.upvals[n - 1]);
}

int _getupvalue(LuaThread L) {
  L.checkType(1, 'function');
  final r = _upvalue(L.arg(1), L.checkInt(2));
  if (r == null) return 0;
  L.push(r.$1);
  L.push(r.$2.v);
  return 2;
}

int _setupvalue(LuaThread L) {
  L.checkAny(3);
  L.checkType(1, 'function');
  final r = _upvalue(L.arg(1), L.checkInt(2));
  if (r == null) return 0;
  r.$2.v = L.arg(3);
  L.push(r.$1);
  return 1;
}

int _upvalueid(LuaThread L) {
  L.checkType(1, 'function');
  final n = L.checkInt(2);
  final r = _upvalue(L.arg(1), n);
  if (r == null) L.argError(2, 'invalid upvalue index');
  L.push(LuaUserdata(r.$2));
  return 1;
}

int _upvaluejoin(LuaThread L) {
  final f1 = L.arg(1);
  final n1 = L.checkInt(2);
  final f2 = L.arg(3);
  final n2 = L.checkInt(4);
  if (f1 is! LuaClosure) L.argError(1, 'Lua function expected');
  if (f2 is! LuaClosure) L.argError(3, 'Lua function expected');
  if (_upvalue(f1, n1) == null) L.argError(2, 'invalid upvalue index');
  if (_upvalue(f2, n2) == null) L.argError(4, 'invalid upvalue index');
  f1.upvals[n1 - 1] = f2.upvals[n2 - 1];
  return 0;
}

int _traceback(LuaThread L) {
  final (th, arg) = _thread(L);
  final msg = L.arg(arg + 1);
  if (msg != null && msg is! String && msg is! double) {
    L.pushValue(arg + 1);
    return 1;
  }
  final level = L.optInt(arg + 2, identical(L, th) ? 1 : 0);
  L.push(traceback(th, msg == null ? null : L.toStr(arg + 1), level));
  return 1;
}

/// `luaopen_debug` into [t] in the order of `dblib`.
LuaTable openDebug(LuaTable t) {
  for (final (name, f) in <(String, LuaCFunction)>[
    ('debug', (L) => 0),
    (
      'getuservalue',
      (L) {
        final u = L.arg(1);
        L.push(u is LuaUserdata ? u.userValue : null);
        return 1;
      },
    ),
    (
      'gethook',
      (L) {
        L.push(null);
        L.push('');
        L.push(0.0);
        return 3;
      },
    ),
    ('getinfo', _getinfo),
    ('getlocal', _getlocal),
    (
      'getregistry',
      (L) {
        L.push(L.vm.registry);
        return 1;
      },
    ),
    (
      'getmetatable',
      (L) {
        L.checkAny(1);
        L.push(L.vm.metatableOf(L.arg(1)));
        return 1;
      },
    ),
    ('getupvalue', _getupvalue),
    ('upvaluejoin', _upvaluejoin),
    ('upvalueid', _upvalueid),
    (
      'setuservalue',
      (L) {
        final u = L.arg(1);
        if (u is! LuaUserdata) L.typeErrorArg(1, 'userdata');
        final v = L.arg(2);
        if (v != null && v is! LuaTable) L.typeErrorArg(2, 'table');
        u.userValue = v;
        L.setTop(1);
        return 1;
      },
    ),
    ('sethook', (L) => 0),
    ('setlocal', _setlocal),
    (
      'setmetatable',
      (L) {
        final v = L.arg(1);
        final mt = L.arg(2);
        if (mt != null && mt is! LuaTable) {
          L.argError(2, 'nil or table expected');
        }
        switch (v) {
          case LuaTable t:
            t.metatable = mt as LuaTable?;
          case LuaUserdata u:
            u.metatable = mt as LuaTable?;
          default:
            if (mt == null) {
              L.vm.typeMetatables.remove(luaTypeName(v));
            } else {
              L.vm.typeMetatables[luaTypeName(v)] = mt as LuaTable;
            }
        }
        L.setTop(2);
        L.push(true);
        return 1;
      },
    ),
    ('setupvalue', _setupvalue),
    ('traceback', _traceback),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  return t;
}
