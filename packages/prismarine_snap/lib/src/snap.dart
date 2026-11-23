// The snapshot object-graph codec (formats/port/snapshot.md "Body"): a
// binary stream of values in which every object is written once and named
// by its index after that, so shared references and cycles come back as
// they were. Classes are written by codecs ([SnapCodec]) that live in their
// own libraries (private fields); a codec writes what the object's
// constructor needs ([SnapCodec.writeNew]) where the object is first
// referenced and the rest of its state ([SnapCodec.write]) later, in queue
// order, so a cycle never runs through a constructor.
//
// Objects the reader already has (the fresh session's roots, the slice's
// data) are registered on both sides in the same order ([SnapWriter.known],
// [SnapReader.known]) and only their state is written.
import 'dart:collection';
import 'dart:typed_data';

import 'package:prismarine_kept/prismarine_kept.dart';

part 'snap_kinds.dart';
part 'snap_reader.dart';
part 'snap_registry.dart';
part 'snap_weak_map.dart';
part 'snap_writer.dart';
part 'snap_writer_graph.dart';

/// A snapshot that can't be written or read (a class without a codec, a
/// stream out of step).
class SnapError extends Error {
  SnapError(this.message);
  final String message;
  @override
  String toString() => 'SnapError: $message';
}

/// Writes and reads one class's objects.
abstract class SnapCodec<T extends Object> {
  const SnapCodec(this.tag);

  /// The class's name in the stream.
  final String tag;

  Type get type => T;

  /// What [make] needs to construct the object (its constructor's inputs),
  /// written where the object is first referenced. References are allowed,
  /// but no reference back to this object.
  void writeNew(SnapWriter w, T o) =>
      throw SnapError('$tag is not constructible (a known object only)');

  /// The object, constructed from what [writeNew] wrote.
  T make(SnapReader r) =>
      throw SnapError('$tag is not constructible (a known object only)');

  /// The object's state (everything [writeNew] didn't cover).
  void write(SnapWriter w, T o);

  /// Restores what [write] wrote into [o].
  void read(SnapReader r, T o);

  /// Whether a new object has state after its constructor's inputs: one
  /// without (a vector: [writeNew] holds it all) isn't queued for [write].
  bool get hasState => true;
}

/// A [SnapCodec] made of functions.
class FnCodec<T extends Object> extends SnapCodec<T> {
  FnCodec(
    super.tag, {
    void Function(SnapWriter w, T o)? writeNew,
    T Function(SnapReader r)? make,
    void Function(SnapWriter w, T o)? write,
    void Function(SnapReader r, T o)? read,
  }) : _writeNew = writeNew,
       _make = make,
       _write = write,
       _read = read;

  final void Function(SnapWriter w, T o)? _writeNew;
  final T Function(SnapReader r)? _make;
  final void Function(SnapWriter w, T o)? _write;
  final void Function(SnapReader r, T o)? _read;

  @override
  void writeNew(SnapWriter w, T o) =>
      _writeNew == null ? super.writeNew(w, o) : _writeNew(w, o);
  @override
  T make(SnapReader r) => _make == null ? super.make(r) : _make(r);
  @override
  void write(SnapWriter w, T o) => _write?.call(w, o);
  @override
  void read(SnapReader r, T o) => _read?.call(r, o);
  @override
  bool get hasState => _write != null || _read != null;
}

// Value tags.
const _tNull = 0, _tFalse = 1, _tTrue = 2, _tInt = 3, _tDouble = 4;
const _tString = 5, _tRef = 6, _tObject = 7, _tList = 8, _tMap = 9;
const _tSet = 10, _tTyped = 11, _tCustom = 12, _tFn = 13, _tRecord = 14;
const _tOrigin = 15;
