// Ported from Lua 5.2.3 lbitlib.c (MIT, see LICENSE-lua). A result is a
// number of the VM's mode. In a float mode `bit32.bnot(0)` is 4294967296.

import '../state.dart';
import '../table.dart';

const _all = 0xFFFFFFFF;

int _mask(int n) => ~((_all << 1) << (n - 1)) & _all;

void _pushU(LuaThread L, int u) => L.push(L.number((u & _all).toDouble()));

int _andAux(LuaThread L) {
  final n = L.getTop();
  var r = _all;
  for (var i = 1; i <= n; i++) {
    r &= L.checkUnsigned(i);
  }
  return r & _all;
}

int _shift(LuaThread L, int r, int i) {
  if (i < 0) {
    i = -i;
    r &= _all;
    r = i >= 32 ? 0 : r >> i;
  } else {
    r = i >= 32 ? 0 : (r << i) & _all;
  }
  _pushU(L, r);
  return 1;
}

int _rot(LuaThread L, int i) {
  var r = L.checkUnsigned(1);
  i &= 31;
  r &= _all;
  if (i != 0) r = ((r << i) | (r >> (32 - i))) & _all;
  _pushU(L, r);
  return 1;
}

int _fieldArgs(LuaThread L, int farg, List<int> width) {
  final f = L.checkInt(farg);
  final w = L.optInt(farg + 1, 1);
  if (!(0 <= f)) L.argError(farg, 'field cannot be negative');
  if (!(0 < w)) L.argError(farg + 1, 'width must be positive');
  if (f + w > 32) L.luaError('trying to access non-existent bits');
  width[0] = w;
  return f;
}

/// `luaopen_bit32` into [t] in the order of `bitlib`.
LuaTable openBit32(LuaTable t) {
  for (final (name, f) in <(String, LuaCFunction)>[
    (
      'arshift',
      (L) {
        var r = L.checkUnsigned(1);
        final i = L.checkInt(2);
        if (i < 0 || (r & 0x80000000) == 0) return _shift(L, r, -i);
        r = i >= 32 ? _all : ((r >> i) | (~(_all >> i))) & _all;
        _pushU(L, r);
        return 1;
      },
    ),
    (
      'band',
      (L) {
        _pushU(L, _andAux(L));
        return 1;
      },
    ),
    (
      'bnot',
      (L) {
        _pushU(L, ~L.checkUnsigned(1));
        return 1;
      },
    ),
    (
      'bor',
      (L) {
        var r = 0;
        for (var i = 1; i <= L.getTop(); i++) {
          r |= L.checkUnsigned(i);
        }
        _pushU(L, r);
        return 1;
      },
    ),
    (
      'bxor',
      (L) {
        var r = 0;
        for (var i = 1; i <= L.getTop(); i++) {
          r ^= L.checkUnsigned(i);
        }
        _pushU(L, r);
        return 1;
      },
    ),
    (
      'btest',
      (L) {
        L.push(_andAux(L) != 0);
        return 1;
      },
    ),
    (
      'extract',
      (L) {
        final w = [0];
        final r = L.checkUnsigned(1);
        final f = _fieldArgs(L, 2, w);
        _pushU(L, (r >> f) & _mask(w[0]));
        return 1;
      },
    ),
    ('lrotate', (L) => _rot(L, L.checkInt(2))),
    ('lshift', (L) => _shift(L, L.checkUnsigned(1), L.checkInt(2))),
    (
      'replace',
      (L) {
        final w = [0];
        var r = L.checkUnsigned(1);
        var v = L.checkUnsigned(2);
        final f = _fieldArgs(L, 3, w);
        final mk = _mask(w[0]);
        v &= mk;
        r = (r & ~(mk << f)) | (v << f);
        _pushU(L, r);
        return 1;
      },
    ),
    ('rrotate', (L) => _rot(L, -L.checkInt(2))),
    ('rshift', (L) => _shift(L, L.checkUnsigned(1), -L.checkInt(2))),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  return t;
}
