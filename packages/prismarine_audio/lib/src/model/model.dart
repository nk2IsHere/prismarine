import 'curve.dart';

/// The 48 kHz timeline unit.
const timelineRate = 48000;

/// An event or a mix state of a project.
enum EventKind { event, mixState }

/// The channel layout of a strip's input.
enum ChannelLayout { mono, stereo, quad, surround51 }

/// What a start past a polyphony limit does.
enum PolyphonyMode { failNew, stealOldest }

/// The source of a parameter's value.
enum ParameterKind { game, distance, cone, other }

/// The DSP of an effect. The order is the native engine's numbering.
enum EffectKind {
  lowpass,
  highpass,
  echo,
  flange,
  distortion,
  parametricEq,
  limiter,
  compressor,
  reverb,
  tremolo,
  pan,
  threeBandEq,
  chorus,
  multibandEq,
  channelMix,
  objectPan,
}

/// The numbers of the properties that automation, modulators and mix state
/// entries refer to. An effect's parameter n is [effectParameter] + n.
abstract final class Prop {
  static const volume = 0;
  static const pitch = 1;
  static const intensity = 3;
  static const fadeGain = 4;
  static const offsetDirection = 5;
  static const offsetElevation = 6;
  static const offsetDistance = 7;
  static const startOffset = 9;
  static const effectParameter = 1000;
}

class EventDef {
  EventDef({
    required this.guid,
    this.path,
    this.kind = EventKind.event,
    this.inputBus,
    required this.masterTrack,
    this.tracks = const [],
    this.returns = const [],
    this.parameters = const [],
    TimelineDef? timeline,
    this.maxPolyphony = 0,
    this.polyphonyMode = PolyphonyMode.failNew,
    bool? oneShot,
    this.userProperties = const {},
    this.mixState,
  }) : timeline = timeline ?? TimelineDef.empty,
       oneShot = oneShot ?? _oneShot(timeline ?? TimelineDef.empty);

  final String guid;
  final String? path;
  final EventKind kind;

  /// The strip that takes the master track's output into a mixer bus.
  final StripDef? inputBus;
  final StripDef masterTrack;
  final List<StripDef> tracks, returns;
  final List<ParameterDef> parameters;
  final TimelineDef timeline;

  /// Instances that may play at once, 0 for no limit.
  final int maxPolyphony;
  final PolyphonyMode polyphonyMode;

  /// The event ends on its own.
  final bool oneShot;

  /// Values that the game reads, by name.
  final Map<String, double> userProperties;

  /// The mix state part of a [EventKind.mixState] event.
  final MixStateDef? mixState;

  bool get isMixState => kind == EventKind.mixState;

  /// No loop region and no sample that loops forever outside a timelocked
  /// box.
  static bool _oneShot(TimelineDef t) =>
      !t.transitions.any((t) => t.isLoop) &&
      !t.placements.any((p) => p.instrument.loopCount == -1 && !p.timelocked);

  /// The event's sound depends on its position: it has a distance or cone
  /// parameter, a 3D panner on a strip, or a nested event that does.
  late final bool spatial =
      parameters.any((p) => p.kind != ParameterKind.game) ||
      [masterTrack, ...tracks, ...returns].any((b) => b.effects.any(_pan3d)) ||
      timeline.placements.any((p) => _nestedSpatial(p.instrument)) ||
      parameters.any(
        (p) => p.instruments.any((s) => _nestedSpatial(s.instrument)),
      );

  static bool _pan3d(EffectDef fx) {
    if (fx is! DspEffect || fx.kind != EffectKind.pan || fx.bypass) {
      return false;
    }
    final ps = fx.params;
    if (ps.length < 18) return false;
    return (ps[0].stored ?? 0) == 2 && (ps[17].stored ?? 0) > 0;
  }

  static bool _nestedSpatial(InstrumentDef i) =>
      (i.nested?.spatial ?? false) ||
      i.entries.any((e) => _nestedSpatial(e.$2));
}

