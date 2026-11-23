// Ported from Lua 5.2.3 lcorolib.c (MIT; see LICENSE-lua).

import '../state.dart';
import '../table.dart';

/// `auxresume`: resumes [co] with the [narg] top values of [L]; returns the
/// number of results moved to [L], or -1 with the error message on top.
int _auxResume(LuaThread L, LuaThread co, int narg) {
  if (co.status == luaOk && co.top - (co.ci.func + 1) == 0) {
    L.push('cannot resume dead coroutine');
    return -1;
  }
  co.checkStack(narg);
  for (var i = narg; i > 0; i--) {
    co.stack[co.top++] = L.arg(-i);
  }
  L.pop(narg);
  final status = co.resumeRaw(L, narg);
  if (status == luaOk || status == luaYield) {
    final nres = co.top - (co.ci.func + 1);
    for (var i = nres; i > 0; i--) {
      L.push(co.stack[co.top - i]);
    }
    co.top -= nres;
    return nres;
  }
  L.push(co.stack[--co.top]);
  return -1;
}

LuaThread _toThread(LuaThread L, int i) {
  final v = L.arg(i);
  return v is LuaThread ? v : L.argError(i, 'coroutine expected');
}

int _resume(LuaThread L) {
  final co = _toThread(L, 1);
  final r = _auxResume(L, co, L.getTop() - 1);
  if (r < 0) {
    L.push(false);
    L.insert(-2);
    return 2;
  }
  L.push(true);
  L.insert(-(r + 1));
  return r + 1;
}

int _create(LuaThread L) {
  L.checkType(1, 'function');
  L.push(L.vm.newThread(L.arg(1)));
  return 1;
}

int _wrap(LuaThread L) {
  _create(L);
  final co = L.arg(-1) as LuaThread;
  L.pop();
  L.push(
    LuaNative((L) {
      final r = _auxResume(L, co, L.getTop());
      if (r < 0) {
        final e = L.arg(-1);
        if (e is String || e is double) {
          L.set(-1, '${L.where(1)}${L.toStr(-1)}');
        }
        return L.error();
      }
      return r;
    }, 'wrap'),
  );
  return 1;
}

int _yield(LuaThread L) => L.yield(L.getTop());

int _status(LuaThread L) {
  L.push(_toThread(L, 1).statusFrom(L));
  return 1;
}

int _running(LuaThread L) {
  L.push(L);
  L.push(identical(L, L.vm.mainThread));
  return 2;
}

/// The `coroutine` library table.
LuaTable coroutineLibrary() {
  final t = LuaTable(0, 6);
  for (final (name, f) in [
    ('create', _create),
    ('resume', _resume),
    ('running', _running),
    ('status', _status),
    ('wrap', _wrap),
    ('yield', _yield),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  return t;
}
