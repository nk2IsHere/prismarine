part of 'instance.dart';

/// Returns the gain of a source into a strip. Mono into stereo upmixes and
/// stereo into mono downmixes, as in [BusStrip.add].
(double, bool) _format(PcmSource src, BusStrip bus) {
  final mono = src.channels == 1;
  if (mono && !bus.mono) return (upmixGain, false);
  if (!mono && bus.mono) return (1, true);
  return (1, false);
}

class _Locked {
  _Locked(
    this.reader,
    this.bus,
    this.rate,
    this.gain,
    this.seek, {
    required this.fill,
  });
  final SourceReader reader;
  final BusStrip bus;
  final double rate, gain;

  /// The waveform repeats to fill its box, from [Placement.fill].
  final bool fill;

  /// The start offset in source frames, from [Prop.startOffset].
  final double seek;
}

/// A sound that a trigger of an instrument started, a sample voice, a nested
/// event or a scatterer.
abstract class _Sound {
  _Sound(this.owner, {required this.cutoff});
  final Object owner;
  final bool cutoff;
  bool ended = false;

  /// The instruments that it was played through, a playlist and then its
  /// entry, for their polyphony limits.
  List<InstrumentDef> via = const [];

  /// The sound was stopped by a polyphony limit and no longer counts. [pass]
  /// is the last pass of the instance that rendered it.
  bool stolen = false;
  int pass = 0;

  /// Stops the sound for a polyphony limit at block frame [at] of the pass
  /// of [i].
  void steal(EventInstance i, int at) => stolen = ended = true;

  /// Renders this block. Returns false once finished.
  bool render(EventInstance i, int frames);

  /// Ends the sound when its instance finished.
  void dispose() {}

  /// Ends the sound or its cutoff when its trigger region was left.
  void untrigger() {
    if (cutoff) ended = true;
  }
}

/// A triggered sample that plays to its end, from the timeline, a parameter
/// sheet or a scatterer.
class _Voice extends _Sound {
  _Voice(
    this.reader,
    this.bus, {
    required this.rate,
    required this.gain,
    required this.loop,
    required bool cutoff,
    required Object owner,
    required this.delay,
    this.pan,
  }) : super(owner, cutoff: cutoff);
  final SourceReader reader;
  final BusStrip bus;
  final double rate, gain;
  final bool loop;

  /// The left and right gains in place of the mono upmix, from the position
  /// of a spawned sound, or null.
  final (double, double)? pan;
  int delay;
  double pos = 0;

  /// The semitones on top of [rate] in this block, from the pitch envelope
  /// of the scatterer that spawned it.
  double bend = 0;

  /// The declick of a stolen voice, the pass frame that it starts at and the
  /// frames of it that are done. The start is in this pass, or at the start
  /// of the next pass once this one rendered.
  int? fadeFrom;
  int faded = 0;

  @override
  void steal(EventInstance i, int at) {
    stolen = true;
    // The voice was stopped before it started and does not sound.
    if (delay > at || !pcmReady(reader.source)) {
      ended = true;
      return;
    }
    fadeFrom = pass == i._pass ? 0 : at;
  }

