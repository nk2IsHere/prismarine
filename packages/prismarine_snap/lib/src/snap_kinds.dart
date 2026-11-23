// The container kinds the value codec knows.
part of 'snap.dart';

// Container kinds: the element types, and how the list or map was made
// (growable, fixed-length, unmodifiable: [_Kinds.listFinish] turns the
// growable copy read back into the same kind).

class _Kinds {
  _Kinds() {
    list<dynamic>();
    list<Object?>();
    list<Object>();
    list<double>();
    list<int>();
    list<String>();
    list<num>();
    list<bool>();
    list<double?>();
    list<int?>();
    list<String?>();
    list<List<dynamic>>();
    list<Map<String, dynamic>>();
    list<Map<dynamic, dynamic>>();
    list<Map<Object?, dynamic>>();
    list<List<Object?>>();
    list<Map<String, Object?>>();
    list<Map<dynamic, Object?>>();
    list<Map<Object?, Object?>>();
    list<List<Object>>();
    list<Map<String, Object>>();
    list<Map<dynamic, Object>>();
    list<Map<Object?, Object>>();
    list<List<double>>();
    list<Map<String, double>>();
    list<Map<dynamic, double>>();
    list<Map<Object?, double>>();
    list<List<int>>();
    list<Map<String, int>>();
    list<Map<dynamic, int>>();
    list<Map<Object?, int>>();
    list<List<String>>();
    list<Map<String, String>>();
    list<Map<dynamic, String>>();
    list<Map<Object?, String>>();
    list<List<num>>();
    list<Map<String, num>>();
    list<Map<dynamic, num>>();
    list<Map<Object?, num>>();
    map<dynamic, dynamic>();
    map<dynamic, Object?>();
    map<dynamic, Object>();
    map<dynamic, double>();
    map<dynamic, int>();
    map<dynamic, String>();
    map<dynamic, num>();
    map<dynamic, bool>();
    map<dynamic, double?>();
    map<dynamic, int?>();
    map<dynamic, String?>();
    map<dynamic, List<dynamic>>();
    map<dynamic, Map<String, dynamic>>();
    map<dynamic, Map<dynamic, dynamic>>();
    map<dynamic, Map<Object?, dynamic>>();
    map<dynamic, List<Object?>>();
    map<dynamic, Map<String, Object?>>();
    map<dynamic, Map<dynamic, Object?>>();
    map<dynamic, Map<Object?, Object?>>();
    map<dynamic, List<Object>>();
    map<dynamic, Map<String, Object>>();
    map<dynamic, Map<dynamic, Object>>();
    map<dynamic, Map<Object?, Object>>();
    map<dynamic, List<double>>();
    map<dynamic, Map<String, double>>();
    map<dynamic, Map<dynamic, double>>();
    map<dynamic, Map<Object?, double>>();
    map<dynamic, List<int>>();
    map<dynamic, Map<String, int>>();
    map<dynamic, Map<dynamic, int>>();
    map<dynamic, Map<Object?, int>>();
    map<dynamic, List<String>>();
    map<dynamic, Map<String, String>>();
    map<dynamic, Map<dynamic, String>>();
    map<dynamic, Map<Object?, String>>();
    map<dynamic, List<num>>();
    map<dynamic, Map<String, num>>();
    map<dynamic, Map<dynamic, num>>();
    map<dynamic, Map<Object?, num>>();
    map<Object?, dynamic>();
    map<Object?, Object?>();
    map<Object?, Object>();
    map<Object?, double>();
    map<Object?, int>();
    map<Object?, String>();
    map<Object?, num>();
    map<Object?, bool>();
    map<Object?, double?>();
    map<Object?, int?>();
    map<Object?, String?>();
    map<Object?, List<dynamic>>();
    map<Object?, Map<String, dynamic>>();
    map<Object?, Map<dynamic, dynamic>>();
    map<Object?, Map<Object?, dynamic>>();
    map<Object?, List<Object?>>();
    map<Object?, Map<String, Object?>>();
    map<Object?, Map<dynamic, Object?>>();
    map<Object?, Map<Object?, Object?>>();
    map<Object?, List<Object>>();
    map<Object?, Map<String, Object>>();
    map<Object?, Map<dynamic, Object>>();
    map<Object?, Map<Object?, Object>>();
    map<Object?, List<double>>();
    map<Object?, Map<String, double>>();
    map<Object?, Map<dynamic, double>>();
    map<Object?, Map<Object?, double>>();
    map<Object?, List<int>>();
    map<Object?, Map<String, int>>();
    map<Object?, Map<dynamic, int>>();
    map<Object?, Map<Object?, int>>();
    map<Object?, List<String>>();
    map<Object?, Map<String, String>>();
    map<Object?, Map<dynamic, String>>();
    map<Object?, Map<Object?, String>>();
    map<Object?, List<num>>();
    map<Object?, Map<String, num>>();
    map<Object?, Map<dynamic, num>>();
    map<Object?, Map<Object?, num>>();
    map<Object, dynamic>();
    map<Object, Object?>();
    map<Object, Object>();
    map<Object, double>();
    map<Object, int>();
    map<Object, String>();
    map<Object, num>();
    map<Object, bool>();
    map<Object, double?>();
    map<Object, int?>();
    map<Object, String?>();
    map<Object, List<dynamic>>();
    map<Object, Map<String, dynamic>>();
    map<Object, Map<dynamic, dynamic>>();
    map<Object, Map<Object?, dynamic>>();
    map<Object, List<Object?>>();
    map<Object, Map<String, Object?>>();
    map<Object, Map<dynamic, Object?>>();
    map<Object, Map<Object?, Object?>>();
    map<Object, List<Object>>();
    map<Object, Map<String, Object>>();
    map<Object, Map<dynamic, Object>>();
    map<Object, Map<Object?, Object>>();
    map<Object, List<double>>();
    map<Object, Map<String, double>>();
    map<Object, Map<dynamic, double>>();
    map<Object, Map<Object?, double>>();
    map<Object, List<int>>();
    map<Object, Map<String, int>>();
    map<Object, Map<dynamic, int>>();
    map<Object, Map<Object?, int>>();
    map<Object, List<String>>();
    map<Object, Map<String, String>>();
    map<Object, Map<dynamic, String>>();
    map<Object, Map<Object?, String>>();
    map<Object, List<num>>();
    map<Object, Map<String, num>>();
    map<Object, Map<dynamic, num>>();
    map<Object, Map<Object?, num>>();
    map<String, dynamic>();
    map<String, Object?>();
    map<String, Object>();
    map<String, double>();
    map<String, int>();
    map<String, String>();
    map<String, num>();
    map<String, bool>();
    map<String, double?>();
    map<String, int?>();
    map<String, String?>();
    map<String, List<dynamic>>();
    map<String, Map<String, dynamic>>();
    map<String, Map<dynamic, dynamic>>();
    map<String, Map<Object?, dynamic>>();
    map<String, List<Object?>>();
    map<String, Map<String, Object?>>();
    map<String, Map<dynamic, Object?>>();
    map<String, Map<Object?, Object?>>();
    map<String, List<Object>>();
    map<String, Map<String, Object>>();
    map<String, Map<dynamic, Object>>();
    map<String, Map<Object?, Object>>();
    map<String, List<double>>();
    map<String, Map<String, double>>();
    map<String, Map<dynamic, double>>();
    map<String, Map<Object?, double>>();
    map<String, List<int>>();
    map<String, Map<String, int>>();
    map<String, Map<dynamic, int>>();
    map<String, Map<Object?, int>>();
    map<String, List<String>>();
    map<String, Map<String, String>>();
    map<String, Map<dynamic, String>>();
    map<String, Map<Object?, String>>();
    map<String, List<num>>();
    map<String, Map<String, num>>();
    map<String, Map<dynamic, num>>();
    map<String, Map<Object?, num>>();
    map<int, dynamic>();
    map<int, Object?>();
    map<int, Object>();
    map<int, double>();
    map<int, int>();
    map<int, String>();
    map<int, num>();
    map<int, bool>();
    map<int, double?>();
    map<int, int?>();
    map<int, String?>();
    map<int, List<dynamic>>();
    map<int, Map<String, dynamic>>();
    map<int, Map<dynamic, dynamic>>();
    map<int, Map<Object?, dynamic>>();
    map<int, List<Object?>>();
    map<int, Map<String, Object?>>();
    map<int, Map<dynamic, Object?>>();
    map<int, Map<Object?, Object?>>();
    map<int, List<Object>>();
    map<int, Map<String, Object>>();
    map<int, Map<dynamic, Object>>();
    map<int, Map<Object?, Object>>();
    map<int, List<double>>();
    map<int, Map<String, double>>();
    map<int, Map<dynamic, double>>();
    map<int, Map<Object?, double>>();
    map<int, List<int>>();
    map<int, Map<String, int>>();
    map<int, Map<dynamic, int>>();
    map<int, Map<Object?, int>>();
    map<int, List<String>>();
    map<int, Map<String, String>>();
    map<int, Map<dynamic, String>>();
    map<int, Map<Object?, String>>();
    map<int, List<num>>();
    map<int, Map<String, num>>();
    map<int, Map<dynamic, num>>();
    map<int, Map<Object?, num>>();
    set<String>();
    set<int>();
    set<Object?>();
    set<dynamic>();
    set<Object>();
    constMap(const <String, dynamic>{});
    constMap(const <String, Object?>{});
    constMap(const <String, Object>{});
    constMap(const <Object?, Object?>{});
    constMap(const <dynamic, dynamic>{});
    constMap(const <String, String>{});
    constMap(const <String, double>{});
    constMap(const <String, int>{});
    constMap(const <int, Object?>{});
    // Appended (earlier kinds keep their numbers): the chore engine's kept
    // property maps, read back as the same kind.
    _addMap(KeptMap<String, Object?>(), () => KeptMap<String, Object?>(), null);
  }

