// The snapshot codec writes a binary stream of values. Every object is
// written once and is referred to by its index after that. Shared references
// and cycles are read back as they were. A codec ([SnapCodec]) writes the
// objects of one class. It is defined in the library of its class to reach
// the private fields. A codec writes the inputs of the constructor
// ([SnapCodec.writeNew]) where the object is first referenced. It writes the
// rest of the state ([SnapCodec.write]) later in queue order. A cycle
// therefore never runs through a constructor.
//
// Objects that the reader already has, such as the roots of a new session or
// data loaded from files, are registered on both sides in the same order with
// [SnapWriter.known] and [SnapReader.known]. Only their state is written.
import 'dart:collection';
import 'dart:typed_data';

import 'package:prismarine_kept/prismarine_kept.dart';

part 'snap_kinds.dart';
part 'snap_reader.dart';
part 'snap_registry.dart';
part 'snap_weak_map.dart';
part 'snap_writer.dart';
part 'snap_writer_graph.dart';

/// The error of a snapshot that cannot be written or read, such as a class
/// without a codec or a stream out of step.
class SnapError extends Error {
  SnapError(this.message);
  final String message;
  @override
  String toString() => 'SnapError: $message';
}

/// Writes and reads the objects of one class.
abstract class SnapCodec<T extends Object> {
  const SnapCodec(this.tag);

  /// The name of the class in the stream.
  final String tag;

  Type get type => T;

  /// Writes the inputs of the constructor that [make] needs, where the object
  /// is first referenced. The inputs may hold references but no reference
  /// back to this object.
  void writeNew(SnapWriter w, T o) =>
      throw SnapError('$tag is not constructible (a known object only)');

  /// Constructs the object from the inputs that [writeNew] wrote.
  T make(SnapReader r) =>
      throw SnapError('$tag is not constructible (a known object only)');

  /// Writes the state of the object that [writeNew] did not cover.
  void write(SnapWriter w, T o);

  /// Restores what [write] wrote into [o].
  void read(SnapReader r, T o);

  /// False for a class whose objects have no state beyond the inputs of the
  /// constructor, such as a vector that [writeNew] writes whole. Such an
  /// object is not queued for [write].
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
