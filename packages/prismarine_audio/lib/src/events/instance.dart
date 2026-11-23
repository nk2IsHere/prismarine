import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;

import '../mixer/mix_state.dart';
import '../mixer/strip.dart';
import '../model/curve.dart';
import '../model/model.dart';
import '../pcm_source.dart';
import 'formats.dart';
import 'player.dart';
import 'rng.dart';
import 'voice.dart';

part 'instance_sounds.dart';
part 'instance_timeline.dart';

/// Quantized transitions take a grid point only when their condition holds at
/// least this long before it (O: 0.459–0.502 s on `mus_autoChickenFarm`).
const transitionLookahead = 0.48 * timelineRate;

/// The pitch span (semitones) a random pitch modulator's percent refers to
/// (O: ±4.1667 → ±2 st).
const _pitchSpan = 48.0;

const _declick = 64;

/// A stolen instance plays on for one FMOD mix block, then is cut (O: the
/// oldest of `Destr_Wood_LightDebris_01` at max 2 ends at the block after
/// the new start's).
const _stealDelay = 1024;

/// A playing event (FMOD Studio EventInstance): a 48 kHz timeline cursor,
/// parameters, voices, and the event's tracks (with their effects, automation
/// and sends) into its master track and input bus.
class EventInstance implements StripSink {
  /// FMOD's paused flag: no output, no advance.
  bool paused = false;

  EventInstance(this.player, this.def, this._rng, {this.slot, double seek = 0})
    : cursor = (math.max(0, seek) * timelineRate).round() {
    _init();
  }

  void _init() {
    for (final p in def.parameters) {
      _params[p.guid] = p.defaultValue.clamp(p.minimum, p.maximum);
      _paramByName[p.name.toLowerCase()] = p;
    }
    for (final b in [...def.tracks, ...def.returns, def.masterTrack]) {
      _strips[b.guid] = BusStrip(
        b,
        problem: player.problem,
        format: def.stripFormats[b.guid],
      );
    }
    _master = _strips[def.masterTrack.guid]!;
    if (def.inputBus case final ib?) {
      _inputBus = BusStrip(
        ib,
        problem: player.problem,
        format: def.stripFormats[ib.guid],
      );
    }
    _order = [
      for (final b in def.tracks) _strips[b.guid]!,
      for (final b in def.returns) _strips[b.guid]!,
      _master,
    ];

    for (final b in [
      ...def.tracks,
      ...def.returns,
      def.masterTrack,
      ?def.inputBus,
    ]) {
      for (final p in b.properties) {
        if (p.automation.isNotEmpty) _props[(b.guid, p.index)] = p;
      }
      for (final fx in b.effects) {
        for (final p in fx.properties) {
          if (p.automation.isNotEmpty) _props[(fx.guid, p.index)] = p;
        }
      }
    }
    _asyncInside.addAll(List.filled(def.timeline.placements.length, false));
    _locked.addAll(List.filled(def.timeline.placements.length, null));
    _modulate();
  }

  /// The master track's modulators, drawn or armed at the start: random
  /// volume (dB) and pitch (percent of the UI span), the AHDSR on volume;
  /// and random modulators on effect parameters (percent of their UI span,
  /// added to the stored value's UI position) [I: by analogy with the
  /// instrument rules, O].
  void _modulate() {
    final master = def.masterTrack;
    for (final p in master.properties) {
      for (final m in p.modulators) {
        switch ((p.index, m.type)) {
          case (0, 'random'):
            _baseDb += _rng.range(m.minimum, m.maximum);
          case (1, 'random'):
            _pitch += _uiOffset(p, _rng.range(m.minimum, m.maximum));
          case (0, 'ahdsr'):
            _env = m;
            _envMap = p.mapping;
          default:
            player.problem(
              'unsupported ${m.type} modulator on bus property ${p.index} '
              'in ${def.path}',
            );
        }
      }
    }
    for (final b in [...def.tracks, ...def.returns, master, ?def.inputBus]) {
      for (final fx in b.effects) {
        if (fx is! DspEffect) continue;
        final params = fx.params;
        for (final p in fx.properties) {
          final n = p.index - 1000;
          if (p.modulators.isEmpty || n < 0 || n >= params.length) continue;
          final stored = params[n].stored;
          if (stored == null) continue;
          var ui = p.mapping?.unmap(stored) ?? stored;
          for (final m in p.modulators) {
            if (m.type != 'random') {
              player.problem(
                'unsupported ${m.type} modulator on an effect '
                'in ${def.path}',
              );
              continue;
            }
            ui +=
                _rng.range(m.minimum, m.maximum) / 100 * (p.mapping?.span ?? 1);
          }
          final v = p.mapping?.map(ui) ?? ui;
          final strip = _strips[b.guid] ?? _inputBus;
          strip?.effect(fx.guid)?.set(n, v);
        }
      }
    }
  }

