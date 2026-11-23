import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

void main() {
  const w = 64, h = 36;
  Uint8List frame([int base = 40]) =>
      Uint8List(w * h)..fillRange(0, w * h, base);

  void fillTriangle(Uint8List f, int v) {
    // A right triangle with its corner at (4, 4), 20 px a side.
    for (var y = 0; y < 20; y++) {
      for (var x = 0; x <= y; x++) {
        f[(4 + y) * w + 4 + x] = v;
      }
    }
  }

  test('a white triangle in one frame only is flagged as one patch', () {
    final prev = frame(), cur = frame(), next = frame();
    fillTriangle(cur, 250);
    final r = brightTransient(prev, cur, next, w);
    expect(r.count, 210);
    expect(r.box, [4, 4, 23, 23]);
    expect(largestBlob(r.mask, w), 210);
  });

  test('a bright shape that moved a few pixels is not flagged', () {
    final prev = frame(), cur = frame(), next = frame();
    fillTriangle(prev, 250);
    fillTriangle(cur, 250);
    fillTriangle(next, 250);
    // cur shifted right by 3 px relative to its neighbours.
    final shifted = frame();
    for (var y = 0; y < h; y++) {
      for (var x = 3; x < w; x++) {
        shifted[y * w + x] = cur[y * w + x - 3];
      }
    }
    expect(brightTransient(prev, shifted, next, w).count, 0);
  });

  test('scattered sparkles make many small patches, not one large one', () {
    final prev = frame(), cur = frame(), next = frame();
    for (var k = 0; k < 30; k++) {
      final x = (k * 7) % (w - 2), y = (k * 5) % (h - 2);
      cur[y * w + x] = 255;
    }
    final r = brightTransient(prev, cur, next, w);
    expect(r.count, greaterThan(0));
    expect(largestBlob(r.mask, w), lessThan(const GlitchThresholds().minBlob));
  });

  test('a saturated rim light is not taken for a white artefact', () {
    final prev = frame(), cur = frame(), next = frame();
    fillTriangle(cur, 250);
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      // Yellow: red and green bright, blue dark.
      rgba[i * 4] = cur[i];
      rgba[i * 4 + 1] = cur[i];
      rgba[i * 4 + 2] = 20;
      rgba[i * 4 + 3] = 255;
    }
    expect(brightTransient(prev, cur, next, w, rgba: rgba).count, 0);
  });
}