/// A track, master track, return, input bus or mixer bus.
class StripDef {
  StripDef({
    required this.guid,
    this.master = false,
    this.output,
    this.outputPath,
    this.volume = 0,
    this.pitch = 0,
    this.layout = ChannelLayout.stereo,
    this.effects = const [],
    this.properties = const [],
  });

  final String guid;

  /// The master bus of the mixer.
  final bool master;

  /// The id of the strip it feeds, and the path of the mixer bus that an
  /// event's input bus feeds.
  final String? output, outputPath;

  /// Strip volume in dB and pitch in semitones.
  final double volume, pitch;
  final ChannelLayout layout;
  final List<EffectDef> effects;
  final List<PropertyDef> properties;

  PropertyDef? property(int index) =>
      properties.where((p) => p.index == index).firstOrNull;
}

/// One stage of a strip.
sealed class EffectDef {
  EffectDef({
    required this.guid,
    this.bypass = false,
    this.prefader = false,
    this.properties = const [],
  });

  final String guid;
  final bool bypass, prefader;

  /// Automation and modulators of its parameters ([Prop.effectParameter] +
  /// n) or of a send's level ([Prop.volume]).
  final List<PropertyDef> properties;
}

/// A DSP. A null [kind] is an effect that the engine does not have, which it
/// skips with a problem that has [label].
class DspEffect extends EffectDef {
  DspEffect({
    required super.guid,
    required this.kind,
    this.label = '',
    this.params = const [],
    this.sidechainInput = false,
    this.passAtTop = false,
    super.bypass,
    super.prefader,
    super.properties,
  });

  final EffectKind? kind;
  final String label;
  final List<EffectParam> params;

  /// A compressor that takes its key from sidechain taps.
  final bool sidechainInput;

  /// A lowpass at a cutoff of 22000 Hz or more and a resonance of 1 or less
  /// passes its input unchanged.
  final bool passAtTop;
}

/// A parameter value of a [DspEffect]: a number, an on or off switch, or
/// nothing, which keeps the DSP's default.
class EffectParam {
  const EffectParam.number(double this.value) : isSwitch = false;
  const EffectParam.toggle(bool on) : value = on ? 1 : 0, isSwitch = true;
  const EffectParam.none() : value = null, isSwitch = false;

  final double? value;
  final bool isSwitch;

  /// The value that mix states and modulators start from: a number only.
  double? get stored => isSwitch ? null : value;
}

/// A send of the strip's signal into the return bus [returnBus] at [level]
/// dB.
class SendEffect extends EffectDef {
  SendEffect({
    required super.guid,
    required this.returnBus,
    this.returnPath,
    this.level = -80,
    super.bypass,
    super.prefader,
    super.properties,
  });

  final String returnBus;
  final String? returnPath;
  final double level;
}

/// A tap of the strip's signal into the sidechain input of the compressors
/// [targets]. An inactive tap is skipped.
class SidechainTap extends EffectDef {
  SidechainTap({
    required super.guid,
    this.targets = const [],
    this.active = true,
    this.label = '',
    super.bypass,
    super.prefader,
    super.properties,
  });

  final List<String> targets;
  final bool active;
  final String label;
}

/// Automation curves and modulators on one property of its owner.
class PropertyDef {
  PropertyDef({
    required this.index,
    this.isVolume = false,
    this.mapping,
    this.automation = const [],
    this.modulators = const [],
  });

  /// A [Prop] number.
  final int index;

  /// A volume in dB: several curves add.
  final bool isVolume;

  /// UI units to property units, null for the identity.
  final PiecewiseMap? mapping;
  final List<AutomationDef> automation;
  final List<ModulatorDef> modulators;
}

class AutomationDef {
  AutomationDef({
    this.onTimeline = false,
    this.parameterGuid,
    this.parameterName,
    required this.curve,
  });

  /// x is a timeline position, not a parameter value.
  final bool onTimeline;
  final String? parameterGuid, parameterName;
  final Curve curve;
}

