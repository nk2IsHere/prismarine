import 'dart:convert';
import 'dart:io';

import 'route_hash.dart';

/// The format of a route. The header line is a JSON object whose first key
/// is [marker] with [version] as its value.
final class RouteFormat {
  const RouteFormat(this.marker, {this.version = 1});
  final String marker;
  final int version;
}

/// A change that the host made to the simulation outside its input. A
/// route records it under the `host` key of the next frame line.
abstract interface class HostChange {
  /// The change as a JSON value.
  Object toJson();
}

/// Records a route, one line per frame after a header line.
class RouteRecorder {
  /// Starts a route with [header], the fields after the marker of [format].
  RouteRecorder(RouteFormat format, Map<String, Object?> header, {IOSink? sink})
    : _sink = sink {
    final line = jsonEncode(<String, Object?>{
      format.marker: format.version,
      ...header,
    });
    _lines.add(line);
    routeHash = routeLineHash(routeHashSeed, line);
    _sink?.writeln(line);
  }

  /// Goes on from [lines], the header and the first frames of a route. A run
  /// restored from a snapshot taken after them records on.
  RouteRecorder.resume(List<String> lines, {IOSink? sink}) : _sink = sink {
    var h = routeHashSeed;
    for (final l in lines) {
      _lines.add(l);
      h = routeLineHash(h, l);
      _sink?.writeln(l);
    }
    routeHash = h;
  }

  IOSink? _sink;
  final _lines = <String>[];
  final _changes = <HostChange>[];

  /// The hash after the last line.
  int routeHash = routeHashSeed;

  /// Called with each frame line as it is recorded.
  void Function(String line)? onLine;

  /// The frames recorded so far.
  int get frames => _lines.length - 1;

  /// The lines so far, header first.
  List<String> get lines => _lines;

  /// Queues [change] for the next frame line.
  void hostChange(HostChange change) => _changes.add(change);

  /// Records a frame of [dt] seconds with the game's [fields] after `dt` and
  /// the queued host changes after them. Returns the line.
  String addFrame(double dt, Map<String, Object?> fields) {
    final line = jsonEncode(<String, Object?>{
      'dt': dt,
      ...fields,
      if (_changes.isNotEmpty) 'host': [for (final c in _changes) c.toJson()],
    });
    _changes.clear();
    _lines.add(line);
    routeHash = routeLineHash(routeHash, line);
    _sink?.writeln(line);
    onLine?.call(line);
    return line;
  }

  /// Sends the lines so far to [sink] and every later line as it comes.
  void sinkTo(IOSink sink) {
    for (final l in _lines) {
      sink.writeln(l);
    }
    _sink = sink;
  }

  /// Returns the route so far as JSON lines.
  String toJsonLines() => '${_lines.join('\n')}\n';
}

/// Reads a route and plays its frames in order. The header holds `seed`
/// and, optionally, `t0` and `frame0`.
class RouteReader {
  /// Reads [raw], a header line and frame lines. Throws a [FormatException]
  /// when the first line has no marker of [format].
  RouteReader(List<String> raw, {required RouteFormat format, this.path})
    : _hashes = _hashesOf(raw),
      _frames = [for (final l in raw.skip(1)) _decode(l)],
      header = raw.isEmpty ? const {} : _decode(raw.first) {
    if (raw.isEmpty || header[format.marker] == null) {
      throw FormatException('not a route: no ${format.marker} header line');
    }
    seed = (header['seed']! as num).toInt();
  }

  static Map<String, Object?> _decode(String line) =>
      jsonDecode(line) as Map<String, Object?>;

  static List<int> _hashesOf(List<String> raw) {
    final hashes = <int>[];
    var hash = routeHashSeed;
    for (final l in raw) {
      hashes.add(hash = routeLineHash(hash, l));
    }
    return hashes;
  }

  /// Splits [text] into its lines without the blank ones.
  static List<String> splitLines(String text) => const LineSplitter()
      .convert(text)
      .where((l) => l.trim().isNotEmpty)
      .toList();

  /// The file that the route was read from, if any.
  final String? path;

  /// The header line's fields.
  final Map<String, Object?> header;

  /// The seed of the run.
  late final int seed;

  /// The simulated time at the first frame.
  late final double t0 = (header['t0'] as num? ?? 0).toDouble();

  /// The frame count at the first frame.
  late final int frame0 = (header['frame0'] as num? ?? 0).toInt();

  final List<int> _hashes;
  final List<Map<String, Object?>> _frames;
  int _next = 0;

  /// Adds a frame line at the end, for a route read while it is recorded.
  void addLine(String line) {
    _hashes.add(routeLineHash(_hashes.last, line));
    _frames.add(_decode(line));
  }

  /// Returns the route hash after the header and the first [frames] frames.
  int hashAt(int frames) => _hashes[frames];

  /// The frames in the route.
  int get length => _frames.length;

  /// The frames left to play.
  int get remaining => _frames.length - _next;

  /// The frames played so far.
  int get played => _next;

  /// Returns frame [i], from 0.
  Map<String, Object?> frameAt(int i) => _frames[i];

  /// Returns the next frame and moves past it, or null at the end.
  Map<String, Object?>? next() =>
      _next < _frames.length ? _frames[_next++] : null;

  /// Moves to the point after [frames] frames, for a sim restored from a
  /// snapshot taken there.
  void skipTo(int frames) {
    if (frames < 0 || frames > _frames.length) {
      throw RangeError.range(frames, 0, _frames.length, 'frames');
    }
    _next = frames;
  }

  /// Returns the header and the first [frames] frame lines as written in
  /// [path].
  List<String> prefixLines(int frames) {
    final p = path;
    if (p == null) throw StateError('a route read from no file');
    return splitLines(File(p).readAsStringSync()).take(frames + 1).toList();
  }
}
