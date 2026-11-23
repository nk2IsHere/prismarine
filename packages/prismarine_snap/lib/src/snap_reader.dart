// The snapshot reader.
part of 'snap.dart';

/// Reads a snapshot stream written by [SnapWriter].
class SnapReader {
  SnapReader(this.registry, Uint8List bytes)
    : _buf = bytes,
      _bd = ByteData.sublistView(bytes);

  final SnapRegistry registry;

  /// What codecs share during one read, by key.
  final env = <Object, Object?>{};
  final Uint8List _buf;
  final ByteData _bd;
  int _pos = 0;
  final _objs = <Object?>[];
  final _strings = <String>[];
  final _queue = Queue<(Object, SnapCodec)>();

  /// Objects read so far (known ones included).
  int get objects => _objs.length;

  /// Every object read so far, by its index (a restore's consistency checks).
  List<Object?> get table => _objs;

  // --- primitives ------------------------------------------------------------

  int byte() => _buf[_pos++];

  int uint() {
    var v = 0, shift = 0;
    while (true) {
      final b = _buf[_pos++];
      v |= (b & 0x7f) << shift;
      if (b < 0x80) return v;
      shift += 7;
    }
  }

  int int_() {
    var z = 0, shift = 0;
    while (true) {
      final b = _buf[_pos++];
      z |= (b & 0x7f) << shift;
      if (b < 0x80) break;
      shift += 7;
    }
    return (z >>> 1) ^ -(z & 1);
  }

  bool boolean() => byte() != 0;

