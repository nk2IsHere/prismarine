import 'dart:typed_data';

/// A table of fixed-size rows in one byte buffer, as the GPU reads it: a
/// storage buffer indexed by row. Rows are taken and given back by index,
/// written in place, and the bytes written since the last [takeDirty] form
/// one range, so a frame uploads only what changed.
///
/// One writer: the renderer's change feed on the UI isolate. Nothing here
/// allocates per row write; the buffer grows by doubling when rows run out,
/// and a grown buffer is all dirty once (the GPU side makes a new buffer).
class RowTable {
  RowTable(this.stride, {int capacity = 64})
    : assert(stride > 0 && stride % 16 == 0, 'rows are 16-byte aligned'),
      _bytes = ByteData(stride * capacity);

  /// Bytes per row; a multiple of 16 so a row is a whole number of vec4s.
  final int stride;

  ByteData _bytes;
  final _free = <int>[];
  int _used = 0;
  int _dirtyFrom = 1 << 62, _dirtyTo = 0;
  bool _grew = false;

  /// The table's bytes, as the GPU buffer should hold them.
  ByteData get bytes => _bytes;

  /// Rows the table can hold before it grows.
  int get capacity => _bytes.lengthInBytes ~/ stride;

  /// Rows ever handed out (live rows are this minus the free ones): the
  /// part of [bytes] the GPU needs.
  int get extent => _used;

  /// Live rows.
  int get live => _used - _free.length;

  /// A row for a new entry, zeroed. A freed row is reused first, so
  /// [extent] stays near the live count.
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

  /// Gives [row] back. Its bytes stay as they were until it is taken
  /// again; the GPU must not reach it meanwhile (its instance is gone from
  /// the lists that name rows).
  void free(int row) {
    assert(row >= 0 && row < _used && !_free.contains(row));
    _free.add(row);
  }

  /// The byte offset of [field] in [row], marking that row dirty: the
  /// caller writes the field's bytes right after.
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

  /// Writes [values] as consecutive floats from [field].
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

  /// The bytes written since the last call, as (start, end) byte offsets,
  /// or null when nothing changed; [whole] is true when the buffer grew and
  /// the GPU side needs it all in a new buffer.
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
