import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:prismarine_math/libm.dart' as libm;

/// A synthetic project that uses each instrument kind, each effect kind, a
/// 5.1 bus, sends, a sidechain and a mix state, with generated samples.
class SyntheticProject {
  /// With [dir] the waveforms have the paths `<dir>/<key>.f32`.
  SyntheticProject({this.dir}) {
    _samples['tone'] = _tone(220, 48000, 1);
    _samples['noise'] = _noise(24000, 2, 7);
    _samples['quad'] = _noise(12000, 4, 11);
    _samples['voice'] = _tone(330, 36000, 1);
  }

  final String? dir;
  final _samples = <String, PcmSource>{};

  /// The generated samples by key.
  Map<String, PcmSource> get samples => _samples;

  /// The source of a waveform key.
  PcmSource? sample(WaveformDef w) => _samples[w.key];

  /// The source of a slot sound.
  PcmSource? sound(String key) => _samples[key];

  static PcmSource _tone(double hz, int frames, int channels) {
    final s = Float32List(frames * channels);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < channels; c++) {
        s[i * channels + c] = 0.3 * libm.sin(2 * math.pi * hz * i / 48000);
      }
    }
    return MemoryPcmSource(s, channels: channels, sampleRate: 48000);
  }

  static PcmSource _noise(int frames, int channels, int seed) {
    final r = math.Random(seed);
    final s = Float32List(frames * channels);
    for (var i = 0; i < s.length; i++) {
      s[i] = (r.nextDouble() * 2 - 1) * 0.2;
    }
    return MemoryPcmSource(s, channels: channels, sampleRate: 48000);
  }

  WaveformDef _wave(String key, int frames, int channels) => WaveformDef(
    key: key,
    path: dir == null ? null : '$dir/$key.f32',
    label: key,
    frames: frames,
    channels: channels,
  );

  static DspEffect _fx(
    String id,
    EffectKind kind, [
    List<double> p = const [],
  ]) => DspEffect(
    guid: id,
    kind: kind,
    label: kind.name,
    params: [for (final v in p) EffectParam.number(v)],
  );

  /// The mixer: a master, an effects bus with every stereo DSP, a 5.1 bus,
  /// a reverb return and a music bus that a sidechain from the voice bus
  /// ducks.
  MixerDef mixer() => MixerDef(
    buses: [
      StripDef(guid: 'master', master: true),
      StripDef(
        guid: 'fx',
        output: 'master',
        effects: [
          _fx('lp', EffectKind.lowpass, [8000, 1]),
          _fx('hp', EffectKind.highpass, [80, 1]),
          _fx('peq', EffectKind.parametricEq, [1000, 1, 3]),
          _fx('eq3', EffectKind.threeBandEq, [2, -1, 1, 300, 3000, 1]),
          _fx('dist', EffectKind.distortion, [0.2]),
          _fx('echo', EffectKind.echo, [120, 30, 0, -12]),
          _fx('flange', EffectKind.flange, [40, 1, 0.2]),
          _fx('chorus', EffectKind.chorus, [50, 0.8, 3]),
          _fx('trem', EffectKind.tremolo, [4, 0.5]),
          _fx('lim', EffectKind.limiter, [10, -3, 0, 1]),
          SendEffect(guid: 'send', returnBus: 'verb', level: -6),
        ],
      ),
      StripDef(
        guid: 'wide',
        output: 'master',
        layout: ChannelLayout.surround51,
        effects: [
          _fx('mbeq', EffectKind.multibandEq, [1, 500, 0.7, 4]),
          _fx('cmix', EffectKind.channelMix, [0, -3, -3, 0, -80, -6, -6]),
        ],
      ),
      StripDef(
        guid: 'verb',
        output: 'master',
        effects: [
          _fx('rv', EffectKind.reverb, [
            900,
            20,
            30,
            5000,
            60,
            100,
            100,
            250,
            0,
            20000,
            50,
            -8,
            -80,
          ]),
        ],
      ),
      StripDef(
        guid: 'voice',
        output: 'master',
        effects: [
          SidechainTap(guid: 'tap', targets: ['comp']),
        ],
      ),
      StripDef(
        guid: 'music',
        output: 'master',
        effects: [
          DspEffect(
            guid: 'comp',
            kind: EffectKind.compressor,
            label: 'compressor',
            params: [
              for (final v in <double>[-30, 4, 5, 80, 0]) EffectParam.number(v),
            ],
            sidechainInput: true,
          ),
        ],
      ),
    ],
    paths: {
      'master': 'bus:master',
      'fx': 'bus:fx',
      'wide': 'bus:wide',
      'verb': 'bus:verb',
      'voice': 'bus:voice',
      'music': 'bus:music',
    },
  );

  EventDef _event(
    String path,
    String bus,
    InstrumentDef inst, {
    int length = 48000,
    List<EffectDef> effects = const [],
    List<ParameterDef> parameters = const [],
    StripDef? track,
  }) => EventDef(
    guid: path,
    path: path,
    inputBus: StripDef(guid: '$path/in', outputPath: bus),
    masterTrack: StripDef(guid: '$path/m', effects: effects),
    tracks: [?track],
    parameters: parameters,
    timeline: TimelineDef(
      placements: [Placement(start: 0, length: length, instrument: inst)],
      end: length,
    ),
  );

  /// The events by path.
  Map<String, EventDef> events() => {
    'event:tone': _event(
      'event:tone',
      'bus:fx',
      InstrumentDef(
        guid: 'i1',
        kind: 'sample',
        waveform: _wave('tone', 48000, 1),
      ),
      effects: [
        _fx('pan', EffectKind.pan, [0, 40]),
      ],
    ),
    'event:playlist': _event(
      'event:playlist',
      'bus:music',
      InstrumentDef(
        guid: 'i2',
        kind: 'playlist',
        shuffle: true,
        entries: [
          (
            1,
            InstrumentDef(
              guid: 'e1',
              kind: 'sample',
              waveform: _wave('tone', 48000, 1),
            ),
          ),
          (
            2,
            InstrumentDef(
              guid: 'e2',
              kind: 'sample',
              waveform: _wave('noise', 24000, 2),
            ),
          ),
        ],
        loopCount: -1,
      ),
      length: 96000,
    ),
    'event:scatter': _event(
      'event:scatter',
      'bus:fx',
      InstrumentDef(
        guid: 'i3',
        kind: 'scatterer',
        spawnIntervalMin: 0.1,
        spawnIntervalMax: 0.3,
        offset3dDistance: 3,
        entries: [
          (
            1,
            InstrumentDef(
              guid: 'e3',
              kind: 'sample',
              waveform: _wave('noise', 24000, 2),
            ),
          ),
        ],
      ),
      length: 72000,
    ),
    'event:voice': _event(
      'event:voice',
      'bus:voice',
      InstrumentDef(guid: 'i4', kind: 'slot'),
      length: 0,
      parameters: [
        ParameterDef(
          guid: 'p1',
          name: 'Trigger',
          instruments: [
            SheetPlacement(
              start: 0,
              length: 1,
              instrument: InstrumentDef(guid: 'i5', kind: 'slot'),
            ),
          ],
        ),
      ],
    ),
    'event:quad': _event(
      'event:quad',
      'bus:wide',
      InstrumentDef(
        guid: 'i6',
        kind: 'sample',
        waveform: _wave('quad', 12000, 4),
      ),
      track: StripDef(
        guid: 'event:quad/t',
        output: 'event:quad/m',
        layout: ChannelLayout.surround51,
      ),
    ),
    'event:duck': EventDef(
      guid: 'event:duck',
      path: 'event:duck',
      kind: EventKind.mixState,
      masterTrack: StripDef(guid: 'event:duck/m'),
      mixState: MixStateDef(
        priority: 1,
        entries: [
          MixEntry(target: 'fx', property: Prop.volume, value: -12),
          MixEntry(target: 'lp', property: Prop.effectParameter, value: 2000),
        ],
      ),
    ),
  };

  /// The engine over the project.
  AudioEngine engine({int seed = 3}) {
    final events = this.events();
    final mixer = MixerGraph(this.mixer())
      ..addMixStates(events.values.where((e) => e.isMixState));
    return AudioEngine(events, mixer, sample, sounds: sound, seed: seed);
  }

  /// A script of every command kind, by frame.
  static List<(int, AudioCommand)> script() => [
    (0, const StartEvent(1, 'event:tone')),
    (0, const SetSpatial(1, 30, 2, 10)),
    (4800, const StartEvent(2, 'event:playlist')),
    (9600, const StartEvent(3, 'event:scatter')),
    (12000, const StartEvent(4, 'event:voice', sound: 'voice')),
    (12000, const SetParameter(4, 'Trigger', 0.5)),
    (14400, const StartEvent(5, 'event:quad')),
    (24000, const StartMixState(10, 'event:duck')),
    (36000, const SetVolume(2, 0.5)),
    (40000, const SetPaused(3, true)),
    (52000, const SetPaused(3, false)),
    (60000, const StopMixState(10)),
    (72000, const StopEvent(2)),
    (80000, const StopEvent(3, fade: false)),
  ];

  /// Frames that the script renders.
  static const frames = 120000;
}
