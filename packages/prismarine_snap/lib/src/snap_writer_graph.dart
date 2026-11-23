// The writer's value switch: an object written once, then by reference.
part of 'snap.dart';

extension _SnapWriterGraph on SnapWriter {
  void _object(Object o) {
    final id = _ids[o];
    if (id != null) {
      byte(_tRef);
      uint(id);
      return;
    }
    final codec = registry.codecOf(o);
    if (codec != null) {
      final id = _assign(o, codec.tag);
      byte(_tObject);
      str(codec.tag);
      _current.add(id);
      if (trace) _mark(id, 'new ${codec.tag}');
      codec.writeNew(this, o);
      _current.removeLast();
      if (codec.hasState) _queue.add((o, codec));
      return;
    }
    if (_originsOff == 0 && (o is Map || o is List)) {
      final origin = registry.originOf?.call(this, o);
      if (origin != null) {
        _current.add(_assign(o, 'origin ${origin.$1}'));
        byte(_tOrigin);
        str(origin.$1);
        values(origin.$2);
        // Changed in place: its content, for the reader's copy.
        final changed = registry.originChanged?.call(o) ?? false;
        boolean(changed);
        if (changed) {
          _originsOff++;
          if (o is List) {
            values(o);
          } else {
            final m = o as Map;
            uint(m.length);
            m.forEach((k, v) {
              value(k);
              value(v);
            });
          }
          _originsOff--;
        }
        _current.removeLast();
        return;
      }
    }
    switch (o) {
      case final TypedData t:
        final k = _typedKind(t);
        if (k < 0) {
          throw SnapError('typed data ${t.runtimeType} (${_where()})');
        }
        _assign(o, 'typed');
        byte(_tTyped);
        byte(k);
        final b = t.buffer.asUint8List(t.offsetInBytes, t.lengthInBytes);
        bytes(b);
      case final List l:
        var k = _kinds.listKinds[l.runtimeType];
        if (k == null) {
          // A list type no kind names: read back as List<Object?>.
          unknownKinds.add('${l.runtimeType}');
          k = _kinds.listKinds[<Object?>[].runtimeType]!;
        }
        _current.add(_assign(o, 'list'));
        if (trace) _mark(_current.last, 'list ${l.runtimeType}');
        byte(_tList);
        uint(k);
        uint(l.length);
        for (var i = 0; i < l.length; i++) {
          value(l[i]);
        }
        _current.removeLast();
      case final Map m:
        var k = _kinds.mapKinds[m.runtimeType];
        if (k == null) {
          unknownKinds.add('${m.runtimeType}');
          k = _kinds.mapKinds[<Object?, Object?>{}.runtimeType]!;
        } else if (m.isNotEmpty) {
          k = _kinds.constFrozen[k] ?? k;
        }
        _current.add(_assign(o, 'map'));
        if (trace) _mark(_current.last, 'map ${m.runtimeType}');
        byte(_tMap);
        uint(k);
        uint(m.length);
        m.forEach((key, val) {
          value(key);
          value(val);
        });
        _current.removeLast();
      case final Set s:
        var k = _kinds.setKinds[s.runtimeType];
        if (k == null) {
          unknownKinds.add('${s.runtimeType}');
          k = _kinds.setKinds[<Object?>{}.runtimeType]!;
        }
        _current.add(_assign(o, 'set'));
        if (trace) _mark(_current.last, 'set ${s.runtimeType}');
        byte(_tSet);
        uint(k);
        uint(s.length);
        for (final e in s) {
          value(e);
        }
        _current.removeLast();
      case final Function f:
        final r = _recipes[f];
        if (r == null) {
          throw SnapError(
            'a closure without a recipe: ${f.runtimeType} (${_where()})',
          );
        }
        _current.add(_assign(o, 'fn ${r.$1}'));
        byte(_tFn);
        str(r.$1);
        uint(r.$2.length);
        for (final a in r.$2) {
          value(a);
        }
        _current.removeLast();
      case final Record rec:
        final c = registry.codecFor(rec.runtimeType);
        if (c == null) {
          throw SnapError('record ${rec.runtimeType} (${_where()})');
        }
        byte(_tRecord);
        str(c.tag);
        c.writeNew(this, rec);
      default:
        throw SnapError('no codec for ${o.runtimeType} (${_where()})');
    }
  }

  /// Starts an object written by the caller (a typed collection kept by
  /// identity, an object of a class without a codec): true when [o] is new
  /// (the caller writes it now), false when a reference was written.
}
