// The snapshot writer with its primitives, object bookkeeping and typed
// collections.
part of 'snap.dart';

/// Writes a snapshot stream.
class SnapWriter {
  SnapWriter(this.registry);

  final SnapRegistry registry;

  /// The values that codecs share during one write, by key.
  final env = <Object, Object?>{};
  Uint8List _buf = Uint8List(1 << 16);
  int _len = 0;
  late ByteData _bd = ByteData.sublistView(_buf);

  final _ids = HashMap<Object, int>.identity();
  int _next = 0;
  final _strings = HashMap<String, int>();
  final _queue = Queue<(Object, SnapCodec)>();

  // The parent of each object is the object whose state or constructor
  // inputs were being written when it was first met. Error messages show
  // the chain of parents with the tag of each object.
  final _parent = <int>[];
  final _tag = <String>[];
  final _current = <int>[];

  int _assign(Object o, String tag) {
    final id = _next++;
    _ids[o] = id;
    while (_parent.length < id) {
      _parent.add(-1);
      _tag.add('?');
    }
    _parent.add(_current.isEmpty ? -1 : _current.last);
    _tag.add(tag);
    return id;
  }

  int _originsOff = 0;

  /// The container types without a kind. They are written as containers of
  /// `Object?` and their element type is read back wider. Add a kind for
  /// each of them.
  final unknownKinds = <String>{};

  /// Runs [write] with origins off. Objects are written as they are, even
  /// where [SnapRegistry.originOf] gives them an origin. Use it to write the
  /// data that the origins refer to.
  void noOrigins(void Function() write) {
    _originsOff++;
    try {
      write();
    } finally {
      _originsOff--;
    }
  }

  /// Records the byte offset at the start of each object, for [at].
  bool trace = false;
  final _traceAt = <int>[];
  final _traceObj = <int>[];
  final _traceWhat = <String>[];

  void _mark(int id, String what) {
    if (!trace) return;
    _traceAt.add(_len);
    _traceObj.add(id);
    _traceWhat.add(what);
  }

  /// Adds the trace mark [what] of the caller, which [at] reports.
  void traceMark(String what) =>
      _mark(_current.isEmpty ? -1 : _current.last, what);

  /// Returns the bytes and objects of each traced kind, largest first, with
  /// [trace] on. The kind of an object is its start mark. It covers the
  /// bytes up to the next mark.
  List<(String, int, int)> traceStats() {
    final bytes = <String, int>{}, count = <String, int>{};
    for (var i = 0; i < _traceAt.length; i++) {
      final end = i + 1 < _traceAt.length ? _traceAt[i + 1] : _len;
      final k = _traceWhat[i].replaceAll(RegExp(r'<.*>'), '<>');
      bytes[k] = (bytes[k] ?? 0) + end - _traceAt[i];
      count[k] = (count[k] ?? 0) + 1;
    }
    return [for (final k in bytes.keys) (k, bytes[k]!, count[k]!)]
      ..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// Returns the path of the object that was written at byte [offset], with
  /// [trace] on.
  String at(int offset) {
    var lo = 0, hi = _traceAt.length - 1, best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_traceAt[mid] <= offset) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (best < 0) return 'before any object';
    final saved = [..._current];
    _current
      ..clear()
      ..add(_traceObj[best]);
    final p = path;
    _current
      ..clear()
      ..addAll(saved);
    return '${_traceWhat[best]} at +${offset - _traceAt[best]}: $p';
  }

  /// Returns the chain of objects that led to the first write of [o].
  String pathOf(Object o) {
    final id = _ids[o];
    if (id == null) return '(not written)';
    final saved = [..._current];
    _current
      ..clear()
      ..add(id);
    final p = path;
    _current
      ..clear()
      ..addAll(saved);
    return p;
  }

  /// The chain of objects that led to the object being written now.
  String get path {
    final out = <String>[];
    var id = _current.isEmpty ? -1 : _current.last;
    for (var guard = 0; id >= 0 && guard < 40; guard++) {
      out.add('${id < _tag.length ? _tag[id] : '?'}#$id');
      id = id < _parent.length ? _parent[id] : -1;
    }
    return out.reversed.join(' > ');
  }

  /// The number of objects written so far, the known ones included.
  int get objects => _next;

  /// The number of bytes written so far.
  int get length => _len;

  void _grow(int n) {
    if (_len + n <= _buf.length) return;
    var size = _buf.length * 2;
    while (size < _len + n) {
      size *= 2;
    }
    final b = Uint8List(size)..setRange(0, _len, _buf);
    _buf = b;
    _bd = ByteData.sublistView(_buf);
  }

