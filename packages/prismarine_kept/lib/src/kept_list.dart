import 'dart:collection';

/// A growable list that keeps its storage when cleared or shortened. The
/// VM's growable list gives its store up on `clear()` (and on a length
/// cut well below its capacity), so a list cleared and refilled each frame
/// grew it again from empty every frame (perf).
final class KeptList<E> extends ListBase<E> {
  KeptList();

  var _items = List<Object?>.filled(8, null);
  int _length = 0;

  /// Elements the list has room for before it grows (tests).
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
    // A list by index (no iterator).
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

  /// Empties the list, its storage kept.
  @override
  void clear() => length = 0;

  @override
  bool get isEmpty => _length == 0;

  @override
  bool get isNotEmpty => _length != 0;
}

/// [had] while it holds [now]'s elements (the same objects, in order),
/// else a fixed-length copy of [now]: a list gathered in scratch each frame
/// and kept from frame to frame while it holds (perf). Nothing may write
/// the list returned.
List<E> keptCopyOf<E>(List<E>? had, List<E> now) {
  final n = now.length;
  if (had != null && had.length == n) {
    var same = true;
    for (var i = 0; i < n && same; i++) {
      same = identical(had[i], now[i]);
    }
    if (same) return had;
  }
  return List.of(now, growable: false);
}
