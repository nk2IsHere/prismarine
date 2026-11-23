import 'dart:developer' show NativeRuntime;
import 'dart:io';

/// Heap snapshots at the game times of `PRISMARINE_HEAP_SNAPSHOT=<dir>:<t>,<t>…`.
///
/// At the first tick at or past each game time t, the heap of the isolate
/// group is written to `<dir>/heap-<t>.dartheap` in the snapshot format of
/// the VM service, which `HeapSnapshotGraph.fromChunks` reads. This works in
/// profile and debug builds only. A release VM has no snapshot writer and
/// logs that once. The write holds every isolate for several seconds.
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

  /// Writes the snapshot that is due at game time [t], if any. Reports to
  /// [log].
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
