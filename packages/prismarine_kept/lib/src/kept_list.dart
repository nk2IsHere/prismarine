import 'dart:collection';

/// A growable list that keeps its storage when it is cleared or shortened.
/// Use it for a list that is cleared and filled again every frame.
final class KeptList<E> extends ListBase<E> {
  KeptList();

  var _items = List<Object?>.filled(8, null);
  int _length = 0;

  /// The number of elements the list holds before it grows.
  int get capacity => _items.length;

  @override
  int get length => _length;

  @override
  set length(int n) {
    if (n < 0) throw RangeError.value(n, 'length');
    if (n > _length) {
      if (null is! E) {
        throw UnsupportedError('a longer list of non-nullable elements');
      }
      _reserve(n);
    } else {
      _items.fillRange(n, _length, null);
    }
    _length = n;
  }

  void _reserve(int n) {
    if (n <= _items.length) return;
    var size = _items.length * 2;
    while (size < n) {
      size *= 2;
    }
    // alloc: the storage grows when it is full and is kept from then on
    _items = List<Object?>.filled(size, null)..setRange(0, _length, _items);
  }

  @override
  E operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _items[index] as E;
  }

  @override
  void operator []=(int index, E value) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    _items[index] = value;
  }

  @override
  void add(E element) {
    if (_length == _items.length) _reserve(_length + 1);
    _items[_length++] = element;
  }

  @override
  void addAll(Iterable<E> iterable) {
    // A list is read by index. An iterator would allocate.
    if (iterable is List<E>) {
      final n = iterable.length;
      if (_length + n > _items.length) _reserve(_length + n);
      for (var i = 0; i < n; i++) {
        _items[_length++] = iterable[i];
      }
      return;
    }
    for (final e in iterable) {
      add(e);
    }
  }

  /// Empties the list and keeps its storage.
  @override
  void clear() => length = 0;

  @override
  bool get isEmpty => _length == 0;

  @override
  bool get isNotEmpty => _length != 0;
}

/// Returns [had] while it holds the elements of [now], the same objects in
/// the same order, or else a fixed-length copy of [now]. Use it to keep a
/// list that is gathered in scratch storage every frame. The returned list
/// must not be changed.
List<E> keptCopyOf<E>(List<E>? had, List<E> now) {
  final n = now.length;
  if (had != null && had.length == n) {
    var same = true;
    for (var i = 0; i < n && same; i++) {
      same = identical(had[i], now[i]);
    }
    if (same) return had;
  }
  // alloc: a copy only when the elements changed
  return List.of(now, growable: false);
}