  /// A random modulator's draw [pct] (percent of [p]'s UI span) in property
  /// units relative to the UI centre (pitch: ±4.1667 % of 48 st = ±2 st, O).
  static double _uiOffset(PropertyDef p, double pct) {
    final m = p.mapping;
    if (m == null) return pct;
    return m.map(m.unmap(0) + pct / 100 * m.span) - m.map(m.unmap(0));
  }

  final EventPlayer player;
  final EventDef def;
  final Rng _rng;

  /// The sound programmer instruments play (a voice line).
  final PcmSource? slot;

  /// The timeline position in 48 kHz samples.
  int cursor;
  bool _stopping = false, _done = false, _stolen = false;

  /// Stopped with FMOD's immediate mode (not a fade-out or a steal).
  bool _immediate = false;

  /// Frames into the declick (negative: frames before it starts).
  int _stopAt = 0;

  final _params = <String, double>{};
  final _paramByName = <String, ParameterDef>{};
  final _strips = <String, BusStrip>{};
  late final BusStrip _master;
  BusStrip? _inputBus;
  late final List<BusStrip> _order;
  final _props = <(String, int), PropertyDef>{};

  /// This block's sends into mixer returns outside the event, by path.
  final sendOutputs = <String, Float32List>{};
  final _voices = <_Sound>[];

  /// Master volume (dB) and pitch (semitones) from random modulators.
  double _baseDb = 0, _pitch = 0;

  /// The AHDSR on the master volume (UI units through [_envMap]).
  ModulatorDef? _env;
  PiecewiseMap? _envMap;

  /// Seconds since the start (the AHDSR's clock) and since the release
  /// began (null: not releasing).
  double _age = 0;
  double? _released;
  double _releaseFrom = 0;

  /// Pitched output: rendered frames not yet resampled, per output (main
  /// and each send path), and the read position in them.
  _Pitched? _pitched;
  final _asyncInside = <bool>[];
  final _locked = <_Locked?>[];
  final _sheetInside = <SheetPlacement>{};
  final _playlists = <String, int>{};

  /// Raw passes rendered (a stolen sound knows whether it has rendered
  /// this one).
  int _pass = 0;
  (TransitionDef, int)? _pending;

  String get outputPath => def.inputBus?.outputPath ?? player.defaultBus;

  /// EventInstance volume (linear), ramped over a block.
  double volume = 1;
  double? _volume;

  /// Whether it has rendered: until then a volume is the one it starts
  /// with (the audio thread's start sets the channel's volume before
  /// `start()`; see formats/telltale/sound-runtime.md, "A channel starts
  /// with its volume").
  bool get hasPlayed => _volume != null;
  bool get isDone => _done;

  /// The low-level channels it plays now (FMOD 1.06 has 64 real ones, the
  /// rest go virtual by audibility: not modelled, measured with
  /// [EventPlayer.peakChannels]): started sample voices, timelocked sounds
  /// under the cursor, and its nested events' channels.
  int get channels {
    if (_done) return 0;
    var n = 0;
    for (final l in _locked) {
      if (l != null) n++;
    }
    for (final v in _voices) {
      if (v.ended) continue;
      if (v is _Voice && v.delay == 0) n++;
      if (v is _Nested) n += v.event.channels;
    }
    return n;
  }

  /// Cut by its event's polyphony (it no longer counts against it).
  bool get isStolen => _stolen;

  /// Stopped by a newer instance past its event's polyphony: one mix block
  /// later it is cut with the declick.
  void steal() {
    if (_done || _stolen) return;
    _stolen = true;
    if (_stopping) return;
    _stopping = true;
    _stopAt = -_stealDelay;
  }

