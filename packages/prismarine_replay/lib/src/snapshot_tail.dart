import 'package:prismarine_snap/prismarine_snap.dart';

/// Writes the tail of a snapshot body. The tail is a boolean followed by
/// [tail] as its own section when it is not null. The tail is an object that the reader's
/// host makes only after the restore, such as an audio bridge.
void writeSnapshotTail(SnapWriter w, Object? tail) {
  w.boolean(tail != null);
  if (tail != null) {
    w
      ..known(tail)
      ..fillKnown(tail)
      ..finish();
  }
}

/// The tail of a snapshot body that is read after the rest. The reader's
/// host reads it once it has made its own tail object.
class SnapshotTail {
  /// Reads the tail with the reader that read the rest of the body.
  SnapshotTail(this._r);
  final SnapReader _r;
  bool _done = false;
  bool? _peek;

  /// True when the snapshot holds a tail.
  bool get hasTail => _peek ??= _r.boolean();

  /// Reads the tail into [tail], with [env] added to the reader's env for
  /// its codecs. Returns false when the snapshot has no tail.
  bool read(Object tail, {Map<Object, Object?> env = const {}}) {
    if (_done) throw StateError('the tail was read');
    _done = true;
    if (!hasTail) return false;
    _r.env.addAll(env);
    _r
      ..known(tail)
      ..fillKnown(tail)
      ..finish();
    if (!_r.atEnd) throw SnapError('snapshot has bytes left over');
    return true;
  }
}