  /// Returns the stream written so far.
  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);

  // --- primitives ------------------------------------------------------------

  void byte(int b) {
    _grow(1);
    _buf[_len++] = b;
  }

  /// Writes a non-negative int.
  void uint(int v) {
    if (v < 0) throw SnapError('uint $v < 0 (${_where()})');
    _grow(10);
    while (v >= 0x80) {
      _buf[_len++] = (v & 0x7f) | 0x80;
      v >>>= 7;
    }
    _buf[_len++] = v;
  }

  /// Writes any 64-bit int in zigzag form.
  void int_(int v) {
    var z = (v << 1) ^ (v >> 63);
    _grow(10);
    while (z & ~0x7f != 0) {
      _buf[_len++] = (z & 0x7f) | 0x80;
      z >>>= 7;
    }
    _buf[_len++] = z;
  }

  void boolean(bool b) => byte(b ? 1 : 0);

  /// Writes every bit of a double, NaN payloads and −0 included.
  void f64(double v) {
    _grow(8);
    _bd.setFloat64(_len, v, Endian.little);
    _len += 8;
  }

  void str(String s) {
    final i = _strings[s];
    if (i != null) {
      uint(i);
      return;
    }
    final n = _strings.length;
    _strings[s] = n;
    uint(n);
    uint(s.length);
    _grow(s.length * 3);
    // A Dart string holds UTF-16 code units. Each is written as a uint16.
    for (var k = 0; k < s.length; k++) {
      final c = s.codeUnitAt(k);
      if (c < 0x80) {
        _buf[_len++] = c;
      } else {
        _buf[_len++] = 0x80 | (c & 0x7f);
        _buf[_len++] = c >> 7;
        if (c >= 0x4000) {
          _buf[_len - 1] |= 0x80;
          _buf[_len++] = c >> 14;
        }
      }
    }
  }

  void strOrNull(String? s) {
    if (s == null) {
      byte(0);
    } else {
      byte(1);
      str(s);
    }
  }

  void bytes(Uint8List b) {
    uint(b.length);
    _grow(b.length);
    _buf.setRange(_len, _len + b.length, b);
    _len += b.length;
  }

  /// Writes a section marker that [SnapReader.mark] checks.
  void mark(int m) => uint(m);

  // --- objects ---------------------------------------------------------------

  /// Registers an object that the reader already has. Both sides register
  /// in the same order.
  void known(Object o) {
    if (_ids.containsKey(o)) throw SnapError('known object registered twice');
    _assign(o, 'known ${o.runtimeType}');
  }

  /// Returns true when [o] has been written or registered.
  bool has(Object o) => _ids.containsKey(o);

  int _strong = -1;

  /// Marks the objects written so far as the strongly held graph. Weak
  /// tables written after it list only the entries whose keys are in it. An
  /// entry whose key only the value of another weak table holds is garbage
  /// that is not yet collected.
  void sealStrong() => _strong = _next;

  /// Returns true when [o] is in the strongly held graph of [sealStrong].
  /// Before [sealStrong], returns true when [o] was written.
  bool heldStrongly(Object o) {
    final id = _ids[o];
    return id != null && (_strong < 0 || id < _strong);
  }

  /// Queues the state of [o] for [SnapCodec.write] by [codec] or by the
  /// codec of its class.
  void fillKnown(Object o, [SnapCodec? codec]) {
    final c = codec ?? registry.codecOf(o);
    if (c == null) throw SnapError('no codec for ${o.runtimeType}');
    if (!_ids.containsKey(o)) {
      throw SnapError('${o.runtimeType} filled but not known');
    }
    _queue.add((o, c));
  }

  /// Writes every queued object's state.
  void finish() {
    while (_queue.isNotEmpty) {
      final (o, c) = _queue.removeFirst();
      final id = _ids[o]!;
      uint(id);
      _current
        ..clear()
        ..add(id);
      if (trace) _mark(id, 'state of ${c.tag}');
      c.write(this, o);
      _current.removeLast();
    }
    uint(0x7fffffff);
  }

  /// The path of the object being written now, for error messages.
  String get where => _where();

  String _where() => 'path ${_current.isEmpty ? 'top' : path}';

  /// Writes a value. A value is null, a bool, an int, a double, a String, a
  /// container of values with its identity kept, typed data, a function with
  /// a recipe or an object with a codec.
  void value(Object? v) {
    switch (v) {
      case null:
        byte(_tNull);
      case true:
        byte(_tTrue);
      case false:
        byte(_tFalse);
      case final int i:
        byte(_tInt);
        int_(i);
      case final double d:
        byte(_tDouble);
        f64(d);
      case final String s:
        byte(_tString);
        str(s);
      default:
        _object(v);
    }
  }

  /// Writes an object reference with its identity kept, as [value] does.
  void ref(Object? o) => value(o);

  /// Starts an object that the caller writes, such as a typed collection kept
  /// by identity or an object of a class without a codec. Returns true when
  /// [o] is new and the caller writes it now. Returns false when a reference
  /// was written.
  bool begin(Object o) {
    final id = _ids[o];
    if (id != null) {
      byte(_tRef);
      uint(id);
      return false;
    }
    _assign(o, 'custom ${o.runtimeType}');
    byte(_tCustom);
    return true;
  }

  // --- typed collections without identity ------------------------------------

  void list<T>(List<T> l, void Function(T e) write) {
    uint(l.length);
    for (var i = 0; i < l.length; i++) {
      write(l[i]);
    }
  }

  void iter<T>(Iterable<T> l, void Function(T e) write) {
    final items = l is List<T> ? l : l.toList();
    uint(items.length);
    for (final e in items) {
      write(e);
    }
  }

  void map<K, V>(
    Map<K, V> m,
    void Function(K k) writeKey,
    void Function(V v) writeValue,
  ) {
    uint(m.length);
    m.forEach((k, v) {
      writeKey(k);
      writeValue(v);
    });
  }

  /// Writes a list of values and references.
  void values(Iterable<Object?> l) => iter<Object?>(l, value);

  void doubles(List<double> l) => list<double>(l, f64);
  void ints(List<int> l) => list<int>(l, int_);
  void strs(Iterable<String> l) => iter<String>(l, str);

  void f64OrNull(double? v) {
    if (v == null) {
      byte(0);
    } else {
      byte(1);
      f64(v);
    }
  }

  void intOrNull(int? v) {
    if (v == null) {
      byte(0);
    } else {
      byte(1);
      int_(v);
    }
  }

  void boolOrNull(bool? v) => byte(v == null ? 2 : (v ? 1 : 0));
}
