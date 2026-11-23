// JSON lines written into kept bytes and to a file by synchronous writes,
// without a string, a map or a sink buffer per line (perf: the profiler's
// and the run trace's line each frame were the UI isolate's own garbage).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One JSON object per line, built by calls: [begin], then [key] and a
/// value each ([number], [integer], [boolean], [string], [nil], [value], or
/// [beginList] … [endList] with values between), then [end].
/// [buffer]: bytes kept before a write (0: every line is written at its
/// [end], for a record that must survive a crash).
final class JsonLineWriter {
  JsonLineWriter(String path, {this.buffer = 0})
    : _file = File(path).openSync(mode: FileMode.write);

  final RandomAccessFile _file;
  final int buffer;
  Uint8List _b = Uint8List(4096);
  int _n = 0;
  bool _closed = false;

  /// Whether the next value at each depth is its first (no comma before).
  final _first = Uint8List(32);
  int _depth = 0;

  /// Each key as `"key":` in bytes, made once.
  final _keys = <String, Uint8List>{};

  void _room(int n) {
    if (_n + n <= _b.length) return;
    var size = _b.length * 2;
    while (size < _n + n) {
      size *= 2;
    }
    _b = Uint8List(size)..setRange(0, _n, _b);
  }

  @pragma('vm:prefer-inline')
  void _byte(int c) {
    if (_n == _b.length) _room(1);
    _b[_n++] = c;
  }

  void _sep() {
    if (_first[_depth] == 0) {
      _byte(0x2c);
    } else {
      _first[_depth] = 0;
    }
  }

  void begin() {
    _depth = 0;
    _first[0] = 1;
    _byte(0x7b);
  }

  /// The next value's key (in the line's object or a nested one).
  void key(String k) {
    _sep();
    final bytes = _keys[k] ??= Uint8List.fromList(
      utf8.encode('${jsonEncode(k)}:'),
    );
    _room(bytes.length);
    _b.setRange(_n, _n + bytes.length, bytes);
    _n += bytes.length;
    // The value follows its key without a comma.
    _first[_depth] = 1;
  }

  void beginList() {
    _sep();
    _byte(0x5b);
    _first[++_depth] = 1;
  }

  void endList() {
    _depth--;
    _byte(0x5d);
  }

  void beginObject() {
    _sep();
    _byte(0x7b);
    _first[++_depth] = 1;
  }

  void endObject() {
    _depth--;
    _byte(0x7d);
  }

  void nil() {
    _sep();
    _ascii('null');
  }

  void boolean(bool v) {
    _sep();
    _ascii(v ? 'true' : 'false');
  }

  void integer(int v) {
    _sep();
    _int(v);
  }

  /// [v] with up to [decimals] decimals (trailing zeros dropped, one kept:
  /// a double reads back as a double); null when it is not finite.
  void number(double v, [int decimals = 6]) {
    _sep();
    if (!v.isFinite) {
      _ascii('null');
      return;
    }
    var scale = 1;
    for (var i = 0; i < decimals; i++) {
      scale *= 10;
    }
    final a = v.abs() * scale;
    if (a >= 9e15) {
      // Past exact integers at this scale (rare): the VM's own digits.
      _ascii(v.toString());
      return;
    }
    final scaled = a.round();
    if (v < 0 && scaled != 0) _byte(0x2d);
    _int(scaled ~/ scale);
    _byte(0x2e);
    var frac = scaled % scale;
    // The fraction's digits from the top, zeros at the end dropped.
    var div = scale ~/ 10;
    if (frac == 0 || div == 0) {
      _byte(0x30);
      return;
    }
    while (frac != 0 && div != 0) {
      _byte(0x30 + frac ~/ div);
      frac %= div;
      div ~/= 10;
    }
  }

  void string(String s) {
    _sep();
    _byte(0x22);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x20 && c < 0x7f && c != 0x22 && c != 0x5c) {
        _byte(c);
      } else {
        // An escape or a character past ASCII (rare): the encoder's form.
        final e = utf8.encode(jsonEncode(String.fromCharCode(c)));
        for (var k = 1; k < e.length - 1; k++) {
          _byte(e[k]);
        }
      }
    }
    _byte(0x22);
  }

  /// Any JSON value: numbers, strings, bools, null, lists and maps with
  /// string keys of them; anything else by its string.
  void value(Object? v) {
    switch (v) {
      case null:
        nil();
      case final bool b:
        boolean(b);
      case final int i:
        integer(i);
      case final double d:
        number(d);
      case final String s:
        string(s);
      case final List<Object?> l:
        beginList();
        for (var i = 0; i < l.length; i++) {
          value(l[i]);
        }
        endList();
      case final Map<Object?, Object?> m:
        beginObject();
        m.forEach(_entry_);
        endObject();
      default:
        string('$v');
    }
  }

  late final _entry_ = _entry;

  void _entry(Object? k, Object? v) {
    key('$k');
    value(v);
  }

  void _ascii(String s) {
    _room(s.length);
    for (var i = 0; i < s.length; i++) {
      _b[_n++] = s.codeUnitAt(i);
    }
  }

  void _int(int v) {
    if (v < 0) {
      _byte(0x2d);
      v = -v;
    }
    var div = 1;
    while (v ~/ div >= 10) {
      div *= 10;
    }
    while (div != 0) {
      _byte(0x30 + v ~/ div);
      v %= div;
      div ~/= 10;
    }
  }

  /// Ends the line; written now, or once [buffer] bytes are kept.
  void end() {
    _byte(0x7d);
    _byte(0x0a);
    if (_n >= buffer) flush();
  }

  void flush() {
    if (_closed || _n == 0) return;
    _file.writeFromSync(_b, 0, _n);
    _n = 0;
  }

  void close() {
    if (_closed) return;
    flush();
    _closed = true;
    _file.closeSync();
  }
}