  double f64() {
    final v = _bd.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  String str() {
    final i = uint();
    if (i < _strings.length) return _strings[i];
    if (i != _strings.length) throw SnapError('string table out of step');
    final n = uint();
    final units = Uint16List(n);
    for (var k = 0; k < n; k++) {
      final b = _buf[_pos++];
      if (b < 0x80) {
        units[k] = b;
      } else {
        final b1 = _buf[_pos++];
        var c = (b & 0x7f) | ((b1 & 0x7f) << 7);
        if (b1 >= 0x80) c |= _buf[_pos++] << 14;
        units[k] = c;
      }
    }
    final s = String.fromCharCodes(units);
    _strings.add(s);
    return s;
  }

  String? strOrNull() => byte() == 0 ? null : str();

  Uint8List bytes() {
    final n = uint();
    final b = Uint8List.fromList(Uint8List.sublistView(_buf, _pos, _pos + n));
    _pos += n;
    return b;
  }

  void mark(int m) {
    final got = uint();
    if (got != m) throw SnapError('out of step: mark $got, expected $m');
  }

  // --- objects ---------------------------------------------------------------

  void known(Object o) => _objs.add(o);

  void fillKnown(Object o, [SnapCodec? codec]) {
    final c = codec ?? registry.codecOf(o);
    if (c == null) throw SnapError('no codec for ${o.runtimeType}');
    _queue.add((o, c));
  }

  /// Reads every queued object's state, as [SnapWriter.finish] wrote it.
  void finish() {
    while (_queue.isNotEmpty) {
      final (o, c) = _queue.removeFirst();
      final id = uint();
      if (id >= _objs.length || !identical(_objs[id], o)) {
        throw SnapError('out of step at ${c.tag}: object $id');
      }
      c.read(this, o);
    }
    final end = uint();
    if (end != 0x7fffffff) throw SnapError('out of step at the end');
  }

  Object? value() {
    final t = byte();
    switch (t) {
      case _tNull:
        return null;
      case _tFalse:
        return false;
      case _tTrue:
        return true;
      case _tInt:
        return int_();
      case _tDouble:
        return f64();
      case _tString:
        return str();
      case _tRef:
        return _objs[uint()];
      case _tObject:
        final tag = str();
        final codec = registry.codecByTag(tag);
        if (codec == null) throw SnapError('no codec for tag $tag');
        final slot = _objs.length;
        _objs.add(null);
        final o = codec.make(this);
        _objs[slot] = o;
        if (codec.hasState) _queue.add((o, codec));
        return o;
      case _tTyped:
        final k = byte();
        final slot = _objs.length;
        _objs.add(null);
        final b = bytes();
        // Typed lists of their own (not views), byte for byte.
        final TypedData o = switch (k) {
          0 => b,
          1 => Int8List(b.length),
          2 => Uint16List(b.length >> 1),
          3 => Int16List(b.length >> 1),
          4 => Uint32List(b.length >> 2),
          5 => Int32List(b.length >> 2),
          6 => Int64List(b.length >> 3),
          7 => Float32List(b.length >> 2),
          _ => Float64List(b.length >> 3),
        };
        if (k != 0) {
          o.buffer.asUint8List(o.offsetInBytes, b.length).setAll(0, b);
        }
        _objs[slot] = o;
        return o;
      case _tList:
        final k = uint();
        final n = uint();
        final l = _kinds.listMakers[k]();
        final slot = _objs.length;
        _objs.add(l);
        for (var i = 0; i < n; i++) {
          l.add(value());
        }
        if (_kinds.listFinish[k] case final f?) {
          final done = f(l);
          _objs[slot] = done;
          return done;
        }
        return l;
      case _tMap:
        final k = uint();
        final n = uint();
        final m = _kinds.mapMakers[k]();
        final slot = _objs.length;
        _objs.add(m);
        for (var i = 0; i < n; i++) {
          final key = value();
          m[key] = value();
        }
        if (_kinds.mapFinish[k] case final f?) {
          final done = f(m);
          _objs[slot] = done;
          return done;
        }
        return m;
      case _tSet:
        final k = uint();
        final n = uint();
        final s = _kinds.setMakers[k]();
        _objs.add(s);
        for (var i = 0; i < n; i++) {
          s.add(value());
        }
        return s;
      case _tFn:
        final kind = str();
        final slot = _objs.length;
        _objs.add(null);
        final n = uint();
        final args = [for (var i = 0; i < n; i++) value()];
        final f = registry.factoryOf(kind);
        if (f == null) throw SnapError('no factory for closure $kind');
        final fn = f(args);
        _recipes[fn] = (kind, args);
        _objs[slot] = fn;
        return fn;
      case _tRecord:
        final tag = str();
        final codec = registry.codecByTag(tag);
        if (codec == null) throw SnapError('no codec for record $tag');
        return codec.make(this);
      case _tOrigin:
        final kind = str();
        final slot = _objs.length;
        _objs.add(null);
        final args = values();
        final f = registry.resolveOrigin;
        if (f == null) throw SnapError('no resolver for origin $kind');
        final o = f(this, kind, args);
        _objs[slot] = o;
        if (boolean()) {
          if (o is List) {
            final content = values();
            o
              ..clear()
              ..addAll(content);
          } else {
            final m = o as Map;
            final n = uint();
            final entries = [for (var i = 0; i < n; i++) (value(), value())];
            m.clear();
            for (final (k, v) in entries) {
              m[k] = v;
            }
          }
          registry.patchedOrigin?.call(o);
        }
        return o;
      case _tCustom:
        throw SnapError('a custom object read as a value');
      default:
        throw SnapError('bad value tag $t at $_pos');
    }
  }

  /// A reference read as [T].
  T ref<T>() => value() as T;

  /// An object written with [SnapWriter.begin]: [create] makes it (it is
  /// registered at once), [fill] reads the rest.
  T begin<T extends Object>(T Function() create, [void Function(T o)? fill]) {
    final t = byte();
    if (t == _tRef) return _objs[uint()] as T;
    if (t != _tCustom) throw SnapError('expected a custom object, tag $t');
    final slot = _objs.length;
    _objs.add(null);
    final o = create();
    _objs[slot] = o;
    fill?.call(o);
    return o;
  }

  // --- typed collections without identity ------------------------------------

  List<T> list<T>(T Function() read) {
    final n = uint();
    return [for (var i = 0; i < n; i++) read()];
  }

  /// Clears [target] and fills it.
  void listInto<T>(List<T> target, T Function() read) {
    target.clear();
    final n = uint();
    for (var i = 0; i < n; i++) {
      target.add(read());
    }
  }

  void setInto<T>(Set<T> target, T Function() read) {
    target.clear();
    final n = uint();
    for (var i = 0; i < n; i++) {
      target.add(read());
    }
  }

  Map<K, V> map<K, V>(K Function() readKey, V Function() readValue) {
    final n = uint();
    final m = <K, V>{};
    for (var i = 0; i < n; i++) {
      final k = readKey();
      m[k] = readValue();
    }
    return m;
  }

  void mapInto<K, V>(
    Map<K, V> target,
    K Function() readKey,
    V Function() readValue,
  ) {
    target.clear();
    final n = uint();
    for (var i = 0; i < n; i++) {
      final k = readKey();
      target[k] = readValue();
    }
  }

  List<Object?> values() => list<Object?>(value);
  List<double> doubles() => list<double>(f64);
  List<int> ints() => list<int>(int_);
  List<String> strs() => list<String>(str);

  double? f64OrNull() => byte() == 0 ? null : f64();
  int? intOrNull() => byte() == 0 ? null : int_();
  bool? boolOrNull() => switch (byte()) {
    0 => false,
    1 => true,
    _ => null,
  };

  /// Whether the whole stream was read.
  bool get atEnd => _pos == _buf.length;
}
