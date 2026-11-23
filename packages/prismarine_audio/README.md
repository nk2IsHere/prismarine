# prismarine_audio

prismarine_audio holds the interfaces of decoded audio and a WAV writer. It has no native code and no Flutter. You can
use it from any isolate or tool. The decoders and the output device are in
[prismarine_audio_out](../prismarine_audio_out/README.md). The details are on [the area
page](../../docs/areas/audio.md).

## Usage

`PcmSource` is decoded audio as interleaved float32 frames, with its channel count, sample rate and length in frames. A
mixer reads frames at any position with `read`. `MemoryPcmSource` holds a whole decoded sound in memory. A
`LoadingPcmSource` is a source whose data still loads on another thread. `pcmReady` returns true once a source has its
data. Your mixer decides what a sound does before that, such as starting late.

`WavWriter` streams 48 kHz stereo float32 frames into a WAV file. `add` appends interleaved frames and `close` writes
the sizes into the header.

## Example

The example makes one second of a tone, reads it in blocks of 10 ms and writes it to `tone.wav`. It is
[`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools.
