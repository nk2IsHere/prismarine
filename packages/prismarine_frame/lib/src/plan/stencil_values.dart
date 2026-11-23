import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';

/// The values that a depth target's stencil can hold: its clear value under
/// any sequence of the replacing writes since the clear. Each write stores
/// its reference under its write mask. Only replacing writes are followed.
class StencilValues {
  int _clear = 0;

  /// Distinct writes, reference | write mask << 8.
  final _writes = <int>[];
  final _held = Uint8List(256);

  /// Whether the stencil changed since the last copy.
  bool stale = false;

  void reset(int clear) {
    _clear = clear & 0xff;
    _writes.clear();
    stale = true;
  }

  void write(DrawPlan d) {
    final st = d.state.stencil;
    if (st == null || st.passOp != 'replace') return;
    final mask = st.writeMask & 0xff;
    if (mask == 0) return;
    // Any write changes which pixels hold a value, so the copy is stale
    // even when the value is not new.
    stale = true;
    final w = (d.stencilRef & 0xff) | mask << 8;
    if (!_writes.contains(w)) _writes.add(w);
  }

  /// 1 for each value the stencil can hold.
  Uint8List held() {
    _held.fillRange(0, 256, 0);
    _held[_clear] = 1;
    for (var grew = true; grew;) {
      grew = false;
      for (var v = 0; v < 256; v++) {
        if (_held[v] == 0) continue;
        for (final w in _writes) {
          final mask = w >> 8;
          final next = (v & ~mask) | (w & mask);
          if (_held[next] == 0) {
            _held[next] = 1;
            grew = true;
          }
        }
      }
    }
    return _held;
  }
}
