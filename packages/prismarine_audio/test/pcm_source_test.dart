import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:test/test.dart';

void main() {
  test('a memory source reads interleaved frames and stops at the end', () {
    final s = MemoryPcmSource(
      Float32List.fromList([1, 2, 3, 4, 5, 6]),
      channels: 2,
      sampleRate: 48000,
    );
    expect((s.frames, s.channels, s.sampleRate), (3, 2, 48000));
    final out = Float32List(4);
    expect(s.read(out, 1, 2), 2);
    expect(out, [3, 4, 5, 6]);
    expect(s.read(out, 2, 2), 1);
    expect(s.read(out, 5, 2), 0);
  });
}
