/// A cache of GPU objects by key whose entries can be let go once the
/// scenes that asked for them closed.
///
/// What it guarantees: [loosen] never drops a value, it only stops holding
/// it. A loosened value anything else still holds (a live draw's setup, a
/// cooked scene's pulled draw) is found again by `[]`, the same object, so
/// a second copy is never loaded; one nothing holds goes with the
/// collector, and only then does an ask miss. What [loosen] keeps held, so
/// it is there whenever the collector runs: entries asked for in the
/// [epoch] it is given or later, entries one of the kept scenes asked for
/// ([owners]' bits), and entries its `keep` names (the held prediction's
/// own loads).
class LooseMap<K extends Object, V extends Object> {
  final _held = <K, V>{};
  final _loose = <K, WeakReference<V>>{};
  final _asked = <K, int>{};
  final _askedBy = <K, int>{};

  /// Bumped at each scene close: entries asked for after it carry the new
  /// value.
  int epoch = 0;

  /// The scenes asking now, one bit each, such as the open 3D scenes and a
  /// scene whose draws are made ready ahead. Every ask adds them to the
  /// entry's.
  int owners = 0;

  /// [k]'s value if held, or loosened and still alive (held again).
  V? operator [](K k) {
    final v = _held[k];
    if (v != null) {
      _stamp(k);
      return v;
    }
    if (_loose.isEmpty) return null;
    return _revive(k);
  }

  void _stamp(K k) {
    if (_asked[k] != epoch) _asked[k] = epoch;
    if (owners == 0) return;
    final by = _askedBy[k] ?? 0;
    if (by | owners != by) _askedBy[k] = by | owners;
  }

  // alloc-cold: a loosened entry asked for again.
  V? _revive(K k) {
    final v = _loose.remove(k)?.target;
    if (v != null) this[k] = v;
    return v;
  }

  void operator []=(K k, V v) {
    _held[k] = v;
    _stamp(k);
  }

  bool containsKey(K k) => this[k] != null;

  /// Whether [k]'s value is held or alive, without asking for it (no stamp,
  /// no revive: a look ahead, not a use).
  bool has(K k) => _held.containsKey(k) || _loose[k]?.target != null;

  /// Whether [k] is held, without asking for it.
  bool holds(K k) => _held.containsKey(k);

  V? remove(K k) {
    _loose.remove(k);
    _asked.remove(k);
    _askedBy.remove(k);
    return _held.remove(k);
  }

  int get length => _held.length;

  /// The keys held (diagnostics).
  Iterable<K> get heldKeys => _held.keys;

  // alloc-cold: a diagnostics line now and then.
  /// Loosened entries still alive (the memory census).
  int get looseAlive {
    var n = 0;
    for (final w in _loose.values) {
      if (w.target != null) n++;
    }
    return n;
  }

  // alloc-cold: at a scene close's release.
  /// The loosened entries still alive, as (key, value) pairs.
  List<(K, V)> get looseEntries => [
    for (final MapEntry(:key, :value) in _loose.entries)
      if (value.target case final v?) (key, v),
  ];

  /// Whether [k] is loosened (held weakly), for tests.
  bool isLoose(K k) => _loose.containsKey(k) && !_held.containsKey(k);

  // alloc-cold: a shader's layout change (Assets.dropInput).
  /// Calls [f] with every entry held, and every loosened one still alive.
  void forEachAlive(void Function(V v) f) {
    _held.values.forEach(f);
    for (final w in _loose.values) {
      if (w.target case final v?) f(v);
    }
  }

  // alloc-cold: at a scene close's release.
  /// Loosens every held entry last asked for before [since] that none of
  /// the scenes in [keepOwners] asked for and [keep] doesn't name, and
  /// forgets loosened ones already gone; how many were loosened.
  int loosen(int since, {int keepOwners = 0, bool Function(K k)? keep}) {
    _loose.removeWhere((_, w) => w.target == null);
    var n = 0;
    _held.removeWhere((k, v) {
      if ((_asked[k] ?? 0) >= since) return false;
      if ((_askedBy[k] ?? 0) & keepOwners != 0) return false;
      if (keep?.call(k) ?? false) return false;
      _asked.remove(k);
      _askedBy.remove(k);
      _loose[k] = WeakReference(v);
      n++;
      return true;
    });
    return n;
  }
}
