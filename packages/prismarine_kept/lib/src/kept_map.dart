import 'dart:collection';
import 'dart:typed_data';

/// A hash map that keeps its storage when cleared, in insertion order like
/// the default map. The VM's LinkedHashMap drops its tables on `clear()`,
/// so a map cleared and refilled each frame grew them from empty every
/// frame (perf: most of what the frame's maps allocated).
///
/// Keys are compared by `==` and `hashCode`, or by identity
/// ([KeptMap.identity]). Changing the map while walking it throws, as the
/// default map does.
final class KeptMap<K extends Object, V> extends MapBase<K, V> {
  KeptMap() : identity = false;
  KeptMap.identity() : identity = true;

  final bool identity;

  /// The entries in insertion order, the first [_used] written ([_gone]
  /// where one was removed), and each one's hash.
  var _keys = List<Object?>.filled(_initial, null);
  var _values = List<Object?>.filled(_initial, null);
  var _hashes = Int32List(_initial);
  int _used = 0;
  int _length = 0;

  /// Open addressing over the entries: entry + 1, 0 for an empty slot, -1
  /// for a removed one (probes go past it). Twice the entries' capacity.
  var _index = Int32List(_initial * 2);

  /// Changes that move entries, for the walks' checks.
  int _changes = 0;

  static const _initial = 8;
  static final Object _gone = Object();

  /// Entries the map has room for before it grows (tests).
  int get capacity => _keys.length;

  int _hash(Object key) =>
      (identity ? identityHashCode(key) : key.hashCode) & 0x3fffffff;

  bool _same(Object? a, Object b) => identity ? identical(a, b) : a == b;

  static int _slot(int hash, int mask) => (hash ^ (hash >> 13)) & mask;

  /// [key]'s entry, or -1.
  int _find(Object? key) {
    if (key == null || _length == 0) return -1;
    final h = _hash(key);
    final index = _index, mask = index.length - 1;
    var s = _slot(h, mask);
    while (true) {
      final e = index[s];
      if (e == 0) return -1;
      if (e > 0 && _hashes[e - 1] == h && _same(_keys[e - 1], key)) {
        return e - 1;
      }
      s = (s + 1) & mask;
    }
  }

  /// [key]'s entry, added with [value] when it has none.
  int _findOrAdd(K key, V value) {
    final h = _hash(key);
    var index = _index;
    var mask = index.length - 1;
    var s = _slot(h, mask);
    var free = -1;
    while (true) {
      final e = index[s];
      if (e == 0) break;
      if (e < 0) {
        if (free < 0) free = s;
      } else if (_hashes[e - 1] == h && _same(_keys[e - 1], key)) {
        return e - 1;
      }
      s = (s + 1) & mask;
    }
    if (_used == _keys.length) {
      _grow();
      index = _index;
      mask = index.length - 1;
      s = _slot(h, mask);
      while (index[s] != 0) {
        s = (s + 1) & mask;
      }
    } else if (free >= 0) {
      s = free;
    }
    final i = _used++;
    _keys[i] = key;
    _values[i] = value;
    _hashes[i] = h;
    index[s] = i + 1;
    _length++;
    _changes++;
    return -1;
  }

  /// Room for one more entry: the live ones packed when removals left
  /// half the entries free, else twice the capacity.
  void _grow() {
    final size = _length * 2 <= _keys.length ? _keys.length : _keys.length * 2;
    final keys = List<Object?>.filled(size, null);
    final values = List<Object?>.filled(size, null);
    final hashes = Int32List(size);
    final index = Int32List(size * 2);
    final mask = index.length - 1;
    var n = 0;
    for (var i = 0; i < _used; i++) {
      final k = _keys[i];
      if (identical(k, _gone)) continue;
      keys[n] = k;
      values[n] = _values[i];
      final h = hashes[n] = _hashes[i];
      var s = _slot(h, mask);
      while (index[s] != 0) {
        s = (s + 1) & mask;
      }
      index[s] = ++n;
    }
    _keys = keys;
    _values = values;
    _hashes = hashes;
    _index = index;
    _used = n;
    _changes++;
  }