  @override
  bool render(EventInstance i, int frames) {
    if (ended) return false;
    // The data is still loading and the voice starts late from its first
    // sample.
    if (!pcmReady(reader.source)) {
      delay = math.max(0, delay - frames);
      return true;
    }
    final at = delay;
    delay = 0;
    if (at >= frames) {
      delay = at - frames;
      return true;
    }
    final r = bend == 0 ? rate : rate * libm.dpow(2, bend / 12);
    var (k, down) = _format(reader.source, bus);
    var gl = 1.0, gr = 1.0;
    // The rear pair of a quad source goes to SL and SR of a 5.1 strip.
    final rear = bus.wide && reader.source.channels >= 4 ? bus.input51 : null;
    if (pan case (final l, final r)) {
      if (bus.mono) {
        // A mono bus takes the distance gain only.
        k *= math.sqrt(l * l + r * r);
      } else {
        // Mono sources pan at constant power and stereo ones balance with
        // a factor of √2.
        final s = reader.source.channels == 1 ? 1.0 : math.sqrt2;
        k = 1;
        gl = l * s;
        gr = r * s;
      }
    }
    final from = fadeFrom;
    if (from != null) {
      // Full gain up to the fade, then 64 frames down to silence, linearly.
      final f0 = math.max(at, from);
      if (f0 > at) {
        final next = reader.addInto(
          bus.input,
          at,
          f0 - at,
          pos,
          r,
          g0: gain * k,
          g1: gain * k,
          loop: loop,
          downmix: down,
          panL: gl,
          panR: gr,
          rear: rear,
        );
        if (next == null) return false;
        pos = next;
      }
      final n = math.min(frames - f0, _declick - faded);
      final next = reader.addInto(
        bus.input,
        f0,
        n,
        pos,
        r,
        g0: gain * k * (1 - faded / _declick),
        g1: gain * k * (1 - (faded + n) / _declick),
        loop: loop,
        downmix: down,
        panL: gl,
        panR: gr,
        rear: rear,
      );
      faded += n;
      fadeFrom = 0;
      if (next == null || faded >= _declick) return false;
      pos = next;
      return true;
    }
    final next = reader.addInto(
      bus.input,
      at,
      frames - at,
      pos,
      r,
      g0: gain * k,
      g1: gain * k,
      loop: loop,
      downmix: down,
      panL: gl,
      panR: gr,
      rear: rear,
    );
    if (next == null) return false;
    pos = next;
    return true;
  }
}

/// The nested event of an event instrument, rendered into the bus of the
/// instrument. Its parameter stubs follow the automation of the instrument.
class _Nested extends _Sound {
  _Nested(
    this.event,
    this.inst,
    this.bus, {
    required Object owner,
    required bool cutoff,
    required this.delay,
  }) : super(owner, cutoff: cutoff);
  final EventInstance event;
  final InstrumentDef inst;
  final BusStrip bus;
  int delay;
  Float32List _buf = Float32List(0);

  @override
  void untrigger() {
    // An event instrument left with cutoff stops its event with a fade.
    if (cutoff) event.stop();
  }

  @override
  void steal(EventInstance i, int at) {
    stolen = true;
    event.stop(fade: false);
  }

  @override
  bool render(EventInstance i, int frames) {
    if (ended) return false;
    if (delay >= frames) {
      delay -= frames;
      return true;
    }
    final at = delay;
    delay = 0;
    for (final (index, guid, _) in inst.parameterStubs) {
      final v = i._automated(inst.property(index));
      if (v != null) event.setParameterGuid(guid, v);
    }
    final n = frames - at;
    if (_buf.length != n * 2) {
      _buf = Float32List(n * 2);
    } else {
      _buf.fillRange(0, _buf.length, 0);
    }
    if (event.outputChannels == 6) {
      // A 5.1 nested event goes in through the 5.1 rule of the strip.
      final b = Float32List(frames * 6);
      final o = Float32List(n * 6);
      event.render(o, n);
      b.setRange(at * 6, frames * 6, o);
      bus.add(b, frames, srcCh: 6);
      _sends(i, frames, at);
      return !event.isDone;
    }
    event.render(_buf, n);
    final input = bus.input;
    if (bus.mono) {
      for (var f = 0; f < n; f++) {
        final m = (_buf[f * 2] + _buf[f * 2 + 1]) * upmixGain;
        input[(at + f) * 2] += m;
        input[(at + f) * 2 + 1] += m;
      }
    } else {
      for (var f = 0; f < n * 2; f++) {
        input[at * 2 + f] += _buf[f];
      }
    }
    _sends(i, frames, at);
    return !event.isDone;
  }

  /// Adds the sends of the nested event to mixer returns into the parent's.
  void _sends(EventInstance i, int frames, int at) {
    for (final MapEntry(:key, :value) in event.sendOutputs.entries) {
      final o = i.sendOutputs.putIfAbsent(key, () => Float32List(frames * 2));
      for (var f = 0; f < value.length; f++) {
        o[at * 2 + f] += value[f];
      }
    }
  }
}

/// A mix state instrument. The mix state applies to the mixer while the
/// instrument plays, at the intensity of the instrument, with its stubs at
/// their initial values and then their automation and with its distance
/// and cone parameters from the position of the event. It stops when the
/// instrument is cut or its event ends.
class _SnapshotSound extends _Sound {
  _SnapshotSound(
    this.inst,
    this.def, {
    required Object owner,
    required bool cutoff,
    required this.delay,
  }) : super(owner, cutoff: cutoff);
  final InstrumentDef inst;
  final EventDef def;
  int delay;
  MixStateInstance? snap;

