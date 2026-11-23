// Ported from Lua 5.2.3 ltable.c and `luaS_hash` of lstring.c (MIT, see
// LICENSE-lua). A number key hashes with the frexp form of `luai_hashnum` in
// float arithmetic in every number mode. A string key hashes with `luaS_hash`
// and the fixed seed [luaHashSeed], and an object with its id.

import 'dart:typed_data';

import 'package:prismarine_snap/prismarine_snap.dart';

import 'number.dart';
import 'value.dart';

/// The seed of the string hash. Stock Lua seeds from the time and addresses,
/// which gives another `pairs` order on each run. The seed 0 gives the same
/// order on every run.
const int luaHashSeed = 0;

const _maxBits = 30;
const _maxASize = 1 << _maxBits;
const _none = 0x7FFFFFFFFFFF;

/// `luaS_hash`.
int luaStringHash(String s, int seed) {
  final l = s.length;
  var h = (seed ^ l) & 0xFFFFFFFF;
  final step = (l >> 5) + 1;
  for (var l1 = l; l1 >= step; l1 -= step) {
    h =
        (h ^
            (((h << 5) & 0xFFFFFFFF) +
                (h >> 2) +
                (s.codeUnitAt(l1 - 1) & 0xFF))) &
        0xFFFFFFFF;
  }
  return h;
}

/// A table error that the VM reports with its position, as `luaG_runerror`
/// does.
class LuaTableKeyError implements Exception {
  LuaTableKeyError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Truncation to int32. A NaN or a value outside int32 gives 0x80000000.
int _ftol(double x) {
  if (x.isNaN || x >= 2147483648.0 || x <= -2147483649.0) return -2147483648;
  return x.truncate();
}

/// `luai_hashnum` with the sign fix of `hashnum`.
int _hashNum(double n) {
  final (m, e) = frexp(n);
  var i = _ftol(f32(f32(m) * 2147482624.0)) + e;
  i = i.toSigned(32);
  if (i < 0) i = i == -2147483648 ? 0 : -i;
  return i;
}

int _ceilLog2(int x) => (x - 1).bitLength;

/// An integer key as a Lua number. A key beyond 2^24 is a float value when
/// the numbers of the isolate are floats.
double _keyNumber(int key) => key >= -0x1000000 && key <= 0x1000000
    ? key.toDouble()
    : (luaFloatKeys ? f32(key.toDouble()) : key.toDouble());

/// `lua_number2int` and `luai_numeq`. Returns the int value of an integral
/// number key in the int32 range, or null.
int? _intKey(double n) {
  if (n >= 2147483648.0 || n < -2147483648.0) return null;
  final k = n.truncate();
  return k == n ? k : null;
}

class LuaTable extends LuaObject {
  /// `luaH_new`, then `luaH_resize(narray, nhash)` when either is not zero,
  /// as OP_NEWTABLE and `lua_createtable` do.
  LuaTable([int narray = 0, int nhash = 0]) {
    _setNodeVector(0);
    if (narray != 0 || nhash != 0) resize(narray, nhash);
  }

  LuaTable? metatable;

  /// The cache of absent metamethods, `flags` of `fasttm` in ltm.c. Bit e is
  /// set when the metamethod of event e is known to be absent. A raw set
  /// clears it.
  int flags = 0xFF;

  List<Object?> _arr = List<Object?>.filled(0, null);
  int _sizeArray = 0;
  late List<Object?> _nk;
  late List<Object?> _nv;
  late Int32List _nn;
  int _lsize = 0;
  bool _dummy = true;
  int _lastFree = 0;

  int get sizeArray => _sizeArray;

  /// Writes the raw state of the table, the metatable, the array part and
  /// the node vector as they are. The node order is the iteration order.
  void snapWrite(SnapWriter w) {
    w.ref(metatable);
    w.uint(flags);
    w.uint(_sizeArray);
    w.values(_arr);
    w.uint(_lsize);
    w.boolean(_dummy);
    w.int_(_lastFree);
    w.values(_nk);
    w.values(_nv);
    w.ints(_nn);
  }

