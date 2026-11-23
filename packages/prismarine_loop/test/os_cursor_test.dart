import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

/// A stand-in for the NSCursor hide and unhide count of the runner. Hide
/// pushes and unhide pops. An unhide without a hide is an error, since the
/// calls of NSCursor must pair.
class _Count {
  int depth = 0;
  final calls = <bool>[];
  void send(bool hidden) {
    calls.add(hidden);
    if (hidden) {
      depth++;
    } else {
      expect(depth, greaterThan(0), reason: 'unhide without a hide');
      depth--;
    }
    expect(depth, inInclusiveRange(0, 1));
  }
}

void main() {
  test('hidden only while over the game area', () {
    final c = _Count();
    final h = OsCursorHider(c.send);
    expect(c.calls, isEmpty);
    h.over = true;
    expect(c.depth, 1);
    h.over = true; // repeated enter: no second hide
    expect(c.calls, [true]);
    h.over = false; // to the panel or out of the window
    expect(c.depth, 0);
    h.over = false;
    expect(c.calls, [true, false]);
  });

  test('the review shows the OS cursor and gives it back after', () {
    final c = _Count();
    final h = OsCursorHider(c.send)..over = true;
    h.reviewing = true;
    expect(c.depth, 0);
    h.over = false;
    h.over = true; // hovering the review's tools
    expect(c.depth, 0);
    h.reviewing = false;
    expect(c.depth, 1);
    expect(h.hidden, isTrue);
  });

  test('any sequence stays paired and dispose shows the cursor', () {
    final c = _Count();
    final h = OsCursorHider(c.send);
    // Every order of enter, exit and review over a few hundred steps.
    var s = 12345;
    for (var i = 0; i < 400; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      switch (s % 4) {
        case 0:
          h.over = true;
        case 1:
          h.over = false;
        case 2:
          h.reviewing = true;
        default:
          h.reviewing = false;
      }
      expect(c.depth, h.hidden ? 1 : 0);
    }
    h.over = true;
    h.reviewing = false;
    h.dispose();
    expect(c.depth, 0);
    expect(h.hidden, isFalse);
  });
}
