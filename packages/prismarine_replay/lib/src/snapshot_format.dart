import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'route.dart';
import 'route_hash.dart';

/// One snapshot file and its header.
class SnapshotFile {
  SnapshotFile(this.path, this.header);

  final String path;
  final Map<String, Object?> header;

  /// The route frames played before the snapshot.
  int get frames => (header['frames']! as num).toInt();

  /// The simulated time of the snapshot.
  double get time => (header['time']! as num).toDouble();

  /// The route hash after the header and the first [frames] frames.
  int get routeHash => parseRouteHash(header['routeHash']! as String);

  /// Reads the body and decompresses it.
  Uint8List body() {
    final bytes = File(path).readAsBytesSync();
    final nl = bytes.indexOf(10);
    return Uint8List.fromList(
      zlib.decode(Uint8List.sublistView(bytes, nl + 1)),
    );
  }
}

/// The format of a game's snapshot files. A file is one JSON header line,
/// then the body compressed with zlib. The header's `format` is [name] and
/// its `version` is [version], the version of the body.
final class SnapshotFormat {
  const SnapshotFormat(this.name, this.version);
  final String name;
  final int version;

  /// Opens the snapshot at [path]. Returns null when the file is no
  /// snapshot of this format and version.
  SnapshotFile? open(String path) {
    try {
      final f = File(path).openSync();
      try {
        final head = <int>[];
        while (head.length < 1 << 16) {
          final b = f.readByteSync();
          if (b < 0 || b == 10) break;
          head.add(b);
        }
        final h = jsonDecode(utf8.decode(head));
        if (h is! Map || h['format'] != name) return null;
        if (h['version'] != version) return null;
        return SnapshotFile(path, h.cast<String, Object?>());
      } finally {
        f.closeSync();
      }
    } on Object {
      return null;
    }
  }

  /// Returns the snapshots in [dir], oldest first.
  List<SnapshotFile> list(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return [
      for (final f in d.listSync().whereType<File>())
        if (f.path.endsWith('.snap')) ?open(f.path),
    ]..sort((a, b) => a.frames.compareTo(b.frames));
  }

  /// Returns the latest snapshot of [route] in [dirs] taken at or before
  /// frame [frames], or null.
  SnapshotFile? latestFor(
    RouteReader route, {
    required int frames,
    required List<String> dirs,
  }) => _latest(route, dirs, (s) => s.frames <= frames);

  /// Returns the latest snapshot of [route] in [dirs] taken at or before
  /// the simulated time [time], or null.
  SnapshotFile? latestBeforeTime(
    RouteReader route, {
    required double time,
    required List<String> dirs,
  }) => _latest(route, dirs, (s) => s.time <= time);

  SnapshotFile? _latest(
    RouteReader route,
    List<String> dirs,
    bool Function(SnapshotFile) before,
  ) {
    SnapshotFile? best;
    for (final dir in dirs) {
      for (final s in list(dir)) {
        if (!before(s) || s.frames > route.length) continue;
        if (route.hashAt(s.frames) != s.routeHash) continue;
        if (best == null || s.frames > best.frames) best = s;
      }
    }
    return best;
  }

  /// Returns the header of a snapshot taken after [frames] route frames
  /// whose hash is [routeHash]. The game's [fields] follow the route hash.
  Map<String, Object?> header({
    required int frames,
    required double time,
    required int frame,
    required int routeHash,
    Map<String, Object?> fields = const {},
    required int bodyBytes,
    required double writeMs,
    String? reason,
  }) => {
    'format': name,
    'version': version,
    'frames': frames,
    'time': time,
    'frame': frame,
    'routeHash': routeHashText(routeHash),
    ...fields,
    'bodyBytes': bodyBytes,
    'writeMs': (writeMs * 100).round() / 100,
    'reason': ?reason,
  };

  /// Writes a snapshot file to a temporary file and renames it to [path].
  /// A reader does not see a file half written.
  void writeSync(String path, Map<String, Object?> header, Uint8List body) {
    final f = File(path)..parent.createSync(recursive: true);
    final tmp = File('$path.tmp')
      ..writeAsBytesSync(snapshotFileBytes(header, body));
    tmp.renameSync(f.path);
  }

  /// Runs [writeSync] on a worker isolate, then [prune] in the folder of
  /// [path] at the simulated time [pruneAt] when given. Returns the size of
  /// the file.
  Future<int> write(
    String path,
    Map<String, Object?> header,
    Uint8List body, {
    double? pruneAt,
  }) {
    final data = TransferableTypedData.fromList([body]);
    return Isolate.run(() {
      writeSync(path, header, data.materialize().asUint8List());
      if (pruneAt != null) prune(File(path).parent.path, now: pruneAt);
      return File(path).lengthSync();
    }, debugName: 'snapshot write');
  }

  /// Deletes the snapshots in [dir] that a run no longer needs. Every one of
  /// the last [recent] seconds before [now] stays. Before that the latest of
  /// each [span] seconds stays. Returns the deleted paths.
  List<String> prune(
    String dir, {
    required double now,
    double recent = 600,
    double span = 300,
  }) {
    final all = list(dir);
    final keep = <String>{};
    final latestOf = <int, SnapshotFile>{};
    for (final s in all) {
      if (s.time >= now - recent) {
        keep.add(s.path);
        continue;
      }
      final b = (s.time / span).floor();
      final cur = latestOf[b];
      if (cur == null || s.frames > cur.frames) latestOf[b] = s;
    }
    keep.addAll([for (final s in latestOf.values) s.path]);
    final gone = <String>[];
    for (final s in all) {
      if (keep.contains(s.path)) continue;
      try {
        File(s.path).deleteSync();
        gone.add(s.path);
      } on FileSystemException {
        // Still being written or deleted already.
      }
    }
    return gone;
  }
}

/// Returns the bytes of a snapshot file, the header line followed by [body]
/// compressed.
Uint8List snapshotFileBytes(Map<String, Object?> header, Uint8List body) {
  final head = utf8.encode('${jsonEncode(header)}\n');
  final z = ZLibCodec(level: 6).encode(body);
  return Uint8List(head.length + z.length)
    ..setAll(0, head)
    ..setAll(head.length, z);
}

/// Returns the file name of a snapshot taken after [frames] route frames.
String snapshotFileName(int frames) =>
    '${frames.toString().padLeft(9, '0')}.snap';

/// Returns a rough size for logs, in KB or MB.
String snapshotSize(int bytes) => bytes >= 1 << 20
    ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
    : '${math.max(1, bytes >> 10)} KB';