  /// A const map's kind (a const literal of [K], [V]): read back as an
  /// unmodifiable map of the same types.
  void constMap<K, V>(Map<K, V> proto) {
    // An empty one is the canonical const itself.
    Map<Object?, Object?> frozen(Map<Object?, Object?> m) =>
        m.isEmpty ? proto : Map<K, V>.unmodifiable(m as Map<K, V>);
    _addMap(proto, () => <K, V>{}, frozen);
    // A non-empty one is written as the unmodifiable map it reads back as
    // (no const can be made at run time), so a restored game writes the
    // same bytes.
    map<K, V>();
    constFrozen[mapKinds[proto.runtimeType]!] =
        mapKinds[Map<K, V>.unmodifiable(const {}).runtimeType]!;
  }

  /// A const map kind → the unmodifiable map kind of its types.
  final constFrozen = <int, int>{};

  final listKinds = <Type, int>{};
  final listMakers = <List<Object?> Function()>[];
  final listFinish = <List<Object?> Function(List<Object?>)?>[];
  final mapKinds = <Type, int>{};
  final mapMakers = <Map<Object?, Object?> Function()>[];
  final mapFinish = <Map<Object?, Object?> Function(Map<Object?, Object?>)?>[];
  final setKinds = <Type, int>{};
  final setMakers = <Set<Object?> Function()>[];