  /// Seconds left on the programmer sound (a dialog channel's length and
  /// position are its sound's): its whole length before it
  /// starts, 0 once it has finished; null without one.
  double? get slotLeft {
    final src = slot;
    if (src == null) return null;
    for (final v in _voices.whereType<_Voice>()) {
      if (identical(v.reader.source, src)) {
        return math.max(0, src.frames - v.pos) / src.sampleRate;
      }
    }
    return _slotStarted ? 0 : src.frames / src.sampleRate;
  }

  bool _slotStarted = false;

  /// The event's position relative to the listener (FMOD Studio's 3D
  /// attributes, recomputed each update): direction in degrees (0 ahead,
  /// +90 right), distance and cone angle; null until set.
  (double, double, double)? spatial;

  /// Sets the event's relative position: its automatic distance parameters
  /// (type 1, clamped to their range; O: `sfx_TempleInt_Torch_lp` reads 0.5,
  /// 1, …, 8 then 10 for distances 0.5–30 on [0, 10]) and cone-angle
  /// parameters (type 2, the same way; O: `SFX_furnaceFire_3D`), its PAN
  /// DSPs, and its nested events (they play where their parent does).
  void setSpatial(double azimuth, double distance, [double cone = 0]) {
    spatial = (azimuth, distance, cone);
    for (final p in def.parameters) {
      if (p.kind == ParameterKind.distance) {
        _params[p.guid] = distance.clamp(p.minimum, p.maximum).toDouble();
      } else if (p.kind == ParameterKind.cone) {
        _params[p.guid] = cone.clamp(p.minimum, p.maximum).toDouble();
      }
    }
    for (final st in [..._order, ?_inputBus]) {
      for (final pan in st.pans) {
        pan
          ..azimuth = azimuth
          ..distance = distance;
      }
    }
    for (final v in _voices) {
      if (v is _Nested) v.event.setSpatial(azimuth, distance, cone);
      if (v is _SnapshotSound) v.snap?.setAuto(distance, cone);
    }
  }

  double parameter(String name) =>
      _params[_paramByName[name.toLowerCase()]?.guid] ?? 0;

  /// Sets a game parameter (clamped to its range, applied at the next
  /// render: seek speed 0); false for a name the event lacks.
  bool setParameter(String name, double value) {
    final p = _paramByName[name.toLowerCase()];
    if (p == null) return false;
    _params[p.guid] = value.clamp(p.minimum, p.maximum).toDouble();
    return true;
  }

  /// Stops: with [fade] and an AHDSR on the master volume, through its
  /// release (O: `AMB_FieldNightLoop` fades over its 1 s release, then
  /// ends); else after a short declick.
  void stop({bool fade = true}) {
    if (_stopping || _done || _released != null) return;
    final env = _env;
    if (fade && env != null && env.release > 0) {
      _releaseFrom = _envLevel(_age);
      _released = 0;
      return;
    }
    _stopping = true;
    _immediate = !fade;
    _stopAt = 0;
  }

  /// The AHDSR's level (UI units) [t] seconds after the start, before any
  /// release.
  double _envLevel(double t) => ahdsrLevel(_env!, t);

  /// An AHDSR's level (UI units) [t] seconds after its start, before any
  /// release: linear segments (O: FMOD 1.06 ignores the attack shape; a
  /// pitch envelope's ramp is linear to 0.05 st).
  static double ahdsrLevel(ModulatorDef e, double t) {
    if (t < e.attack) return e.initial + (e.peak - e.initial) * t / e.attack;
    t -= e.attack;
    if (t < e.hold) return e.peak;
    t -= e.hold;
    if (t < e.decay) return e.peak + (e.sustain - e.peak) * t / e.decay;
    return e.sustain;
  }

  /// The master's modulated gain [dt] seconds into this block.
  double _envGain(double dt) {
    final e = _env;
    if (e == null) return 1;
    final r = _released;
    final ui = r == null
        ? _envLevel(_age + dt)
        : (r + dt >= e.release
              ? e.initial
              : _releaseFrom +
                    (e.initial - _releaseFrom) * (r + dt) / e.release);
    return dbToGain(_envMap?.map(ui) ?? ui);
  }

  /// Nested events take their parameter values from their stubs.
  void setParameterGuid(String guid, double value) {
    final p = def.parameters.where((p) => p.guid == guid).firstOrNull;
    if (p == null) return;
    _params[guid] = value.clamp(p.minimum, p.maximum).toDouble();
  }

  bool _holds(String? guid, double lo, double hi) {
    if (guid == null) return true;
    final v = _params[guid];
    return v != null && v >= lo && v <= hi;
  }

