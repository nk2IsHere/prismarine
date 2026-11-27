import 'dart:typed_data';

import '../plan/frame_plan.dart';

// One frame's skinned meshes in one compute dispatch: the bookkeeping a
// builder's skinning batch keeps, whatever its program. Each mesh's source
// vertices sit once in one source buffer, each skinned mesh has a place of
// its own in one output buffer kept from frame to frame (so its draws keep
// their stream offsets and stay kept), each mesh is a whole number of
// 64-thread groups, and the dispatch stays the same object while its shape
// holds. A builder gives its program, its sources' bytes and its rows per
// mesh.

/// The source vertices of every mesh a batch has skinned, each appended
/// once, in one buffer.
final class SkinSources {
  SkinSources([int capacity = 1 << 16]) : bytes = Uint8List(capacity);
  Uint8List bytes;
  int length = 0;

  /// The sources as bound: a new object whenever they grew, so the plan
  /// codec sends them again.
  Uint8List view = Uint8List(0);

  // alloc-cold: a mesh's first skinning
  /// [src] appended, 4-byte aligned: its place in bytes.
  int add(Uint8List src) {
    final at = length;
    final end = at + ((src.length + 3) & ~3);
    if (end > bytes.length) {
      var size = bytes.length;
      while (size < end) {
        size *= 2;
      }
      bytes = Uint8List(size)..setRange(0, at, bytes);
    }
    bytes.setRange(at, at + src.length, src);
    length = end;
    view = Uint8List.sublistView(bytes, 0, end);
    return at;
  }
}

/// A batch's 64-thread groups: each group's mesh, filled a frame at a time.
final class SkinGroups {
  Uint32List table = Uint32List(1024);
  int count = 0;

  void clear() => count = 0;

  /// Groups for mesh [mesh] of [vertices] vertices: the first one's index.
  int add(int mesh, int vertices) {
    final first = count, g = (vertices + 63) >> 6;
    if (table.length < first + g) _grow(first + g);
    table.fillRange(first, first + g, mesh);
    count = first + g;
    return first;
  }

  // alloc-cold: a batch of more groups than before
  void _grow(int n) => table = Uint32List(n * 2)..setAll(0, table);

  /// The table's first [count] entries as bytes: a view kept while the
  /// count and the table hold.
  Uint8List get bytes =>
      _bytes.length == count * 4 && identical(_bytesOf, table)
      ? _bytes
      : _view();
  Uint8List _bytes = Uint8List(0);
  Uint32List? _bytesOf;

  // alloc-cold: a table of another length
  Uint8List _view() {
    _bytesOf = table;
    return _bytes = table.buffer.asUint8List(0, count * 4);
  }
}

/// A batch's dispatch, the same object while its group count and sources
/// hold.
final class SkinDispatch {
  DispatchPlan? plan;
  int _groups = -1;
  Uint8List? _sources;

  /// The kept dispatch when [groups] and [sources] are last frame's.
  DispatchPlan? kept(int groups, Uint8List sources) =>
      _groups == groups && identical(_sources, sources) ? plan : null;

  /// [made] kept for [groups] over [sources].
  DispatchPlan keep(DispatchPlan made, int groups, Uint8List sources) {
    _groups = groups;
    _sources = sources;
    return plan = made;
  }
}
