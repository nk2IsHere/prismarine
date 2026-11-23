import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

// A 200x100-point render area, 400x200 device pixels at a backing scale of 2.
const area = (left: 0.0, top: 0.0, width: 200.0, height: 100.0);

class FakeHost implements MouseLookHost {
  @override
  double sumX = 0, sumY = 0;
  bool accept = true;
  final calls = <String>[];

  @override
  bool hold(double x, double y) {
    calls.add('hold $x,$y');
    return accept;
  }

  @override
  void letGo(double x, double y) => calls.add('letGo $x,$y');
}

void main() {
  group('MouseLookCursor', () {
    test('counts whole device pixels and carries the rest to the next '
        'read', () {
      final c = MouseLookCursor()..begin(0, 0, 0.5, 0.5);
      c.take(0.3, 0, area, 2); // 0.6 px
      expect(c.x, 0.5);
      c.take(0.6, 0, area, 2); // 1.2 px
      expect(c.x, 0.5 + 1 / 400);
      c.take(0.6, 0.25, area, 2); // y 0.5 px
      expect(c.y, 0.5);
      c.take(0.6, 0.5, area, 2); // y 1.0 px
      expect(c.y, 0.5 + 1 / 200);
    });

    test('a step back and forth lands where it started', () {
      final c = MouseLookCursor()..begin(10, 10, 0.5, 0.5);
      c.take(9.75, 10, area, 2);
      expect(c.x, 0.5 - 1 / 400);
      c.take(10, 10, area, 2);
      expect(c.x, 0.5);
    });

    test('the scale is the backing scale: a point is one device pixel at '
        '1x', () {
      final c = MouseLookCursor()..begin(0, 0, 0.5, 0.5);
      c.take(20, -10, area, 1);
      expect(c.x, 0.5 + 20 / 200);
      expect(c.y, 0.5 - 10 / 100);
    });

    test("a width of the area's travel crosses it", () {
      final c = MouseLookCursor()..begin(0, 0, 0, 0.5);
      c.take(200, 0, area, 2);
      expect(c.x, 1.0);
    });

    test('travel between the read and the re-centre counts from the new '
        'place', () {
      final c = MouseLookCursor()..begin(0, 0, 0.5, 0.5);
      c.take(10, 0, area, 2);
      expect(c.sample(), isTrue);
      expect(c.x, 0.5 + 20 / 400);
      // An event arrives while the frame runs, before the game re-centres.
      c.take(13, 0, area, 2, event: true);
      c.set(0.5, 0.5);
      expect(c.x, 0.5 + 6 / 400);
      expect(c.sample(), isTrue);
      c.set(0.5, 0.5);
      expect(c.x, 0.5);
      c.take(13, 0, area, 2);
      expect(c.sample(), isFalse);
    });

    test('an event that posted the cursor makes the read post it again', () {
      final c = MouseLookCursor()..begin(0, 0, 0.5, 0.5);
      expect(c.sample(), isFalse);
      c.take(0, 0, area, 2, event: true);
      expect(c.sample(), isTrue);
      expect(c.sample(), isFalse);
    });

    test("the travel stops at the area's edge and keeps no excess", () {
      final c = MouseLookCursor()..begin(0, 0, 0.9, 0.5);
      c.take(100, 0, area, 2); // 200 px, 40 px of room
      expect(c.x, 1.0);
      c.take(90, 0, area, 2); // back 20 px
      expect(c.x, closeTo(0.95, 1e-12));
      c.take(-1000, 0, area, 2);
      expect(c.x, 0.0);
    });
  });

  group('MouseLook', () {
    test('holds once and begins from the sums after the hold', () {
      final h = FakeHost()..sumX = 50;
      final l = MouseLook(h);
      expect(l.hold(100, 50, 0.5, 0.5), isTrue);
      expect(l.hold(100, 50, 0.5, 0.5), isTrue);
      expect(h.calls, ['hold 100.0,50.0']);
      l.read(area, 2);
      expect(l.cursor.x, 0.5);
      h.sumX = 55;
      l.read(area, 2);
      expect(l.cursor.x, 0.5 + 10 / 400);
    });

    test('a refused hold leaves the pointer to the warps', () {
      final h = FakeHost()..accept = false;
      final l = MouseLook(h);
      expect(l.hold(100, 50, 0.5, 0.5), isFalse);
      expect(l.held, isFalse);
      h.sumX = 30;
      l.read(area, 2);
      expect(l.cursor.x, 0.5);
      expect(l.letGo(1, 1), isFalse);
      expect(h.calls, ['hold 100.0,50.0']);
    });

    test('no host, no hold', () {
      final l = MouseLook(null);
      expect(l.hold(100, 50, 0.5, 0.5), isFalse);
      expect(l.held, isFalse);
    });

    test('lets go once, at the place given, and holds again after', () {
      final h = FakeHost();
      final l = MouseLook(h)..hold(100, 50, 0.5, 0.5);
      expect(l.letGo(120, 40), isTrue);
      expect(l.letGo(120, 40), isFalse);
      expect(l.held, isFalse);
      h.sumX = 80;
      l.hold(100, 50, 0.5, 0.5);
      l.read(area, 2);
      expect(l.cursor.x, 0.5);
      expect(h.calls, [
        'hold 100.0,50.0',
        'letGo 120.0,40.0',
        'hold 100.0,50.0',
      ]);
    });
  });

  test('holdsPointer: only a hidden, re-centred cursor in a focused window '
      'with neither the panel nor the review open', () {
    bool holds({
      bool hidden = true,
      bool recentred = true,
      bool focused = true,
      bool panelOpen = false,
      bool reviewing = false,
    }) => holdsPointer(
      hidden: hidden,
      recentred: recentred,
      focused: focused,
      panelOpen: panelOpen,
      reviewing: reviewing,
    );
    expect(holds(), isTrue);
    expect(holds(hidden: false), isFalse, reason: 'the cursor shows');
    expect(holds(recentred: false), isFalse, reason: 'no re-centre');
    expect(holds(focused: false), isFalse, reason: 'focus lost');
    expect(holds(panelOpen: true), isFalse, reason: 'a debug panel');
    expect(holds(reviewing: true), isFalse, reason: 'a review tool');
  });
}
