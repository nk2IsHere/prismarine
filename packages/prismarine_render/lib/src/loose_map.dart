/// A cache of GPU objects by key whose entries can be let go once the
/// scenes that asked for them closed.
///
/// [loosen] does not drop a value. It only stops holding it. A loosened value
/// that anything else still holds, such as the setup of a live draw, is found
/// again by `[]` as the same object. A second copy is then not loaded. A value
/// that nothing holds goes with the garbage collector. Only then does an ask
/// miss. [loosen] keeps held the entries asked for in its epoch or later, the
/// entries that one of the kept scenes asked for (the bits of [owners]) and the
/// entries that its `keep` selects.
class LooseMap<K extends Object, V extends Object> {
  final _held = <K, V>{};
  final _loose = <K, WeakReference<V>>{};
  final _asked = <K, int>{};
  final _askedBy = <K, int>{};

  /// Raised at each scene close. Entries asked for after it carry the new
  /// value.
  int epoch = 0;

  /// The scenes that ask now, one bit each, such as the open 3D scenes and a
  /// scene whose draws are made ready ahead. Every ask adds them to the
  /// owners of the entry.
  int owners = 0;

  /// Returns the value of [k] if held, or if loosened and still alive, in
  /// which case it is held again.
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

  /// Returns true when the value of [k] is held or alive, without asking for
  /// it. The look does not count as a use and does not revive the value.
  bool has(K k) => _held.containsKey(k) || _loose[k]?.target != null;

  /// Returns true when [k] is held, without asking for it.
  bool holds(K k) => _held.containsKey(k);

  V? remove(K k) {
    _loose.remove(k);
    _asked.remove(k);
    _askedBy.remove(k);
    return _held.remove(k);
  }

  int get length => _held.length;

  /// The keys held.
  Iterable<K> get heldKeys => _held.keys;

  // alloc-cold: a diagnostics line now and then.
  /// The number of loosened entries still alive.
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

  /// Returns true when [k] is loosened and held weakly.
  bool isLoose(K k) => _loose.containsKey(k) && !_held.containsKey(k);

  // alloc-cold: a change of the layout of a shader (RenderAssets.dropInput).
  /// Calls [f] with every entry held and every loosened one still alive.
  void forEachAlive(void Function(V v) f) {
    _held.values.forEach(f);
    for (final w in _loose.values) {
      if (w.target case final v?) f(v);
    }
  }

  // alloc-cold: at a scene close's release.
  /// Loosens every held entry last asked for before [since] that none of
  /// the scenes in [keepOwners] asked for and that [keep] does not select.
  /// Forgets the loosened entries already gone. Returns the number of
  /// entries loosened.
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
