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