  /// Adds [frames] stereo frames of the event's output into [out]; sends to
  /// mixer returns land in [sendOutputs]. A pitched event (its master's
  /// pitch modulation, or an event instrument's pitch) plays its whole
  /// output resampled, as its channel group's pitch does [I: effects inside
  /// it are resampled too].
  void render(Float32List out, int frames) {
    sendOutputs.clear();
    if (_done) return;
    if (paused) {
      // FMOD's immediate stop ends a paused instance at once, its nested
      // snapshots with it; a fade-out waits for the resume [O: FMOD 1.09,
      // a paused MIXEvent_MUS stopped with mode 1 lets the music bus up in
      // that update, with mode 0 not].
      if (_immediate) _finish();
      return;
    }
    if (_pitch == 0 && _pitched == null) {
      _renderRaw(out, frames);
      return;
    }
    final pt = _pitched ??= _Pitched(libm.dpow(2, _pitch / 12));
    pt.render(this, out, frames);
  }

  void _renderRaw(Float32List out, int frames) {
    sendOutputs.clear();
    if (_done) return;
    _pass++;
    for (final b in _strips.values) {
      b.begin(frames);
    }
    _inputBus?.begin(frames);
    _triggerSheets();
    _timeline(frames);
    // Sounds started while rendering (scatterer spawns) render this block.
    for (var k = 0; k < _voices.length; k++) {
      final v = _voices[k];
      v.pass = _pass;
      if (!v.render(this, frames)) v.ended = true;
    }
    _voices.removeWhere((v) => v.ended);
    // The instance volume (with the master's random volume and AHDSR) is
    // the master track's fader gain (BusStrip.faderFrom/To).
    final base = dbToGain(_baseDb);
    _master
      ..faderFrom = (_volume ?? volume) * base * _envGain(0)
      ..faderTo = volume * base * _envGain(frames / timelineRate);
    _volume = volume;
    for (final st in _order) {
      st.process(frames, _prop, this);
      if (identical(st, _master)) break;
      final to = _strips[st.def.output] ?? _master;
      to.add(
        st.output,
        frames,
        srcMono: st.outputMono,
        srcCh: st.outputChannels,
      );
    }
    var last = _master;
    if (_inputBus case final ib?) {
      ib.add(
        _master.output,
        frames,
        srcMono: _master.outputMono,
        srcCh: _master.outputChannels,
      );
      ib.process(frames, _prop, this);
      last = ib;
    }
    final m = last.output;
    final up = last.outputMono ? upmixGain : 1.0;
    final ch = last.outputChannels;
    _age += frames / timelineRate;
    for (var i = 0; i < frames; i++) {
      var k = up;
      if (_stopping) {
        final left = _declick - _stopAt - i;
        k *= left <= 0 ? 0 : (left >= _declick ? 1 : left / _declick);
      }
      if (ch == 2) {
        out[i * 2] += m[i * 2] * k;
        out[i * 2 + 1] += m[i * 2 + 1] * k;
      } else {
        for (var c = 0; c < 6; c++) {
          out[i * 6 + c] += m[i * 6 + c] * k;
        }
      }
    }
    if (_stopping) {
      _stopAt += frames;
      if (_stopAt >= _declick) _finish();
      return;
    }
    if (_released case final r?) {
      _released = r + frames / timelineRate;
      if (_released! >= _env!.release) _finish();
      return;
    }
    // An event plays on while its tracks' effects ring out (O: the Echo
    // return of `sfx_bigGhast_moan` repeats for 4 s after its sound).
    if (cursor >= def.timeline.length &&
        _voices.isEmpty &&
        _pending == null &&
        _order.every((s) => s.quiet) &&
        (_inputBus?.quiet ?? true)) {
      _finish();
    }
  }

  /// The output's channels: 6 for an event whose output is 5.1 (S2).
  int get outputChannels => (_inputBus ?? _master).outputChannels;

  @override
  void send(
    String returnBus,
    String? returnPath,
    Float32List buf,
    bool mono, {
    int channels = 2,
  }) {
    final local = _strips[returnBus];
    if (local != null) {
      local.add(buf, buf.length ~/ channels, srcMono: mono, srcCh: channels);
      return;
    }
    if (channels == 6) {
      // Sends out of an event leave it in stereo [I: no S2 event sends
      // after a surround PAN].
      buf = downmix51(buf, buf.length ~/ 6);
      mono = false;
    }
    final key = returnPath ?? returnBus;
    final o = sendOutputs.putIfAbsent(key, () => Float32List(buf.length));
    final k = mono ? upmixGain : 1.0;
    for (var i = 0; i < buf.length; i++) {
      o[i] += buf[i] * k;
    }
  }