  /// Restores what [snapWrite] wrote.
  void snapRead(SnapReader r) {
    metatable = r.ref<LuaTable?>();
    flags = r.uint();
    _sizeArray = r.uint();
    _arr = List<Object?>.of(r.values(), growable: false);
    _lsize = r.uint();
    _dummy = r.boolean();
    _lastFree = r.int_();
    _nk = List<Object?>.of(r.values(), growable: false);
    _nv = List<Object?>.of(r.values(), growable: false);
    _nn = Int32List.fromList(r.ints());
    // An empty table shares the dummy node again.
    if (_dummy) {
      _nk = _dummyKeys;
      _nv = _dummyValues;
      _nn = _dummyNext;
    }
  }

  int get _sizeNode => 1 << _lsize;

  int _mainPosition(Object? key) {
    final size = _sizeNode;
    if (key is double) return _hashNum(key) % ((size - 1) | 1);
    if (key is String) return luaStringHash(key, luaHashSeed) & (size - 1);
    if (key is bool) return (key ? 1 : 0) & (size - 1);
    if (key is LuaObject) return key.id % ((size - 1) | 1);
    throw StateError('not a Lua key: ${key.runtimeType}');
  }

  int _slotOfInt(int key) {
    if (key - 1 >= 0 && key - 1 < _sizeArray) return ~(key - 1);
    final nk = _keyNumber(key);
    var n = _hashNum(nk) % ((_sizeNode - 1) | 1);
    do {
      final k = _nk[n];
      if (k is double && k == nk) return n;
      n = _nn[n];
    } while (n >= 0);
    return _none;
  }

  int _slotOfStr(String key) {
    var n = luaStringHash(key, luaHashSeed) & (_sizeNode - 1);
    do {
      final k = _nk[n];
      if (k is String && k == key) return n;
      n = _nn[n];
    } while (n >= 0);
    return _none;
  }

  int _slotOf(Object? key) {
    if (key is String) return _slotOfStr(key);
    if (key == null) return _none;
    if (key is double) {
      if (key.isNaN) return _none;
      final k = _intKey(key);
      if (k != null) return _slotOfInt(k);
    }
    var n = _mainPosition(key);
    do {
      if (luaRawEquals(_nk[n], key)) return n;
      n = _nn[n];
    } while (n >= 0);
    return _none;
  }

  Object? _load(int s) => s == _none ? null : (s < 0 ? _arr[~s] : _nv[s]);

  void _store(int s, Object? v) {
    if (s < 0) {
      _arr[~s] = v;
    } else {
      _nv[s] = v;
    }
  }

  /// `luaH_get`, a raw read.
  Object? get(Object? key) => _load(_slotOf(key));

  /// `luaH_getint`, a raw read.
  Object? getInt(int key) {
    if (key - 1 >= 0 && key - 1 < _sizeArray) return _arr[key - 1];
    return _load(_slotOfInt(key));
  }

  /// `luaH_getstr`, a raw read.
  Object? getStr(String key) => _load(_slotOfStr(key));

  /// [getStr] with the [luaStringHash] of [key] given, as
  /// [LuaProto.constHash] has it.
  Object? getStrH(String key, int hash) {
    var n = hash & (_sizeNode - 1);
    do {
      final k = _nk[n];
      if (k is String && (identical(k, key) || k == key)) return _nv[n];
      n = _nn[n];
    } while (n >= 0);
    return null;
  }

  /// `luaH_set` and the assignment, a raw write. Creates the key also for a
  /// nil [value], as `luaV_settable` and `lua_rawset` do. Clears [flags].
  void set(Object? key, Object? value) {
    var s = _slotOf(key);
    if (s == _none) s = _newKey(key);
    _store(s, value);
    flags = 0;
  }

  /// `luaH_setint` and the assignment, a raw write of OP_SETLIST and
  /// `lua_rawseti`.
  void setInt(int key, Object? value) {
    var s = _slotOfInt(key);
    if (s == _none) s = _newKey(_keyNumber(key));
    _store(s, value);
  }

  int _getFreePos() {
    while (_lastFree > 0) {
      _lastFree--;
      if (_nk[_lastFree] == null) return _lastFree;
    }
    return -1;
  }

