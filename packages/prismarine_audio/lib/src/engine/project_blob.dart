import 'dart:convert';
import 'dart:typed_data';

import '../events/formats.dart';
import '../mixer/dsp_reverb.dart';
import '../model/curve.dart';
import '../model/model.dart';

/// A project's model for the native mixer (mcsm_audio_out `native/mixer`,
/// src/model.rs reads it), so defaults, sort orders and lookup rules stay
/// Dart's. Strings are interned; little-endian; lists are a count then their
/// items.
///
/// [events] and [mixStates] are by path in lookup order; waveforms come once
/// per key; the mixer's buses come with their paths. An event without an
/// input bus plays into the bus [defaultBus].
Uint8List projectBlob({
  required Map<String, EventDef> events,
  required Map<String, EventDef> mixStates,
  required MixerDef mixer,
  String? defaultBus,
}) => _Writer().build(
  events,
  mixStates,
  mixer,
  defaultBus ?? mixer.masterPath ?? '',
);

class _Writer {
  final _strings = <String, int>{};
  final _body = BytesBuilder();
  final _scratch = ByteData(8);
  final _waves = <String, int>{};
  final _waveOut = BytesBuilder();

  int str(String? s) =>
      s == null ? -1 : _strings.putIfAbsent(s, () => _strings.length);

  void i32(int v, [BytesBuilder? b]) {
    _scratch.setInt32(0, v, Endian.little);
    (b ?? _body).add(_scratch.buffer.asUint8List(0, 4));
  }

  void i64(int v, [BytesBuilder? b]) {
    _scratch.setInt64(0, v, Endian.little);
    (b ?? _body).add(_scratch.buffer.asUint8List(0, 8));
  }

  void f64(double v, [BytesBuilder? b]) {
    _scratch.setFloat64(0, v, Endian.little);
    (b ?? _body).add(_scratch.buffer.asUint8List(0, 8));
  }

  void u8(bool v, [BytesBuilder? b]) => (b ?? _body).addByte(v ? 1 : 0);

  void s(String? v) => i32(str(v));

  void list<T>(List<T> items, void Function(T) f) {
    i32(items.length);
    items.forEach(f);
  }

  Uint8List build(
    Map<String, EventDef> events,
    Map<String, EventDef> mixStates,
    MixerDef mixer,
    String defaultBus,
  ) {
    s(defaultBus);
    list(Reverb.earlyTaps, (t) {
      f64(t.$1);
      f64(t.$2);
      f64(t.$3);
    });
    i32(events.length);
    for (final MapEntry(:key, :value) in events.entries) {
      s(key);
      event(value);
    }
    i32(mixStates.length);
    for (final MapEntry(:key, :value) in mixStates.entries) {
      s(key);
      event(value);
    }
    list(mixer.buses, (b) => bus(b, path: mixer.paths[b.guid]));
    final out = BytesBuilder();
    i32(0x584D434D, out);
    i32(2, out);
    i32(_strings.length, out);
    for (final k in _strings.keys) {
      final b = utf8.encode(k);
      i32(b.length, out);
      out.add(b);
    }
    i32(_waves.length, out);
    out.add(_waveOut.takeBytes());
    out.add(_body.takeBytes());
    return out.takeBytes();
  }

  int wave(WaveformDef w) {
    final known = _waves[w.key];
    if (known != null) return known;
    final o = _waveOut;
    final p = w.path;
    i32(str(p ?? ''), o);
    i32(str(w.label), o);
    u8(p != null, o);
    u8(w.streamed, o);
    u8(p != null && p.toLowerCase().endsWith('.ogg'), o);
    i64(w.frames, o);
    i64(w.rate, o);
    i64(w.channels, o);
    return _waves[w.key] = _waves.length;
  }

  void curve(Curve c) => list(c.points, (p) {
    f64(p.$1);
    f64(p.$2);
    f64(p.$3);
  });

  void prop(PropertyDef p) {
    i64(p.index);
    u8(p.isVolume);
    final m = p.mapping;
    u8(m != null);
    if (m != null) {
      list(m.points, (q) {
        f64(q.$1);
        f64(q.$2);
      });
    }
    list(p.automation, (a) {
      u8(a.onTimeline);
      s(a.parameterGuid);
      s(a.parameterName?.toLowerCase());
      curve(a.curve);
    });
    list(p.modulators, (m) {
      i32(switch (m.type) {
        'random' => 0,
        'ahdsr' => 1,
        _ => 2,
      });
      s(m.type);
      for (final v in [
        m.minimum,
        m.maximum,
        m.initial,
        m.peak,
        m.sustain,
        m.attack,
        m.hold,
        m.decay,
        m.release,
      ]) {
        f64(v);
      }
    });
  }

