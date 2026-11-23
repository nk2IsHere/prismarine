part of 'snap.dart';

/// An [Expando] whose live entries can be listed (a snapshot writes the
/// entries whose keys it holds). Entries die with their keys, as an
/// Expando's do; the list of keys holds them weakly.
class SnapWeakMap<K extends Object, V extends Object> {
  SnapWeakMap([String? name]) : _e = Expando<V>(name);
  final Expando<V> _e;
  final _keys = <WeakReference<K>>[];
  int _since = 0;

  V? operator [](K key) => _e[key];

  void operator []=(K key, V? value) {
    if (value != null && _e[key] == null) {
      _keys.add(WeakReference(key));
      if (++_since > 4096) _prune();
    }
    _e[key] = value;
  }

  // Drops the references of gone or unset keys, and the later copies of a
  // key removed and set again (each set after a removal adds a reference).
  void _prune() {
    _since = 0;
    final seen = HashSet<K>.identity();
    _keys.removeWhere((r) {
      final k = r.target;
      return k == null || _e[k] == null || !seen.add(k);
    });
  }

  /// The live entries (keys still reachable and set), oldest first.
  List<(K, V)> get entries {
    _prune();
    return [
      for (final r in _keys)
        if (r.target case final k?)
          if (_e[k] case final v?) (k, v),
    ];
  }

  /// Every entry removed.
  void clear() {
    for (final (k, _) in entries) {
      _e[k] = null;
    }
    _keys.clear();
  }

  /// The entries whose keys [w] has written, as (key, value) pairs.
  void snapWrite(SnapWriter w, void Function(V v) writeValue) {
    final live = [
      for (final e in entries)
        if (w.heldStrongly(e.$1)) e,
    ];
    w.uint(live.length);
    for (final (k, v) in live) {
      w.ref(k);
      writeValue(v);
    }
  }

  void snapRead(SnapReader r, V Function() readValue) {
    clear();
    final n = r.uint();
    for (var i = 0; i < n; i++) {
      final k = r.ref<K>();
      this[k] = readValue();
    }
  }
}
