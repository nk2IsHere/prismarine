// Ported from Lua 5.2.3 ltablib.c (MIT, see LICENSE-lua).

import '../state.dart';
import '../table.dart';
import '../value.dart';
import '../vm.dart' show isFalse, lessThan;

int _auxGetN(LuaThread L, int n) {
  L.checkType(n, 'table');
  return L.lenOf(n);
}

int _insert(LuaThread L) {
  final e = _auxGetN(L, 1) + 1;
  int pos;
  switch (L.getTop()) {
    case 2:
      pos = e;
    case 3:
      pos = L.checkInt(2);
      if (!(1 <= pos && pos <= e)) L.argError(2, 'position out of bounds');
      for (var i = e; i > pos; i--) {
        L.rawGetI(1, i - 1);
        L.rawSetI(1, i);
      }
    default:
      L.luaError("wrong number of arguments to 'insert'");
  }
  L.rawSetI(1, pos);
  return 0;
}

int _remove(LuaThread L) {
  final size = _auxGetN(L, 1);
  var pos = L.optInt(2, size);
  if (pos != size && !(1 <= pos && pos <= size + 1)) {
    L.argError(1, 'position out of bounds');
  }
  L.rawGetI(1, pos);
  for (; pos < size; pos++) {
    L.rawGetI(1, pos + 1);
    L.rawSetI(1, pos);
  }
  L.push(null);
  L.rawSetI(1, pos);
  return 1;
}

void _addField(LuaThread L, StringBuffer b, int i) {
  L.rawGetI(1, i);
  final v = L.arg(-1);
  if (v is! String && v is! double) {
    L.luaError(
      "invalid value (${luaTypeName(v)}) at index $i in table for 'concat'",
    );
  }
  b.write(L.toStr(-1));
  L.pop();
}

int _concat(LuaThread L) {
  final sep = L.optString(2, '')!;
  L.checkType(1, 'table');
  var i = L.optInt(3, 1);
  final last = L.arg(4) == null ? L.lenOf(1) : L.checkInt(4);
  final b = StringBuffer();
  for (; i < last; i++) {
    _addField(L, b, i);
    b.write(sep);
  }
  if (i == last) _addField(L, b, i);
  L.push(b.toString());
  return 1;
}

int _pack(LuaThread L) {
  final n = L.getTop();
  final t = LuaTable(n, 1);
  L.push(t);
  t.set('n', n.toDouble());
  if (n > 0) {
    L.pushValue(1);
    L.rawSetI(-2, 1);
    L.replace(1);
    for (var i = n; i >= 2; i--) {
      L.rawSetI(1, i);
    }
  }
  return 1;
}

int _unpack(LuaThread L) {
  L.checkType(1, 'table');
  var i = L.optInt(2, 1);
  final e = L.arg(3) == null ? L.lenOf(1) : L.checkInt(3);
  if (i > e) return 0;
  final n = e - i + 1;
  if (n <= 0 || n >= luaMaxStack - L.top) {
    L.luaError('too many results to unpack');
  }
  L.checkStack(n);
  L.rawGetI(1, i);
  while (i++ < e) {
    L.rawGetI(1, i);
  }
  return n;
}

void _set2(LuaThread L, int i, int j) {
  L.rawSetI(1, i);
  L.rawSetI(1, j);
}

bool _sortComp(LuaThread L, int a, int b) {
  if (L.arg(2) != null) {
    L.pushValue(2);
    L.pushValue(a - 1);
    L.pushValue(b - 2);
    L.call(2, 1);
    final res = !isFalse(L.arg(-1));
    L.pop();
    return res;
  }
  return lessThan(L, L.arg(a), L.arg(b));
}

void _auxSort(LuaThread L, int l, int u) {
  while (l < u) {
    L.rawGetI(1, l);
    L.rawGetI(1, u);
    if (_sortComp(L, -1, -2)) {
      _set2(L, l, u);
    } else {
      L.pop(2);
    }
    if (u - l == 1) break;
    var i = (l + u) ~/ 2;
    L.rawGetI(1, i);
    L.rawGetI(1, l);
    if (_sortComp(L, -2, -1)) {
      _set2(L, i, l);
    } else {
      L.pop();
      L.rawGetI(1, u);
      if (_sortComp(L, -1, -2)) {
        _set2(L, i, u);
      } else {
        L.pop(2);
      }
    }
    if (u - l == 2) break;
    L.rawGetI(1, i);
    L.pushValue(-1);
    L.rawGetI(1, u - 1);
    _set2(L, i, u - 1);
    i = l;
    var j = u - 1;
    for (;;) {
      while (true) {
        L.rawGetI(1, ++i);
        if (!_sortComp(L, -1, -2)) break;
        if (i >= u) L.luaError('invalid order function for sorting');
        L.pop();
      }
      while (true) {
        L.rawGetI(1, --j);
        if (!_sortComp(L, -3, -1)) break;
        if (j <= l) L.luaError('invalid order function for sorting');
        L.pop();
      }
      if (j < i) {
        L.pop(3);
        break;
      }
      _set2(L, i, j);
    }
    L.rawGetI(1, u - 1);
    L.rawGetI(1, i);
    _set2(L, u - 1, i);
    if (i - l < u - i) {
      j = l;
      i = i - 1;
      l = i + 2;
    } else {
      j = i + 1;
      i = u;
      u = j - 2;
    }
    _auxSort(L, j, i);
  }
}

int _sort(LuaThread L) {
  final n = _auxGetN(L, 1);
  L.checkStack(40);
  if (L.arg(2) != null) L.checkType(2, 'function');
  L.setTop(2);
  _auxSort(L, 1, n);
  return 0;
}

/// `luaopen_table` into [t] in the order of `tab_funcs`.
LuaTable openTable(LuaTable t) {
  for (final (name, f) in <(String, LuaCFunction)>[
    ('concat', _concat),
    ('insert', _insert),
    ('pack', _pack),
    ('unpack', _unpack),
    ('remove', _remove),
    ('sort', _sort),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  return t;
}
