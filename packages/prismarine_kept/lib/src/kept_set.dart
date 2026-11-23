import 'dart:collection';

import 'kept_map.dart';

/// A hash set that keeps its storage when cleared, in insertion order like
/// the default set ([KeptMap]'s keys).
final class KeptSet<E extends Object> extends SetBase<E> {
  KeptSet() : _map = KeptMap<E, bool>();
  KeptSet.identity() : _map = KeptMap<E, bool>.identity();

  final KeptMap<E, bool> _map;

  /// Elements the set has room for before it grows (tests).
  int get capacity => _map.capacity;

  @override
  bool add(E value) {
    final had = _map.length;
    _map[value] = true;
    return _map.length != had;
  }

  @override
  bool contains(Object? element) => _map.containsKey(element);

  @override
  E? lookup(Object? element) {
    if (!_map.containsKey(element)) return null;
    for (final e in _map.keys) {
      if (_map.identity ? identical(e, element) : e == element) return e;
    }
    return null;
  }

  @override
  bool remove(Object? value) {
    final had = _map.length;
    _map.remove(value);
    return _map.length != had;
  }

  /// Empties the set, its storage kept.
  @override
  void clear() => _map.clear();

  @override
  Iterator<E> get iterator => _map.keys.iterator;

  @override
  int get length => _map.length;

  @override
  bool get isEmpty => _map.isEmpty;

  @override
  bool get isNotEmpty => _map.isNotEmpty;

  @override
  void forEach(void Function(E element) f) => _map.forEach((k, _) => f(k));

  @override
  Set<E> toSet() =>
      (_map.identity ? KeptSet<E>.identity() : KeptSet<E>())..addAll(this);
}