  /// `luaH_newkey`. Returns the slot for a new [key]. Moves a colliding node,
  /// or rehashes when no free node is left.
  int _newKey(Object? key) {
    if (key == null) throw LuaTableKeyError('table index is nil');
    if (key is double && key.isNaN) {
      throw LuaTableKeyError('table index is NaN');
    }
    var mp = _mainPosition(key);
    if (_nv[mp] != null || _dummy) {
      final n = _getFreePos();
      if (n < 0) {
        _rehash(key);
        final s = _slotOf(key);
        return s == _none ? _newKey(key) : s;
      }
      var othern = _mainPosition(_nk[mp]);
      if (othern != mp) {
        while (_nn[othern] != mp) {
          othern = _nn[othern];
        }
        _nn[othern] = n;
        _nk[n] = _nk[mp];
        _nv[n] = _nv[mp];
        _nn[n] = _nn[mp];
        _nn[mp] = -1;
        _nv[mp] = null;
      } else {
        _nn[n] = _nn[mp];
        _nn[mp] = n;
        mp = n;
      }
    }
    _nk[mp] = key;
    return mp;
  }

  void _setArrayVector(int size) {
    final a = List<Object?>.filled(size, null);
    for (var i = 0; i < _sizeArray && i < size; i++) {
      a[i] = _arr[i];
    }
    _arr = a;
    _sizeArray = size;
  }

  void _setNodeVector(int size) {
    if (size == 0) {
      // The shared dummy node, as `dummynode` of Lua. It is not written. A
      // new key finds no free position and rehashes.
      _nk = _dummyKeys;
      _nv = _dummyValues;
      _nn = _dummyNext;
      _lsize = 0;
      _dummy = true;
      _lastFree = 0;
      return;
    }
    final lsize = _ceilLog2(size);
    if (lsize > _maxBits) throw LuaTableKeyError('table overflow');
    final n = 1 << lsize;
    _nk = List<Object?>.filled(n, null);
    _nv = List<Object?>.filled(n, null);
    _nn = Int32List(n)..fillRange(0, n, -1);
    _lsize = lsize;
    _dummy = false;
    _lastFree = n;
  }

  /// `luaH_resize`.
  void resize(int nasize, int nhsize) {
    final oldasize = _sizeArray;
    final oldhsize = _lsize;
    final oldk = _nk, oldv = _nv;
    if (nasize > oldasize) _setArrayVector(nasize);
    _setNodeVector(nhsize);
    if (nasize < oldasize) {
      _sizeArray = nasize;
      final old = _arr;
      for (var i = nasize; i < oldasize; i++) {
        if (old[i] != null) setInt(i + 1, old[i]);
      }
      _arr = List<Object?>.of(old.take(nasize), growable: false);
    }
    for (var i = (1 << oldhsize) - 1; i >= 0; i--) {
      final v = oldv[i];
      if (v != null) {
        final k = oldk[i];
        var s = _slotOf(k);
        if (s == _none) s = _newKey(k);
        _store(s, v);
      }
    }
  }

  /// `luaH_resizearray` of OP_SETLIST.
  void resizeArray(int nasize) => resize(nasize, _dummy ? 0 : _sizeNode);

  int _arrayIndex(Object? key) {
    if (key is double) {
      final k = _intKey(key);
      if (k != null) return k;
    }
    return -1;
  }

  int _countInt(Object? key, List<int> nums) {
    final k = _arrayIndex(key);
    if (0 < k && k <= _maxASize) {
      nums[_ceilLog2(k)]++;
      return 1;
    }
    return 0;
  }

  int _numUseArray(List<int> nums) {
    var ause = 0;
    var i = 1;
    for (var lg = 0, ttlg = 1; lg <= _maxBits; lg++, ttlg *= 2) {
      var lc = 0;
      var lim = ttlg;
      if (lim > _sizeArray) {
        lim = _sizeArray;
        if (i > lim) break;
      }
      for (; i <= lim; i++) {
        if (_arr[i - 1] != null) lc++;
      }
      nums[lg] += lc;
      ause += lc;
    }
    return ause;
  }