class ModulatorDef {
  ModulatorDef({
    required this.type,
    this.minimum = 0,
    this.maximum = 0,
    this.initial = 0,
    this.peak = 0,
    this.sustain = 0,
    this.attack = 0,
    this.hold = 0,
    this.decay = 0,
    this.release = 0,
  });

  /// `random` or `ahdsr`.
  final String type;

  /// Random: the range of a draw at each start.
  final double minimum, maximum;

  /// AHDSR: levels in the property's UI units, times in seconds.
  final double initial, peak, sustain, attack, hold, decay, release;
}

/// Decoded audio that instruments play. [key] is unique in a project.
class WaveformDef {
  WaveformDef({
    required this.key,
    this.path,
    this.label = '',
    this.frames = 0,
    this.rate = timelineRate,
    this.channels = 1,
    this.streamed = false,
  });

  final String key;

  /// The file, null when the project has none.
  final String? path;

  /// The waveform in problems.
  final String label;
  final int frames, rate, channels;

  /// Streamed from its file while it plays, not loaded.
  final bool streamed;
}

class InstrumentDef {
  InstrumentDef({
    required this.guid,
    required this.kind,
    this.volume = 0,
    this.pitch = 0,
    this.loopCount = 0,
    this.cutoff = false,
    this.outputBus,
    this.properties = const [],
    this.waveform,
    this.triggerChance = 100,
    this.triggerDelayMin = 0,
    this.triggerDelayMax = 0,
    this.offset3dDistance = 0,
    this.initialSeekPosition = 0,
    this.leftTrim = 0,
    this.mixStateIntensity = 100,
    this.spawnIntervalMin = 0,
    this.spawnIntervalMax = 0,
    this.spawnCount = 0,
    this.maxSpawnPolyphony = 0,
    this.spawnPolyphonyMode = PolyphonyMode.failNew,
    this.maxPolyphony = 0,
    this.polyphonyMode = PolyphonyMode.failNew,
    this.nested,
    this.parameterStubs = const [],
    this.shuffle = false,
    this.entries = const [],
  });

  final String guid;

  /// `single`, `multi`, `scatterer`, `programmer` or `event`. Another kind
  /// plays nothing and reports a problem.
  final String kind;

  /// dB and semitones.
  final double volume, pitch;

  /// −1 loops forever.
  final int loopCount;

  /// Stops when its trigger region is left.
  final bool cutoff;

  /// The track or master track it plays into, null in playlist entries.
  final String? outputBus;
  final List<PropertyDef> properties;
  final WaveformDef? waveform;

  /// A playlist picks its entries at random by weight, never the last pick
  /// twice, in place of in order.
  final bool shuffle;
  final List<(double weight, InstrumentDef)> entries;

  /// Trigger chance in percent and a random delay in ms, drawn at each
  /// trigger.
  final double triggerChance, triggerDelayMin, triggerDelayMax;

  /// The 3D offset distance, the base of [Prop.offsetDistance].
  final double offset3dDistance;

  /// The start offset in ms, the base of [Prop.startOffset].
  final double initialSeekPosition;

  /// The waveform frames that a timelocked placement skips.
  final int leftTrim;

  /// A mix state instrument's intensity in percent.
  final double mixStateIntensity;

  /// Scatterer: seconds between spawns, spawns per trigger with 0 for no
  /// limit, and live spawns at most with what a spawn past it does.
  final double spawnIntervalMin, spawnIntervalMax;
  final int spawnCount, maxSpawnPolyphony;
  final PolyphonyMode spawnPolyphonyMode;

  /// Sounds of this instrument that one event instance plays at once, 0
  /// for no limit.
  final int maxPolyphony;
  final PolyphonyMode polyphonyMode;

  /// An event instrument's event and its parameter stubs, each a property
  /// number on this instrument, the nested parameter's id and its initial
  /// value.
  final EventDef? nested;
  final List<(int, String, double)> parameterStubs;

  PropertyDef? property(int index) =>
      properties.where((p) => p.index == index).firstOrNull;
}