  @override
  V? operator [](Object? key) {
    final i = _find(key);
    return i < 0 ? null : _values[i] as V;
  }

  @override
  void operator []=(K key, V value) {
    final i = _findOrAdd(key, value);
    if (i >= 0) _values[i] = value;
  }

  @override
  V putIfAbsent(K key, V Function() ifAbsent) {
    final i = _find(key);
    if (i >= 0) return _values[i] as V;
    final v = ifAbsent();
    this[key] = v;
    return v;
  }

  @override
  bool containsKey(Object? key) => _find(key) >= 0;

  @override
  V? remove(Object? key) {
    if (key == null || _length == 0) return null;
    final h = _hash(key);
    final index = _index, mask = index.length - 1;
    var s = _slot(h, mask);
    while (true) {
      final e = index[s];
      if (e == 0) return null;
      if (e > 0 && _hashes[e - 1] == h && _same(_keys[e - 1], key)) {
        final v = _values[e - 1] as V;
        index[s] = -1;
        _keys[e - 1] = _gone;
        _values[e - 1] = null;
        _length--;
        _changes++;
        return v;
      }
      s = (s + 1) & mask;
    }
  }

  /// Empties the map, its storage kept.
  @override
  void clear() {
    if (_used == 0) return;
    _keys.fillRange(0, _used, null);
    _values.fillRange(0, _used, null);
    _index.fillRange(0, _index.length, 0);
    _used = _length = 0;
    _changes++;
  }

  @override
  int get length => _length;

  @override
  bool get isEmpty => _length == 0;

  @override
  bool get isNotEmpty => _length != 0;

  @override
  void forEach(void Function(K key, V value) action) {
    final changes = _changes;
    for (var i = 0; i < _used; i++) {
      final k = _keys[i];
      if (identical(k, _gone)) continue;
      action(k as K, _values[i] as V);
      if (changes != _changes) throw ConcurrentModificationError(this);
    }
  }

  /// The views made once, and an iterator of each given back when its
  /// walk ends (perf: a view and an iterator per walk; a walk that stops
  /// early leaves its iterator to the collector).
  @override
  late final Iterable<K> keys = _KeptKeys(this);

  @override
  late final Iterable<V> values = _KeptValues(this);

  _KeptIterator<K, V, K>? _freeKeys;
  _KeptIterator<K, V, V>? _freeValues;
}

final class _KeptKeys<K extends Object, V> extends Iterable<K> {
  _KeptKeys(this._map);
  final KeptMap<K, V> _map;

  @override
  Iterator<K> get iterator {
    final free = _map._freeKeys;
    if (free == null) return _KeptIterator<K, V, K>(_map, true);
    _map._freeKeys = null;
    return free.._restart();
  }

  @override
  int get length => _map._length;

  @override
  bool contains(Object? element) => _map._find(element) >= 0;
}

final class _KeptValues<K extends Object, V> extends Iterable<V> {
  _KeptValues(this._map);
  final KeptMap<K, V> _map;

  @override
  Iterator<V> get iterator {
    final free = _map._freeValues;
    if (free == null) return _KeptIterator<K, V, V>(_map, false);
    _map._freeValues = null;
    return free.._restart();
  }

  @override
  int get length => _map._length;
}

final class _KeptIterator<K extends Object, V, T> implements Iterator<T> {
  _KeptIterator(this._map, this._keys) : _changes = _map._changes;
  final KeptMap<K, V> _map;
  final bool _keys;
  int _changes;
  int _at = -1;
  T? _current;

  void _restart() {
    _changes = _map._changes;
    _at = -1;
    _current = null;
  }

  @override
  T get current => _current as T;

  @override
  bool moveNext() {
    final m = _map;
    if (_changes != m._changes) throw ConcurrentModificationError(m);
    while (++_at < m._used) {
      final k = m._keys[_at];
      if (identical(k, KeptMap._gone)) continue;
      _current = (_keys ? k : m._values[_at]) as T;
      return true;
    }
    _current = null;
    // Done: given back for the next walk.
    if (_keys) {
      m._freeKeys = this as _KeptIterator<K, V, K>;
    } else {
      m._freeValues = this as _KeptIterator<K, V, V>;
    }
    return false;
  }
}