  void effect(EffectDef fx) {
    i32(switch (fx) {
      SendEffect() => 0,
      SidechainTap() => 1,
      DspEffect() => 2,
    });
    s(fx.guid);
    u8(fx.bypass);
    u8(fx.prefader);
    switch (fx) {
      case SendEffect(:final returnBus, :final returnPath, :final level):
        s(returnBus);
        s(returnPath);
        f64(level);
      case SidechainTap(:final targets, :final active, :final label):
        u8(!active);
        s(label);
        list(targets, s);
      case DspEffect(:final kind, :final label, :final params):
        i32(kind?.index ?? -1);
        s(label);
        list(params, (p) {
          u8(p.value != null);
          f64(p.value ?? 0);
          u8(p.isSwitch);
        });
        u8(fx.sidechainInput);
        u8(fx.passAtTop);
    }
    list(fx.properties, prop);
  }

  /// [format]: the channel format an event strip runs in (EventFormats; 0:
  /// its layout's).
  void bus(StripDef b, {String? path, int format = 0}) {
    s(b.guid);
    u8(b.master);
    s(b.output);
    s(b.outputPath);
    s(path);
    f64(b.volume);
    i64(b.layout.index);
    i64(format);
    list(b.effects, effect);
    list(b.properties, prop);
  }

  void inst(InstrumentDef d) {
    s(d.guid);
    i32(switch (d.kind) {
      'sample' => 0,
      'playlist' => 1,
      'scatterer' => 2,
      'slot' => 3,
      'event' => 4,
      _ => 5,
    });
    s(d.kind);
    f64(d.volume);
    f64(d.pitch);
    i64(d.loopCount);
    u8(d.cutoff);
    s(d.outputBus);
    list(d.properties, prop);
    final w = d.waveform;
    i32(w == null ? -1 : wave(w));
    f64(d.triggerChance);
    f64(d.triggerDelayMin);
    f64(d.triggerDelayMax);
    f64(d.offset3dDistance);
    f64(d.initialSeekPosition);
    i64(d.leftTrim);
    f64(d.mixStateIntensity);
    f64(d.spawnIntervalMin);
    f64(d.spawnIntervalMax);
    i64(d.spawnCount);
    i64(d.maxSpawnPolyphony);
    u8(d.spawnPolyphonyMode == PolyphonyMode.stealOldest);
    i64(d.maxPolyphony);
    u8(d.polyphonyMode == PolyphonyMode.stealOldest);
    u8(d.shuffle);
    final n = d.nested;
    u8(n != null);
    if (n != null) event(n);
    list(d.parameterStubs, (st) {
      i64(st.$1);
      s(st.$2);
      f64(st.$3);
    });
    list(d.entries, (e) {
      f64(e.$1);
      inst(e.$2);
    });
  }

  void event(EventDef d) {
    s(d.guid);
    s(d.path);
    u8(d.isMixState);
    u8(d.oneShot);
    i64(d.maxPolyphony);
    u8(d.polyphonyMode == PolyphonyMode.stealOldest);
    final ib = d.inputBus;
    final f = d.stripFormats;
    u8(ib != null);
    if (ib != null) bus(ib, format: f[ib.guid] ?? 0);
    bus(d.masterTrack, format: f[d.masterTrack.guid] ?? 0);
    list(d.tracks, (b) => bus(b, format: f[b.guid] ?? 0));
    list(d.returns, (b) => bus(b, format: f[b.guid] ?? 0));
    list(d.parameters, (p) {
      s(p.guid);
      s(p.name.toLowerCase());
      f64(p.minimum);
      f64(p.maximum);
      f64(p.defaultValue);
      i32(p.kind.index);
      list(p.instruments, (sp) {
        f64(sp.start);
        f64(sp.length);
        inst(sp.instrument);
      });
    });
    final tl = d.timeline;
    list(tl.placements, (p) {
      i64(p.start);
      i64(p.length);
      u8(p.timelocked);
      u8(p.fill);
      inst(p.instrument);
    });
    i64(tl.length);
    list(tl.tempo, (t) {
      i64(t.position);
      f64(t.tempo);
      i64(t.beatsPerBar);
      i64(t.beatUnit);
    });
    list(tl.transitions, (t) {
      u8(t.isLoop);
      u8(t.isMarker);
      i64(t.start);
      i64(t.end);
      i64(t.destination);
      s(t.conditionParameter);
      f64(t.conditionMin);
      f64(t.conditionMax);
      i64(t.unit);
      i64(t.multiplier);
    });
    // MixStateInstance's view (empty for events).
    final ms = d.mixState ?? MixStateDef();
    i64(ms.priority);
    f64(ms.intensity);
    list(ms.entries, (e) {
      s(e.target);
      i64(e.property);
      f64(e.value);
      final auto = e.automation;
      u8(auto != null);
      if (auto != null) prop(auto);
    });
    final intensity = ms.intensityProperty;
    u8(intensity != null);
    if (intensity != null) prop(intensity);
    final byName = <String, int>{};
    for (final (i, p) in d.parameters.indexed) {
      byName[p.name.toLowerCase()] = i;
    }
    list(byName.entries.toList(), (e) {
      s(e.key);
      i32(e.value);
    });
  }
}
