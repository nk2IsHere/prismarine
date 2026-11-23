import 'dart:convert';
import 'dart:io';

/// Returns the value of the option `--<name>=<value>` in [args], or null.
String? opt(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

/// Reads the lines of a text file, gzip-compressed when its path ends in
/// `.gz`, one at a time in 1 MiB reads.
class LineReader {
  LineReader(String path) : _raf = File(path).openSync() {
    final lines = _LinesSink(_queue);
    final text = const Utf8Decoder().startChunkedConversion(
      const LineSplitter().startChunkedConversion(lines),
    );
    _bytes = path.endsWith('.gz')
        ? ZLibDecoder(gzip: true).startChunkedConversion(text)
        : text;
  }
  final RandomAccessFile _raf;
  late final ByteConversionSink _bytes;
  final _queue = <String>[];
  var _head = 0;
  var _done = false;

  /// Returns the next line without taking it, or null at the end.
  String? peek() {
    while (_head >= _queue.length && !_done) {
      _queue.removeRange(0, _head);
      _head = 0;
      final chunk = _raf.readSync(1 << 20);
      if (chunk.isEmpty) {
        _done = true;
        _bytes.close();
        _raf.closeSync();
      } else {
        _bytes.add(chunk);
      }
    }
    return _head < _queue.length ? _queue[_head] : null;
  }

  /// Takes the next line, or returns null at the end.
  String? next() {
    final l = peek();
    if (l != null) _head++;
    return l;
  }
}

class _LinesSink implements Sink<String> {
  _LinesSink(this.out);
  final List<String> out;
  @override
  void add(String data) => out.add(data);
  @override
  void close() {}
}

/// Writes lines to a gzip file at level 6, in blocks of about 1 MiB.
class GzWriter {
  GzWriter(String path) : _raf = File(path).openSync(mode: FileMode.write) {
    _sink = ZLibEncoder(
      gzip: true,
      level: 6,
    ).startChunkedConversion(_RafSink(_raf));
  }
  final RandomAccessFile _raf;
  late final ByteConversionSink _sink;
  final _buf = StringBuffer();

  void writeln(String s) {
    _buf.writeln(s);
    if (_buf.length > 1 << 20) _flush();
  }

  void _flush() {
    _sink.add(utf8.encode(_buf.toString()));
    _buf.clear();
  }

  void close() {
    _flush();
    _sink.close();
    _raf.closeSync();
  }
}

class _RafSink implements Sink<List<int>> {
  _RafSink(this.raf);
  final RandomAccessFile raf;
  @override
  void add(List<int> data) => raf.writeFromSync(data);
  @override
  void close() {}
}

/// Reads a route file as text, gzip-compressed when its path ends in `.gz`.
String readRoute(String path) {
  final bytes = File(path).readAsBytesSync();
  return utf8.decode(path.endsWith('.gz') ? gzip.decode(bytes) : bytes);
}

/// Returns true when [s] matches [pattern], in which `*` matches any text.
bool glob(String pattern, String s) =>
    RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$').hasMatch(s);
