import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';

void main() {
  // One second of a 440 Hz tone, 48 kHz stereo.
  final tone = Float32List(48000 * 2);
  for (var i = 0; i < 48000; i++) {
    final v = 0.2 * math.sin(2 * math.pi * 440 * i / 48000);
    tone[2 * i] = tone[2 * i + 1] = v;
  }
  final PcmSource source = MemoryPcmSource(
    tone,
    channels: 2,
    sampleRate: 48000,
  );

  // Read the source in blocks of 10 ms, as a mixer does.
  final wav = WavWriter('tone.wav');
  final block = Float32List(480 * 2);
  for (var at = 0; at < source.frames;) {
    final n = source.read(block, at, 480);
    wav.add(Float32List.sublistView(block, 0, n * 2));
    at += n;
  }
  wav.close();
  print('wrote ${wav.frames} frames to tone.wav');
}