  void list<E>() {
    _addList(<E>[], () => <E>[], null);
    List<Object?> fixed(List<Object?> l) =>
        (l as List<E>).toList(growable: false);
    List<Object?> frozen(List<Object?> l) => List<E>.unmodifiable(l as List<E>);
    _addList(List<E>.empty(), () => <E>[], fixed);
    _addList(<E>[].toList(growable: false), () => <E>[], fixed);
    _addList(List<E>.unmodifiable(const []), () => <E>[], frozen);
    _addList(UnmodifiableListView<E>(<E>[]), () => <E>[], frozen);
  }

  void map<K, V>() {
    _addMap(<K, V>{}, () => <K, V>{}, null);
    Map<Object?, Object?> frozen(Map<Object?, Object?> m) =>
        Map<K, V>.unmodifiable(m as Map<K, V>);
    _addMap(Map<K, V>.unmodifiable(const {}), () => <K, V>{}, frozen);
    _addMap(UnmodifiableMapView<K, V>(<K, V>{}), () => <K, V>{}, frozen);
  }

  void set<E>() {
    if (setKinds.containsKey(<E>{}.runtimeType)) return;
    setKinds[<E>{}.runtimeType] = setMakers.length;
    setMakers.add(() => <E>{});
  }

  void _addList(
    List<Object?> proto,
    List<Object?> Function() make,
    List<Object?> Function(List<Object?>)? finish,
  ) {
    if (listKinds.containsKey(proto.runtimeType)) return;
    listKinds[proto.runtimeType] = listMakers.length;
    listMakers.add(make);
    listFinish.add(finish);
  }

  void _addMap(
    Map<Object?, Object?> proto,
    Map<Object?, Object?> Function() make,
    Map<Object?, Object?> Function(Map<Object?, Object?>)? finish,
  ) {
    if (mapKinds.containsKey(proto.runtimeType)) return;
    mapKinds[proto.runtimeType] = mapMakers.length;
    mapMakers.add(make);
    mapFinish.add(finish);
  }
}

final _kinds = _Kinds();

/// Adds a list element type the value codec knows (both sides, before use).
void snapListKind<E>() => _kinds.list<E>();

/// Adds a map type the value codec knows (both sides, before use).
void snapMapKind<K, V>() => _kinds.map<K, V>();

/// Adds a set type the value codec knows (both sides, before use).
void snapSetKind<E>() => _kinds.set<E>();

/// Adds the kind of const maps like [proto] (a const literal; both sides,
/// before use).
void snapConstMapKind<K, V>(Map<K, V> proto) => _kinds.constMap<K, V>(proto);

int _typedKind(TypedData t) => switch (t) {
  Uint8List() => 0,
  Int8List() => 1,
  Uint16List() => 2,
  Int16List() => 3,
  Uint32List() => 4,
  Int32List() => 5,
  Int64List() => 6,
  Float32List() => 7,
  Float64List() => 8,
  _ => -1,
};
