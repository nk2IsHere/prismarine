part of 'plan_codec.dart';

/// [b]'s bytes hashed (FNV-1a over 64-bit words, then the tail bytes): a
/// block's change in place is told by its hash and length, where a copy of
/// every block sent was kept on the heap. Each step is a bijection of the
/// hash, so one changed word always changes it; several changes cancel
/// only by a 64-bit collision.
int _hash(Uint8List b) {
  var h = 0xcbf29ce484222325;
  final n = b.length;
  var i = 0;
  if (b.offsetInBytes % 8 == 0) {
    // Each little-endian word from its bytes: the bits an Int64 view reads,
    // without the buffer object and view per hash (perf).
    final words = n ~/ 8;
    for (var k = 0; k < words; k++) {
      final o = k * 8;
      final lo = b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
      final hi = b[o + 4] | b[o + 5] << 8 | b[o + 6] << 16 | b[o + 7] << 24;
      h = (h ^ (lo | hi << 32)) * 0x100000001b3;
    }
    i = words * 8;
  }
  for (; i < n; i++) {
    h = (h ^ b[i]) * 0x100000001b3;
  }
  return h;
}

/// A pass's row as last sent: its draw and the pass's sending that named
/// it.
final class _SentRow {
  _SentRow(this.plan, this.stamp);
  DrawPlan plan;
  int stamp;
}

/// A pass's rows as sent: by row id, the id and plan lists sent last, and
/// the count of sendings that changed them.
final class _SentRows {
  final rows = <int, _SentRow>{};
  List<int>? ids;
  List<DrawPlan>? plans;
  int stamp = 0;
}

/// A kept pass changed in place on the reader: a few draws (an edit), its
/// draws whole (a reshape), its draws and rows (a rows reshape).
extension _PassEdits on PlanWriter {
  /// Writes the edit of the kept pass at [at] from [last] to [r] when only
  /// a few of its draws changed (the reader's pass holds [last]'s draws).
  bool _passEdit(int at, RenderPassPlan last, RenderPassPlan r) {
    final id = _passIds[at];
    if (id < 0 || !identical(_objects[id], _keptPass[at])) return false;
    if (!PlanWriter._sameShape(last, r)) return false;
    final a = last.draws, b = r.draws;
    var n = 0;
    for (var i = 0; i < b.length; i++) {
      if (!identical(a[i], b[i])) n++;
    }
    if (n == 0 || n * 4 > b.length) return false;
    _int(tagRenderEdit);
    _int(id);
    _int(n);
    for (var i = 0; i < b.length; i++) {
      if (identical(a[i], b[i])) continue;
      _int(i);
      _draw(b[i]);
    }
    _lastUse[id] = _message;
    for (var i = 0; i < b.length; i++) {
      if (_ids[b[i]] case final k?) _lastUse[k] = _message;
    }
    return true;
  }

  /// Writes [r] as a reshape of the kept pass at [at] (the reader's pass
  /// holds [last]'s attachments): every draw again, most by id.
  bool _passReshape(int at, RenderPassPlan last, RenderPassPlan r) {
    final id = _passIds[at];
    if (id < 0 || !identical(_objects[id], _keptPass[at])) return false;
    if (!PlanWriter._sameAttachments(last, r)) return false;
    final b = r.draws;
    _int(tagRenderReshape);
    _int(id);
    _int(b.length);
    for (var i = 0; i < b.length; i++) {
      _draw(b[i]);
    }
    _lastUse[id] = _message;
    for (var i = 0; i < b.length; i++) {
      if (_ids[b[i]] case final k?) _lastUse[k] = _message;
    }
    return true;
  }

  /// Writes [r], a pass with rows, into the kept pass at [at] (the reader's
  /// pass holds [last]'s attachments): every draw again, most by id, then
  /// the rows' changes.
  bool _passRows(int at, RenderPassPlan last, RenderPassPlan r) {
    final id = _passIds[at];
    if (id < 0 || !identical(_objects[id], _keptPass[at])) return false;
    if (!PlanWriter._sameAttachments(last, r)) return false;
    final b = r.draws;
    _int(tagRenderRows);
    _int(id);
    _int(b.length);
    for (var i = 0; i < b.length; i++) {
      _draw(b[i]);
    }
    _rows(r);
    _lastUse[id] = _message;
    for (var i = 0; i < b.length; i++) {
      if (_ids[b[i]] case final k?) _lastUse[k] = _message;
    }
    return true;
  }
}
