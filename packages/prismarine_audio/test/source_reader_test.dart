import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:prismarine_audio/src/events/voice.dart';
import 'package:test/test.dart';

void main() {
  test('a block whose stepped position drifts past the one-shot span reads '
      'in range (render isolate RangeError at 470.82 s)', () {
    final samples = Float32List(100000);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (i % 100) / 100;
    }
    final src = MemoryPcmSource(samples, channels: 1, sampleRate: 44100);
    // pos0 + 74·rate rounds just under 53221; 74 additions of rate land on
    // 53221.000…, one frame past the span read up front.
    const rate = 0.5751175241513093, pos0 = 53178.441303212705;
    final out = Float32List(75 * 2);
    final pos = SourceReader(src).addInto(out, 0, 75, pos0, rate);
    expect(pos, isNotNull);
    // The last frame interpolates 53221 → 53222 at a fraction near 0.
    expect(out[74 * 2], closeTo(samples[53221], 1e-3));
  });
}