/// An instrument on the timeline, [start] and [length] in timeline frames.
class Placement {
  Placement({
    required this.start,
    required this.length,
    this.timelocked = false,
    this.fill = true,
    required this.instrument,
  });

  final int start, length;
  final bool timelocked;

  /// A timelocked waveform shorter than the box repeats until the box ends.
  final bool fill;
  final InstrumentDef instrument;
  int get end => start + length;
}

/// An instrument on a parameter sheet, [start] and [length] in parameter
/// units.
class SheetPlacement {
  SheetPlacement({
    required this.start,
    required this.length,
    required this.instrument,
  });

  final double start, length;
  final InstrumentDef instrument;
  bool contains(double v) => v >= start && v < start + length;
}

class ParameterDef {
  ParameterDef({
    required this.guid,
    this.name = '',
    this.kind = ParameterKind.game,
    this.minimum = 0,
    this.maximum = 1,
    this.defaultValue = 0,
    this.seekSpeed = 0,
    this.instruments = const [],
  });

  final String guid, name;
  final ParameterKind kind;
  final double minimum, maximum, defaultValue, seekSpeed;
  final List<SheetPlacement> instruments;
}

class TempoMarker {
  TempoMarker({
    this.position = 0,
    this.tempo = 120,
    this.beatsPerBar = 4,
    this.beatUnit = 4,
  });

  final int position;
  final double tempo;
  final int beatsPerBar, beatUnit;
}

class TransitionDef {
  TransitionDef({
    this.isLoop = false,
    required this.start,
    required this.end,
    this.destination = 0,
    this.conditionParameter,
    this.conditionMin = 0,
    this.conditionMax = 1,
    this.unit = 0,
    this.multiplier = 0,
    this.chancePercent = 100,
  });

  /// A loop region: [start] to [end], back to [destination].
  final bool isLoop;
  final int start, end, destination;
  final String? conditionParameter;
  final double conditionMin, conditionMax;

  /// Quantization: unit 1 is a bar, 2 an eighth note, 0 none. The interval
  /// is [multiplier] units.
  final int unit, multiplier;
  final double chancePercent;

  bool get isMarker => !isLoop && start == end;
}

class TimelineDef {
  TimelineDef({
    this.placements = const [],
    this.end = 0,
    List<TempoMarker> tempo = const [],
    this.transitions = const [],
  }) : tempo = [...tempo]..sort((a, b) => a.position.compareTo(b.position));

  static final empty = TimelineDef();

  final List<Placement> placements;

  /// The last placement's end in timeline frames.
  final int end;

  /// The cursor stops at the end of the last placement, loop region or
  /// transition.
  late final int length = transitions.fold(
    end,
    (e, t) => [e, t.start, t.end].reduce((a, b) => a > b ? a : b),
  );
  final List<TempoMarker> tempo;
  final List<TransitionDef> transitions;
}

/// The mix state part of an event: entries that pull properties of the
/// mixer toward values by its intensity.
class MixStateDef {
  MixStateDef({
    this.priority = 0,
    this.intensity = 1,
    this.entries = const [],
    this.intensityProperty,
  });

  /// Lower priorities apply first.
  final int priority;

  /// The intensity of its own, 0 to 1.
  final double intensity;
  final List<MixEntry> entries;

  /// The automation of the intensity.
  final PropertyDef? intensityProperty;
}

/// A property [property] of the mixer object [target] pulled toward [value],
/// or toward [automation] at the mix state's parameters.
class MixEntry {
  MixEntry({
    required this.target,
    required this.property,
    required this.value,
    this.automation,
  });

  final String target;
  final int property;
  final double value;
  final PropertyDef? automation;
}

/// The mixer: its buses, with one master bus.
class MixerDef {
  MixerDef({this.buses = const [], this.paths = const {}});

  final List<StripDef> buses;

  /// Bus paths by bus id.
  final Map<String, String> paths;

  /// The path of the master bus.
  String? get masterPath {
    for (final b in buses) {
      if (b.master) return paths[b.guid];
    }
    return null;
  }
}