  (int, int) _numUseHash(List<int> nums) {
    var totaluse = 0, ause = 0;
    var i = _sizeNode;
    while (i-- > 0) {
      if (_nv[i] != null) {
        ause += _countInt(_nk[i], nums);
        totaluse++;
      }
    }
    return (totaluse, ause);
  }

  static (int, int) _computeSizes(List<int> nums, int narray) {
    var a = 0, na = 0, n = 0;
    for (var i = 0, twotoi = 1; twotoi ~/ 2 < narray; i++, twotoi *= 2) {
      if (nums[i] > 0) {
        a += nums[i];
        if (a > twotoi ~/ 2) {
          n = twotoi;
          na = a;
        }
      }
      if (a == narray) break;
    }
    return (n, na);
  }

  static final _dummyKeys = List<Object?>.filled(1, null);
  static final _dummyValues = List<Object?>.filled(1, null);
  static final _dummyNext = Int32List(1)..[0] = -1;

  /// The counts of [_rehash] per size class, kept between calls.
  static final _nums = List<int>.filled(_maxBits + 1, 0);

  void _rehash(Object? ek) {
    final nums = _nums..fillRange(0, _maxBits + 1, 0);
    var nasize = _numUseArray(nums);
    var totaluse = nasize;
    final (hTotal, hInt) = _numUseHash(nums);
    totaluse += hTotal;
    nasize += hInt;
    nasize += _countInt(ek, nums);
    totaluse++;
    final (size, na) = _computeSizes(nums, nasize);
    resize(size, totaluse - na);
  }

  /// `luaH_getn`. Returns a border, the raw `#`.
  int length() {
    var j = _sizeArray;
    if (j > 0 && _arr[j - 1] == null) {
      var i = 0;
      while (j - i > 1) {
        final m = (i + j) ~/ 2;
        if (_arr[m - 1] == null) {
          j = m;
        } else {
          i = m;
        }
      }
      return i;
    }
    if (_dummy) return j;
    return _unboundSearch(j);
  }

  int _unboundSearch(int j0) {
    var i = j0;
    var j = j0 + 1;
    while (getInt(j) != null) {
      i = j;
      j *= 2;
      if (j > 2147483647) {
        i = 1;
        while (getInt(i) != null) {
          i++;
        }
        return i - 1;
      }
    }
    while (j - i > 1) {
      final m = (i + j) ~/ 2;
      if (getInt(m) == null) {
        j = m;
      } else {
        i = m;
      }
    }
    return i;
  }

  int _findIndex(Object? key) {
    if (key == null) return -1;
    final i = _arrayIndex(key);
    if (0 < i && i <= _sizeArray) return i - 1;
    var n = _mainPosition(key);
    while (true) {
      if (luaRawEquals(_nk[n], key)) return n + _sizeArray;
      n = _nn[n];
      if (n < 0) throw LuaTableKeyError("invalid key to 'next'");
    }
  }

  /// [next] with the pair in [nextKey] and [nextValue], which the caller
  /// reads at once. Returns false at the end.
  bool nextInto(Object? key) {
    var i = _findIndex(key);
    for (i++; i < _sizeArray; i++) {
      final v = _arr[i];
      if (v != null) {
        nextKey = (i + 1).toDouble();
        nextValue = v;
        return true;
      }
    }
    final size = _sizeNode;
    for (i -= _sizeArray; i < size; i++) {
      final v = _nv[i];
      if (v != null) {
        nextKey = _nk[i];
        nextValue = v;
        return true;
      }
    }
    return false;
  }

  static Object? nextKey, nextValue;

  /// `luaH_next`. Returns the pair after [key], the first pair for a null
  /// [key], or null at the end.
  (Object?, Object?)? next(Object? key) {
    var i = _findIndex(key);
    for (i++; i < _sizeArray; i++) {
      final v = _arr[i];
      if (v != null) return ((i + 1).toDouble(), v);
    }
    final size = _sizeNode;
    for (i -= _sizeArray; i < size; i++) {
      final v = _nv[i];
      if (v != null) return (_nk[i], v);
    }
    return null;
  }
}