  void _end() {
    ended = true;
    snap?.stop();
  }

  @override
  void untrigger() {
    if (cutoff) _end();
  }

  @override
  void steal(EventInstance i, int at) {
    stolen = true;
    _end();
  }

  @override
  void dispose() => snap?.stop();

  @override
  bool render(EventInstance i, int frames) {
    if (ended) {
      snap?.stop();
      return false;
    }
    if (delay >= frames) {
      delay -= frames;
      return true;
    }
    delay = 0;
    var s = snap;
    if (s == null) {
      s = snap = i.player.startMixState?.call(def);
      if (s == null) return false;
      s.scale = inst.mixStateIntensity / 100;
      for (final (_, guid, initial) in inst.parameterStubs) {
        s.setParameterGuid(guid, initial);
      }
      if (i.spatial case (_, final d, final c)) s.setAuto(d, c);
    }
    for (final (index, guid, _) in inst.parameterStubs) {
      final v = i._automated(inst.property(index));
      if (v != null) s.setParameterGuid(guid, v);
    }
    return true;
  }
}

/// A scatterer. While triggered it spawns the entries of its playlist, the
/// first at once and the next after uniform random intervals in seconds.
/// At most maxSpawnPolyphony spawned sounds are live at a time, and
/// spawnCount 0 spawns without limit. Spawned sounds play on when it stops.
class _Scatter extends _Sound {
  _Scatter(this.inst, this.bus, {required Object owner, required this.delay})
    : super(owner, cutoff: false);
  final InstrumentDef inst;
  final BusStrip bus;
  final live = <_Sound>[];

  /// The frames from the start of this block to the next spawn.
  int delay;
  int spawned = 0;
  bool stopped = false;

  /// An AHDSR on its pitch, with its property and the pitch in semitones
  /// that it was played at. Then the seconds since the start and into the
  /// release, null while not releasing, the level that the release started
  /// from and the frames in scatterer time to the next spawn, null before
  /// the start.
  ModulatorDef? env;
  PropertyDef? pitchProp;
  double s0 = 0, age = 0, releaseFrom = 0;
  double? released, clock;

  /// The level of the envelope now, in percent of the UI span of the pitch.
  double get _level {
    final e = env!, r = released;
    if (r == null) return EventInstance.ahdsrLevel(e, age);
    return releaseFrom * (1 - r / e.release);
  }

  @override
  void untrigger() {
    final e = env;
    if (e != null && e.release > 0) {
      if (released == null) {
        releaseFrom = _level;
        released = 0;
      }
      return;
    }
    stopped = true;
  }

  @override
  void steal(EventInstance i, int at) => stolen = stopped = true;

  @override
  bool render(EventInstance i, int frames) {
    if (stopped) return false;
    if (env != null) return _renderEnv(i, frames);
    while (delay < frames) {
      if (inst.spawnCount > 0 && spawned >= inst.spawnCount) {
        stopped = true;
        return false;
      }
      live.removeWhere((v) => v.ended || v.stolen);
      final max = inst.maxSpawnPolyphony;
      if (max > 0 &&
          live.length >= max &&
          inst.spawnPolyphonyMode == PolyphonyMode.stealOldest) {
        // Stealing cuts the older spawn as the new one starts. The other
        // mode skips the new one.
        live.removeAt(0).steal(i, delay);
      }
      if (max <= 0 || live.length < max) {
        spawned++;
        i._spawn(this, delay);
      }
      final s = i._rng.range(inst.spawnIntervalMin, inst.spawnIntervalMax);
      delay += math.max(1, (s * timelineRate).round());
    }
    delay -= frames;
    return true;
  }