  @override
  void sidechain(List<String> targets, Float32List buf) =>
      player.problem('sidechain inside an event: ${def.path}');

  /// An automated property's value now (mapped), or null.
  double? _prop(String owner, int index) => _automated(_props[(owner, index)]);

  void _finish() {
    _done = true;
    for (final v in _voices) {
      v.dispose();
    }
    _voices.clear();
  }

  // --- parameters and properties ---------------------------------------

  double _input(AutomationDef a) => a.onTimeline
      ? cursor.toDouble()
      : (_params[a.parameterGuid] ??
            _params[_paramByName[a.parameterName?.toLowerCase()]?.guid] ??
            0);

  /// [p]'s automated value in property units, or null when not automated.
  double? _automated(PropertyDef? p, [double Function(AutomationDef)? x]) {
    if (p == null || p.automation.isEmpty) return null;
    double? r;
    for (final a in p.automation) {
      final ui = a.curve.at((x ?? _input)(a));
      final v = p.mapping?.map(ui) ?? ui;
      r = r == null
          ? v
          : p.isVolume
          ? r + v
          : p.index == 4
          ? r * v
          : v;
    }
    return r;
  }

  // --- triggering --------------------------------------------------------

  /// Parameter-sheet instruments start when their parameter enters their
  /// range (default values included) and, with cutoff, stop when it leaves.
  void _triggerSheets() {
    for (final p in def.parameters) {
      final v = _params[p.guid] ?? p.defaultValue;
      for (final s in p.instruments) {
        final inside = s.contains(v);
        final was = _sheetInside.contains(s);
        if (inside && !was) {
          _sheetInside.add(s);
          _trigger(s.instrument, 0, owner: s);
        } else if (!inside && was) {
          _sheetInside.remove(s);
          _cut(s);
        }
      }
    }
  }

  /// [owner]'s trigger region was left: cutoff sounds end, nested events
  /// with cutoff stop, scatterers stop spawning.
  void _cut(Object owner) {
    for (final v in _voices) {
      if (v.owner == owner) v.untrigger();
    }
    _voices.removeWhere((v) => v.ended);
  }

  /// Starts [inst] at block frame [at]: its trigger chance and delay are
  /// drawn first [I: chance in %, delay in ms, uniform].
  void _trigger(InstrumentDef inst, int at, {required Object owner}) {
    if (inst.triggerChance < 100 && _rng.next() * 100 >= inst.triggerChance) {
      return;
    }
    if (inst.triggerDelayMax > 0 || inst.triggerDelayMin > 0) {
      final ms = _rng.range(inst.triggerDelayMin, inst.triggerDelayMax);
      at += (ms * timelineRate / 1000).round();
    }
    _play(
      inst,
      at,
      owner: owner,
      bus: _strips[inst.outputBus] ?? _master,
      cutoff: inst.cutoff,
    );
  }

  /// FMOD's instrument polyphony, counted per event instance (O: a limit
  /// on `Destr_Wood_LightDebris_01`'s instrument doesn't limit four
  /// instances): with [InstrumentDef.maxPolyphony] of its sounds live, a
  /// trigger fails (behaviour 0) or stops the oldest at block frame [at]
  /// (2) [I: as events and scatterer spawns do]. False: refused.
  bool _admit(InstrumentDef inst, int at) {
    _Sound? oldest;
    var live = 0;
    for (final v in _voices) {
      if (v.ended || v.stolen || !v.via.any((d) => identical(d, inst))) {
        continue;
      }
      oldest ??= v;
      live++;
    }
    if (live < inst.maxPolyphony) return true;
    switch (inst.polyphonyMode) {
      case PolyphonyMode.failNew:
        return false;
      case PolyphonyMode.stealOldest:
        oldest!.steal(this, at);
        return true;
    }
  }

