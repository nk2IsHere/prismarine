# prismarine_audio

prismarine_audio is an audio engine of events, buses with effects, voices and mix states. Its Dart render runs on any
isolate and in command-line tools, and its native render in [prismarine_audio_out](../prismarine_audio_out/README.md)
plays in real time with the same bits. The package also holds the interfaces of decoded audio and a WAV writer. It has
no native code and no Flutter. The details are on [the area page](../../docs/areas/audio.md).

## Usage

You build a project in code: a `MixerDef` with the buses of the mixer and `EventDef`s with their strips, effects and
instruments. An `AudioEngine` over the project takes `AudioCommand`s at frames, such as `StartEvent`, `SetParameter`
and `StopEvent`, and `render` returns the next stereo frames of the master bus. A `SampleLoader` gives the engine the
decoded samples of each waveform as a `PcmSource`.

`PcmSource` is decoded audio as interleaved float32 frames. `MemoryPcmSource` holds a whole decoded sound in memory, and
a `LoadingPcmSource` is a source whose data still loads on another thread. `WavWriter` streams 48 kHz stereo float32
frames into a WAV file.

## Example

The example builds a project with one event that plays a tone through a lowpass, starts it and writes two seconds to
`beep.wav`. It is [`example/example.dart`](example/example.dart):

```dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';

void main() {
  // One second of a 440 Hz tone, 48 kHz mono.
  final tone = Float32List(48000);
  for (var i = 0; i < tone.length; i++) {
    tone[i] = 0.3 * math.sin(2 * math.pi * 440 * i / 48000);
  }
  final samples = {
    'tone': MemoryPcmSource(tone, channels: 1, sampleRate: 48000),
  };

  // A mixer with a master bus and an event that plays the tone through a
  // lowpass into it.
  final mixer = MixerDef(
    buses: [StripDef(guid: 'master', master: true)],
    paths: {'master': 'bus:master'},
  );
  final beep = EventDef(
    guid: 'beep',
    path: 'event:beep',
    masterTrack: StripDef(
      guid: 'beep/master',
      effects: [
        DspEffect(
          guid: 'beep/lowpass',
          kind: EffectKind.lowpass,
          params: const [EffectParam.number(2000), EffectParam.number(1)],
        ),
      ],
    ),
    timeline: TimelineDef(
      placements: [
        Placement(
          start: 0,
          length: 48000,
          instrument: InstrumentDef(
            guid: 'beep/tone',
            kind: 'sample',
            waveform: WaveformDef(key: 'tone', frames: 48000),
          ),
        ),
      ],
      end: 48000,
    ),
  );

  // Start the event half a second in, lower its volume at one second and
  // render two seconds into a WAV file.
  final engine = AudioEngine(
    {'event:beep': beep},
    MixerGraph(mixer),
    (w) => samples[w.key],
  );
  engine
    ..schedule(const StartEvent(1, 'event:beep'), at: 24000)
    ..schedule(const SetVolume(1, 0.5), at: 48000);
  final wav = WavWriter('beep.wav');
  while (engine.position < 96000) {
    wav.add(engine.render(1024));
  }
  wav.close();
  print('wrote ${wav.frames} frames to beep.wav');
}
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools.
