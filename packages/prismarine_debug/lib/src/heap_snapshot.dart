import 'dart:developer' show NativeRuntime;
import 'dart:io';

/// `PRISMARINE_HEAP_SNAPSHOT=<dir>:<t>,<t>…`: at the first tick at or past
/// each game time t, the isolate group's heap (every isolate of the group
/// alike) is written to `<dir>/heap-<t>.dartheap`, the VM service's snapshot
/// format (`HeapSnapshotGraph.fromChunks` reads it). Profile and debug builds
/// only:
/// a release (product) VM has no snapshot writer, so it logs that once.
/// Diagnostics; the write holds every isolate for its seconds.
final class HeapSnapshots {
  HeapSnapshots._(this._dir, this._times);

  static HeapSnapshots? fromEnvironment() {
    final v =
        Platform.environment['PRISMARINE_HEAP_SNAPSHOT'] ??
        Platform.environment['MCSM_HEAP_SNAPSHOT'];
    if (v == null || v.isEmpty) return null;
    final at = v.lastIndexOf(':');
    if (at < 0) return null;
    final times = [
      for (final s in v.substring(at + 1).split(',')) ?double.tryParse(s),
    ]..sort();
    if (times.isEmpty) return null;
    return HeapSnapshots._(v.substring(0, at), times);
  }

  final String _dir;
  final List<double> _times;
  int _next = 0;

  /// Writes the snapshot due at game time [t], if one is.
  void step(double t, void Function(String)? log) {
    if (_next >= _times.length || t < _times[_next]) return;
    final want = _times[_next++];
    Directory(_dir).createSync(recursive: true);
    final path = '$_dir/heap-${want.toStringAsFixed(0)}.dartheap';
    final sw = Stopwatch()..start();
    try {
      NativeRuntime.writeHeapSnapshotToFile(path);
      log?.call(
        'heap snapshot at t=${t.toStringAsFixed(2)}: $path '
        '(${File(path).lengthSync() >> 20} MB, ${sw.elapsedMilliseconds} ms)',
      );
    } on UnsupportedError catch (e) {
      log?.call('heap snapshot unavailable in this build: $e');
      _next = _times.length;
    }
  }
}