  /// Advances a scatterer with a pitch AHDSR. The level is linear in percent
  /// of the UI span of the pitch, where −50 is −24 semitones. It adds to the
  /// pitch that the scatterer played at and the sum stays within the range
  /// of the property. It moves the live spawns as they play and the spawn
  /// clock runs at that pitch. Leaving its region releases the envelope from
  /// its level to 0 over the release time while it spawns on and then the
  /// scatterer stops.
  bool _renderEnv(EventInstance i, int frames) {
    final e = env!;
    final r = released;
    if (r != null && r >= e.release) {
      stopped = true;
      return false;
    }
    final p = pitchProp!;
    final pts = p.mapping?.points ?? const <(double, double)>[];
    var st = s0 + EventInstance._uiOffset(p, _level);
    if (pts.isNotEmpty) st = st.clamp(pts.first.$2, pts.last.$2).toDouble();
    final bend = st - s0;
    final rate = libm.dpow(2, st / 12);
    if (delay >= frames && clock == null) {
      delay -= frames;
      return true;
    }
    var c = clock ?? delay * rate;
    final avail = frames * rate;
    while (c < avail) {
      if (inst.spawnCount > 0 && spawned >= inst.spawnCount) {
        stopped = true;
        return false;
      }
      final at = (c / rate).floor();
      live.removeWhere((v) => v.ended || v.stolen);
      final max = inst.maxSpawnPolyphony;
      if (max > 0 &&
          live.length >= max &&
          inst.spawnPolyphonyMode == PolyphonyMode.stealOldest) {
        live.removeAt(0).steal(i, at);
      }
      if (max <= 0 || live.length < max) {
        spawned++;
        i._spawn(this, at);
      }
      final s = i._rng.range(inst.spawnIntervalMin, inst.spawnIntervalMax);
      c += math.max(1, (s * timelineRate).round());
    }
    clock = c - avail;
    for (final v in i._voices) {
      if (v is _Voice && v.owner == this && !v.ended) v.bend = bend;
    }
    if (r == null) {
      age += frames / timelineRate;
    } else {
      released = r + frames / timelineRate;
    }
    return true;
  }
}

/// The output of an event played at a pitch ratio. The event renders ahead
/// by the ratio and each output, its bus and every send, is read back with
/// linear interpolation.
class _Pitched {
  _Pitched(this.ratio);
  final double ratio;

  /// The frames rendered and not yet consumed, by output, where '' is the
  /// bus.
  final _held = <String, Float32List>{};
  int _count = 0;
  double _pos = 0;

  void render(EventInstance e, Float32List out, int frames) {
    final need = (_pos + (frames - 1) * ratio).floor() + 2;
    if (need > _count) {
      final n = need - _count;
      final main = Float32List(n * e.outputChannels);
      e._renderRaw(main, n);
      _append('', main, n, e.outputChannels);
      for (final MapEntry(:key, :value) in e.sendOutputs.entries) {
        _append(key, value, n, 2);
      }
      for (final k in _held.keys) {
        // Outputs that this block did not reach hold silence.
        final ch = k.isEmpty ? e.outputChannels : 2;
        if (_held[k]!.length < (_count + n) * ch) _append(k, null, n, ch);
      }
      _count += n;
    }
    final sends = <String, Float32List>{};
    for (final MapEntry(:key, :value) in _held.entries) {
      final o = key.isEmpty ? out : (sends[key] = Float32List(frames * 2));
      final ch = key.isEmpty ? e.outputChannels : 2;
      var p = _pos;
      for (var f = 0; f < frames; f++) {
        final k = p.floor(), fr = p - k;
        for (var c = 0; c < ch; c++) {
          final a = value[k * ch + c], b = value[(k + 1) * ch + c];
          o[f * ch + c] += a + (b - a) * fr;
        }
        p += ratio;
      }
    }
    e.sendOutputs
      ..clear()
      ..addAll(sends);
    final end = _pos + frames * ratio;
    final drop = math.min(end.floor(), _count);
    for (final k in _held.keys) {
      final v = _held[k]!, ch = k.isEmpty ? e.outputChannels : 2;
      _held[k] = Float32List.sublistView(
        Float32List.fromList(v.sublist(drop * ch, _count * ch)),
      );
    }
    _count -= drop;
    _pos = end - drop;
  }

  void _append(String key, Float32List? data, int n, [int ch = 2]) {
    final old = _held[key] ?? Float32List(_count * ch);
    final v = Float32List(old.length + n * ch)..setAll(0, old);
    if (data != null) v.setRange(old.length, old.length + n * ch, data);
    _held[key] = v;
  }
}