  /// Plays [inst] (single, programmer, multi, event or scatterer) into
  /// [bus] at block frame [at], with [volume] dB and [pitch] semitones from
  /// the instruments around it (a multi's or a scatterer's).
  void _play(
    InstrumentDef inst,
    int at, {
    required Object owner,
    required BusStrip bus,
    required bool cutoff,
    double volume = 0,
    double pitch = 0,
    (double, double)? pan,
    bool loop = false,
    double seekMs = 0,
    List<InstrumentDef> via = const [],
  }) {
    if (inst.maxPolyphony > 0 && !_admit(inst, at)) return;
    via = [...via, inst];
    volume += inst.volume + _modulation(inst, 0);
    pitch += inst.pitch + _modulation(inst, 1);
    seekMs += _startOffset(inst);
    loop = loop || inst.loopCount == -1;
    switch (inst.kind) {
      case 'playlist':
        final e = _pick(inst);
        if (e == null) return;
        _play(
          e,
          at,
          owner: owner,
          bus: bus,
          cutoff: cutoff,
          volume: volume,
          pitch: pitch,
          pan: pan,
          loop: loop,
          seekMs: seekMs,
          via: via,
        );
        return;
      case 'scatterer':
        final sc = _Scatter(inst, bus, owner: owner, delay: at)..via = via;
        final pp = inst.property(1);
        for (final m in pp?.modulators ?? const <ModulatorDef>[]) {
          if (m.type == 'ahdsr') {
            sc
              ..env = m
              ..pitchProp = pp
              ..s0 = pitch;
          }
        }
        _voices.add(sc);
        return;
      case 'event':
        final nested = inst.nested;
        if (nested == null) return;
        if (nested.isMixState) {
          _voices.add(
            _SnapshotSound(
              inst,
              nested,
              owner: owner,
              cutoff: cutoff,
              delay: at,
            )..via = via,
          );
          return;
        }
        final child = EventInstance(
          player,
          nested,
          Rng((_rng.next() * 4294967296).floor()),
        );
        child.volume = dbToGain(volume);
        child._pitch += pitch;
        for (final (_, guid, initial) in inst.parameterStubs) {
          child.setParameterGuid(guid, initial);
        }
        if (spatial case (final a, final d, final c)) child.setSpatial(a, d, c);
        _voices.add(
          _Nested(child, inst, bus, owner: owner, cutoff: cutoff, delay: at)
            ..via = via,
        );
        return;
      case 'sample' || 'slot':
        break;
      default:
        player.problem('unsupported instrument ${inst.kind} in ${def.path}');
        return;
    }
    final PcmSource? src;
    if (inst.kind == 'slot') {
      // Without a sound (non-dialog channels get none) it plays nothing.
      src = slot;
      if (src == null) return;
      _slotStarted = true;
    } else {
      final w = inst.waveform;
      if (w == null) return; // an empty single
      src = player.sample(w);
      if (src == null) return;
    }
    _voices.add(
      _Voice(
          SourceReader(src),
          bus,
          rate: src.sampleRate / timelineRate * libm.dpow(2, pitch / 12),
          gain: dbToGain(volume),
          loop: loop,
          cutoff: cutoff,
          owner: owner,
          delay: at,
          pan: pan,
        )
        ..via = via
        ..pos = _seekFrames(src, seekMs),
    );
  }

  /// The start offset (property 9) of [inst] in ms: its initial seek
  /// position, moved by its random modulators by percent of the UI span (O:
  /// `SFX_Building_Explosions`' ricochet multi with the modulator fixed at
  /// 30, 45 and 60 starts its take 144,000, 216,000 and 288,000 samples in,
  /// modulo the take's length; −10 clamps to 0).
  double _startOffset(InstrumentDef inst) {
    final base = inst.initialSeekPosition;
    final p = inst.property(9);
    if (p == null || p.modulators.isEmpty) return base;
    final m = p.mapping;
    var ui = m?.unmap(base) ?? base;
    for (final mod in p.modulators) {
      if (mod.type != 'random') {
        player.problem('unsupported modulator ${mod.type} in ${def.path}');
        continue;
      }
      ui += _rng.range(mod.minimum, mod.maximum) / 100 * (m?.span ?? 1);
    }
    return m?.map(ui) ?? math.max(0, ui);
  }

  /// A start offset of [ms] into [src], in its frames: seeking past the
  /// end wraps (O).
  static double _seekFrames(PcmSource src, double ms) {
    if (ms <= 0 || src.frames <= 0) return 0;
    return (ms * src.sampleRate / 1000) % src.frames;
  }

