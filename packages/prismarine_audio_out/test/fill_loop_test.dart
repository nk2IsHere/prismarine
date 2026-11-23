import 'dart:typed_data';

import 'package:prismarine_audio_out/src/fill_loop.dart';
import 'package:test/test.dart';

void main() {
  test('a block whose render throws plays as silence and is reported; the '
      'stream (and the clock it paces) goes on', () {
    var calls = 0;
    final pushed = <Float32List>[];
    final errors = <Object>[];
    final f = FillLoop(
      consumed: () => 0,
      render: (n) {
        if (calls++ == 1) throw RangeError('boom');
        return Float32List(n * 2)..fillRange(0, n * 2, 0.5);
      },
      push: pushed.add,
      lead: 0.05,
      block: 960,
      onError: (e, _) => errors.add(e),
    );
    f.fill();
    expect(pushed, hasLength(3));
    expect(pushed[1].every((v) => v == 0), isTrue);
    expect(pushed[1].length, 960 * 2);
    expect(pushed[2].first, 0.5);
    expect(errors.single, isA<RangeError>());
  });

  test('fills to the lead, then only as the consumer advances', () {
    var consumed = 0.0;
    final pushed = <int>[];
    final f = FillLoop(
      consumed: () => consumed,
      render: (n) => Float32List(n * 2),
      push: (b) => pushed.add(b.length ~/ 2),
      lead: 0.05,
      block: 960,
    );
    f.fill();
    expect(f.requestedFrames, 2880); // 3 × 960 ≥ 0.05 × 48000 = 2400
    f.fill();
    expect(pushed, [960, 960, 960]);
    consumed = 0.04;
    f.fill();
    expect(f.requestedFrames / 48000 - consumed, greaterThanOrEqualTo(0.05));
  });

  test('the fill loop keeps filling on its own timer and stops on dispose, '
      'never pushing after', () async {
    var consumed = 0.0;
    var pushes = 0;
    final f = FillLoop(
      consumed: () => consumed,
      render: (n) => Float32List(n * 2),
      push: (_) => pushes++,
      lead: 0.05,
      block: 960,
      period: const Duration(milliseconds: 1),
    )..start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pushes, greaterThan(0));
    // The consumer moves on and the timer tops the stream up by itself.
    final before = pushes;
    consumed = 1.0;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pushes, greaterThan(before));
    f.stop();
    final stopped = pushes;
    consumed = 10;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    f.fill();
    expect(pushes, stopped);
  });
}
