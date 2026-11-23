import 'dart:typed_data';

/// A table of fixed-size rows in one byte buffer, as the GPU reads it in a
/// storage buffer indexed by row. Rows are taken and given back by index and
/// written in place. The bytes written since the last [takeDirty] form one
/// range. A frame uploads only what changed.
///
/// The table has one writer, the change feed of the renderer on the UI
/// isolate. A row write allocates nothing. The buffer grows by doubling
/// when rows run out. A grown buffer is dirty as a whole once. The GPU side
/// then makes a new buffer.
class RowTable {
  RowTable(this.stride, {int capacity = 64})
    : assert(stride > 0 && stride % 16 == 0, 'rows are 16-byte aligned'),
      _bytes = ByteData(stride * capacity);

  /// The bytes per row, a multiple of 16 for a whole number of vec4s.
  final int stride;

  ByteData _bytes;
  final _free = <int>[];
  int _used = 0;
  int _dirtyFrom = 1 << 62, _dirtyTo = 0;
  bool _grew = false;

  /// The bytes of the table, as the GPU buffer must hold them.
  ByteData get bytes => _bytes;

  /// The number of rows that the table holds before it grows.
  int get capacity => _bytes.lengthInBytes ~/ stride;

  /// The number of rows ever taken, the part of [bytes] that the GPU needs.
  /// The live rows are this number minus the free ones.
  int get extent => _used;

  /// The number of live rows.
  int get live => _used - _free.length;

  /// Returns a zeroed row for a new entry. A freed row is reused first,
  /// which keeps [extent] near the live count.
  int take() {
    final int row;
    if (_free.isNotEmpty) {
      row = _free.removeLast();
    } else {
      if (_used == capacity) _grow();
      row = _used++;
    }
    final at = row * stride;
    for (var i = 0; i < stride; i += 4) {
      _bytes.setUint32(at + i, 0, Endian.little);
    }
    _mark(at, at + stride);
    return row;
  }

  /// Gives [row] back. Its bytes stay as they were until it is taken again.
  /// The GPU must not reach it meanwhile. Its instance must be gone from the
  /// lists of rows.
  void free(int row) {
    assert(row >= 0 && row < _used && !_free.contains(row));
    _free.add(row);
  }

  /// Returns the byte offset of [field] in [row] and marks the row dirty.
  /// The caller writes the bytes of the field right after.
  int at(int row, int field) {
    assert(row >= 0 && row < _used);
    final o = row * stride;
    _mark(o, o + stride);
    return o + field;
  }

  void setFloat(int row, int field, double v) =>
      _bytes.setFloat32(at(row, field), v, Endian.little);

  void setUint(int row, int field, int v) =>
      _bytes.setUint32(at(row, field), v, Endian.little);

  /// Writes [values] as consecutive floats from [field] of [row].
  void setFloats(int row, int field, List<double> values) {
    var o = at(row, field);
    for (final v in values) {
      _bytes.setFloat32(o, v, Endian.little);
      o += 4;
    }
  }

  double getFloat(int row, int field) =>
      _bytes.getFloat32(row * stride + field, Endian.little);

  int getUint(int row, int field) =>
      _bytes.getUint32(row * stride + field, Endian.little);

  /// Returns the bytes written since the last call as (start, end) byte
  /// offsets, or null when nothing changed. `whole` is true when the buffer
  /// grew and the GPU side needs all of it in a new buffer.
  ({int start, int end, bool whole})? takeDirty() {
    if (_dirtyTo <= _dirtyFrom && !_grew) return null;
    final r = (
      start: _grew ? 0 : _dirtyFrom,
      end: _grew ? _used * stride : _dirtyTo,
      whole: _grew,
    );
    _dirtyFrom = 1 << 62;
    _dirtyTo = 0;
    _grew = false;
    return r;
  }

  void _mark(int from, int to) {
    if (from < _dirtyFrom) _dirtyFrom = from;
    if (to > _dirtyTo) _dirtyTo = to;
  }

  void _grow() {
    final next = ByteData(_bytes.lengthInBytes * 2);
    next.buffer.asUint8List().setRange(
      0,
      _bytes.lengthInBytes,
      _bytes.buffer.asUint8List(),
    );
    _bytes = next;
    _grew = true;
  }
}