  /// One scatterer spawn at block frame [at]: the scatterer's playlist entry
  /// (a multi, single or event) with the entry's random 3D offset turned
  /// into a pan and a distance gain.
  void _spawn(_Scatter sc, int at) {
    final inst = sc.inst;
    final e = _pick(inst);
    if (e == null) return;
    final n = _voices.length;
    _play(
      e,
      at,
      owner: sc,
      bus: sc.bus,
      cutoff: false,
      volume: inst.volume + _modulation(inst, 0),
      pitch: inst.pitch + _modulation(inst, 1),
      pan: _position(e),
    );
    for (var k = n; k < _voices.length; k++) {
      sc.live.add(_voices[k]);
    }
  }

  /// A spawned instrument's position: direction (property 5, UI 0–1 →
  /// ±180°), elevation (6, ±90°) and distance (7, around
  /// offset3dDistance), each moved by its random modulator. It pans by
  /// direction (from behind folded to the sides, linear in angle) at
  /// constant power, and its level is 0.5·min(1, 1/distance). [I: fitted to
  /// the oracle's `SFX_Bat_Scatter` over 300 s (140 spawns): its levels form
  /// the samples' two clusters ~15.5 dB under a centred mono sound, which a
  /// fixed distance of 3 with this gain gives and a distance drawn over the
  /// UI span (±1 UI unit) smears out; so the distance's random draw is read
  /// as a percentage of the distance. Pans spread evenly from left to right
  /// in both, independent of level. docs/formats/fmod-bank.md.] Null when
  /// the instrument has no 3D offset.
  (double, double)? _position(InstrumentDef inst) {
    final pd = inst.property(5), pe = inst.property(6), pr = inst.property(7);
    if (pd == null && pe == null && pr == null && inst.offset3dDistance == 0) {
      return null;
    }
    double draw(PropertyDef? p) {
      var pct = 0.0;
      for (final mod in p?.modulators ?? const <ModulatorDef>[]) {
        if (mod.type == 'random') pct += _rng.range(mod.minimum, mod.maximum);
      }
      return pct / 100;
    }

    final dir = draw(pd) * 360; // UI centre 0.5 = straight ahead
    draw(pe); // elevation: drawn, not heard in stereo [I]
    final dist = inst.offset3dDistance * (1 + draw(pr));
    var a = dir % 360;
    if (a > 180) a -= 360;
    final p = (a.abs() <= 90 ? a : (a > 0 ? 180 - a : -180 - a)) / 90;
    final g = 0.5 * (dist <= 1 ? 1.0 : 1 / math.min(dist, 20));
    final th = (p + 1) * math.pi / 4;
    return (libm.cos(th) * g, libm.sin(th) * g);
  }

  /// A multi's next entry: weighted random, never the previous pick when
  /// there is another (a shuffled playlist), else in order [I].
  InstrumentDef? _pick(InstrumentDef multi) {
    final entries = multi.entries;
    if (entries.isEmpty) return null;
    final last = _playlists[multi.guid];
    int pick;
    if (multi.shuffle) {
      final pool = [
        for (var i = 0; i < entries.length; i++)
          if (entries.length == 1 || i != last) i,
      ];
      final total = pool.fold(0.0, (s, i) => s + entries[i].$1);
      var r = _rng.next() * total;
      pick = pool.last;
      for (final i in pool) {
        r -= entries[i].$1;
        if (r < 0) {
          pick = i;
          break;
        }
      }
    } else {
      pick = last == null ? 0 : (last + 1) % entries.length;
    }
    _playlists[multi.guid] = pick;
    return entries[pick].$2;
  }

  /// Random modulation of property [index] on [inst], drawn now: volume in
  /// dB, pitch as ±percent of 48 semitones (O).
  double _modulation(InstrumentDef inst, int index) {
    final p = inst.property(index);
    if (p == null) return 0;
    var sum = 0.0;
    for (final m in p.modulators) {
      if (m.type == 'ahdsr' && index == 1 && inst.kind == 'scatterer') {
        continue; // _Scatter plays it
      }
      if (m.type != 'random') {
        player.problem('unsupported modulator ${m.type} in ${def.path}');
        continue;
      }
      final u = _rng.range(m.minimum, m.maximum);
      sum += index == 0 ? u : u / 100 * _pitchSpan;
    }
    return sum;
  }

  // --- the timeline ------------------------------------------------------

  static final _defaultTempo = TempoMarker();
}
