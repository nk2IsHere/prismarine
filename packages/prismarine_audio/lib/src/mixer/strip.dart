import 'dart:math' as math;
import 'dart:typed_data';

import '../model/model.dart';
import 'dsp.dart';
import 'dsp_dynamics.dart';
import 'dsp_effects.dart';
import 'dsp_eq.dart';
import 'dsp_filters.dart';
import 'dsp_mix.dart';
import 'dsp_reverb.dart';
import 'surround.dart';

part 'strip51.dart';

/// A property's current value on a mixer object (a bus's volume, a send's
/// level, an effect's parameter 1000 + n), or null for its stored value.
typedef PropertyValue = double? Function(String owner, int index);

/// Where a strip's sends and sidechain taps deliver this block.
abstract class StripSink {
  /// [buf] (stereo; [mono] when dual-mono; 5.1 when [channels] is 6) × the
  /// send level, into the return bus [returnBus] (its path, when known, is
  /// [returnPath]).
  void send(
    String returnBus,
    String? returnPath,
    Float32List buf,
    bool mono, {
    int channels = 2,
  });

  /// A sidechain tap feeding the compressors [targets] (effect GUIDs).
  void sidechain(List<String> targets, Float32List buf);
}

/// FMOD's default mono → stereo upmix (and the matching downmix) per side
/// (O on a low-level channel; INFERRED for bus connections).
const upmixGain = math.sqrt1_2;

/// A bus: input sum, effect chain (pre-fader effects, the fader, post-fader
/// effects; sends and sidechain taps where they sit), output. Buffers are
/// stereo; a mono bus (inputChannelLayout 2) holds its signal dual-mono.
///
/// S2's 5.1 buses (inputChannelLayout 6) and strips after a surround PAN
/// run in 5.1 instead (strip51.dart); S1 has neither.
class BusStrip {
  /// [format] (1 mono, 2 stereo, 6 5.1) overrides the bus's layout: an S2
  /// event strip runs in its sources' widest format (EventInstance).
  BusStrip(this.def, {void Function(String)? problem, int? format})
    : mono = format == null ? def.layout == ChannelLayout.mono : format == 1,
      _wide = format == null
          ? def.layout == ChannelLayout.surround51
          : format == 6,
      _problem = problem {
    final pre = <_Stage>[], post = <_Stage>[];
    for (final fx in def.effects) {
      if (fx.bypass) continue;
      final stage = _stage(fx, problem);
      if (stage == null) continue;
      (fx.prefader ? pre : post).add(stage);
    }
    _stages = [...pre, _Fader(), ...post];
    _surround = _stages.indexWhere(
      (s) => s is _Effect && s.dsp is Pan && (s.dsp as Pan).surround,
    );
  }

  final StripDef def;

  /// The bus's input format is mono.
  final bool mono;
  late final List<_Stage> _stages;
  Float32List input = Float32List(0), output = Float32List(0);

  /// The 5.1 input sum (5.1 sources and buses), beside the stereo [input]
  /// sources write into, on a strip that runs in 5.1.
  Float32List input51 = Float32List(0);

  /// The strip runs in 5.1: a 5.1 bus, or an S2 event strip whose format
  /// is 5.1 (EventFormats).
  final bool _wide;
  int _surround = -1;
  final void Function(String)? _problem;

  /// The output's channels: 6 on a strip that runs in 5.1 or ends in 5.1
  /// after a surround PAN, else 2.
  int get outputChannels => _wide || _surround >= 0 ? 6 : 2;

  /// It mixes its input in 5.1 ([input51]).
  bool get wide => _wide;

  /// The block's output is mono (dual-mono).
  bool outputMono = false;
  double? _gain;

  /// A gain ramp the owner applies at the fader this block, on top of the
  /// bus volume: an event's master track takes the EventInstance volume
  /// there, so post-fader sends and effects follow it and pre-fader ones
  /// don't [O: FMOD 1.06, `SFX_Waterfall`'s post-fader reverb send at
  /// instance volume 0.04 renders 28.0 dB below volume 1 in total;
  /// `SFX_batSquak_Multi`'s pre-fader send keeps its level].
  double faderFrom = 1, faderTo = 1;

  String get guid => def.guid;

  /// The DSP of effect [guid] here, or null.
  Dsp? effect(String guid) {
    for (final s in _stages) {
      if (s case _Effect(guid: final g, :final dsp) when g == guid) return dsp;
    }
    return null;
  }

  /// The PAN DSPs here (they take the event's 3D position).
  Iterable<Pan> get pans sync* {
    for (final s in _stages) {
      if (s case _Effect(:final Pan dsp)) yield dsp;
    }
  }

  /// Compressors here, by effect GUID (sidechain targets).
  Iterable<(String, Compressor)> get compressors sync* {
    for (final s in _stages) {
      if (s case _Effect(:final guid, :final Compressor dsp)) yield (guid, dsp);
    }
  }

  void begin(int frames) {
    if (input.length != frames * 2) {
      input = Float32List(frames * 2);
      output = Float32List(frames * outputChannels);
    } else {
      input.fillRange(0, input.length, 0);
    }
    if (_wide) _begin51(frames);
  }

  /// Adds [buf] (stereo; dual-mono when [srcMono]; 5.1 when [srcCh] is 6)
  /// into the input, with the format rule: mono into stereo upmixes, stereo
  /// into mono downmixes, 5.1 into stereo downmixes as FMOD's output does
  /// [I: for a strip].
  void add(Float32List buf, int frames, {bool srcMono = false, int srcCh = 2}) {
    if (srcCh == 6) {
      _add51(buf, frames);
      return;
    }
    if (srcMono == mono) {
      for (var i = 0; i < frames * 2; i++) {
        input[i] += buf[i];
      }
    } else if (srcMono) {
      for (var i = 0; i < frames * 2; i++) {
        input[i] += buf[i] * upmixGain;
      }
    } else {
      for (var i = 0; i < frames; i++) {
        final m = (buf[i * 2] + buf[i * 2 + 1]) * upmixGain;
        input[i * 2] += m;
        input[i * 2 + 1] += m;
      }
    }
  }

  double _lastPeak = 0;

  /// The peak of the last block's final 64 frames.
  double _endPeak = 0;

  /// Nothing sounds here at the end of the last block or is held inside
  /// (effect tails have died away).
  bool get quiet => _endPeak < 1e-7 && !_keyed;

  /// A compressor here has a sidechain key this block (it must track it).
  bool get _keyed {
    for (final (_, c) in compressors) {
      if (c.useSidechain && c.sidechain != null) return true;
    }
    for (final s in _stages) {
      if (s case _Effect(:final dsp) when dsp.ringing) return true;
    }
    return false;
  }

  /// Runs the chain over this block's input into [output]. A silent input
  /// whose last output had died away (< 1e-7, so tails finish) skips it.
  void process(int frames, PropertyValue prop, StripSink sink) {
    if (outputChannels == 6) {
      _process51(frames, prop, sink);
      return;
    }
    var inPeak = 0.0;
    for (var i = 0; i < frames * 2; i++) {
      final a = input[i].abs();
      if (a > inPeak) inPeak = a;
    }
    if (inPeak == 0 && _lastPeak < 1e-7 && !_keyed) {
      for (final st in _stages) {
        switch (st) {
          // The fader keeps following its target while skipped, so a change
          // made in silence holds when sound resumes (no stale ramp).
          case _Fader():
            _gain = dbGain(prop(guid, 0) ?? def.volume);
          case _Effect(:final dsp):
            dsp.idle(frames);
          case _Send() || _Tap():
        }
      }
      output.fillRange(0, frames * 2, 0);
      outputMono = mono;
      _endPeak = 0;
      return;
    }
    output.setRange(0, frames * 2, input);
    var m = mono;
    for (final s in _stages) {
      switch (s) {
        case _Fader():
          final g = dbGain(prop(guid, 0) ?? def.volume);
          final g0 = _gain ?? g;
          _gain = g;
          final e0 = faderFrom, e1 = faderTo;
          for (var i = 0; i < frames; i++) {
            final k =
                (g0 + (g - g0) * (i / frames)) *
                (e0 + (e1 - e0) * (i / frames));
            output[i * 2] *= k;
            output[i * 2 + 1] *= k;
          }
        case _Effect(:final guid, :final dsp):
          for (var i = 0; i < dsp.params.length; i++) {
            if (prop(guid, 1000 + i) case final v?) dsp.set(i, v);
          }
          m = dsp.process(output, frames, mono: m);
        case _Send(
          :final guid,
          :final returnBus,
          :final returnPath,
          :final level,
        ):
          final g = dbGain(prop(guid, 0) ?? level);
          if (g == 0) break;
          final b = Float32List(frames * 2);
          for (var i = 0; i < frames * 2; i++) {
            b[i] = output[i] * g;
          }
          sink.send(returnBus, returnPath, b, m);
        case _Tap(:final targets):
          sink.sidechain(
            targets,
            Float32List.fromList(output.sublist(0, frames * 2)),
          );
      }
    }
    outputMono = m;
    var outPeak = 0.0, endPeak = 0.0;
    final end = math.max(0, frames - 64) * 2;
    for (var i = 0; i < frames * 2; i++) {
      final a = output[i].abs();
      if (a > outPeak) outPeak = a;
      if (i >= end && a > endPeak) endPeak = a;
    }
    _lastPeak = outPeak;
    _endPeak = endPeak;
  }

  static _Stage? _stage(EffectDef fx, void Function(String)? problem) {
    switch (fx) {
      case SendEffect(:final guid, :final returnBus, :final returnPath):
        return _Send(guid, returnBus, returnPath, fx.level);
      case SidechainTap(:final targets, :final active):
        if (!active) return null;
        return _Tap([...targets], fx.label);
      case DspEffect(:final guid, :final label):
        final dsp = createDsp(fx);
        if (dsp == null) {
          problem?.call('unsupported effect $label');
          return null;
        }
        return _Effect(guid, dsp, label);
    }
  }
}

/// A DSP for an effect record, with its stored parameters applied.
Dsp? createDsp(DspEffect fx) {
  final Dsp? dsp = switch (fx.kind) {
    EffectKind.lowpass => Lowpass(keep22k: !fx.passAtTop),
    EffectKind.highpass => Highpass(),
    EffectKind.echo => Echo(),
    EffectKind.flange => Flange(),
    EffectKind.chorus => Chorus(),
    EffectKind.distortion => Distortion(),
    EffectKind.parametricEq => ParamEq(),
    EffectKind.limiter => Limiter(),
    EffectKind.compressor => Compressor(),
    EffectKind.reverb => Reverb(),
    EffectKind.tremolo => Tremolo(),
    EffectKind.pan => Pan(),
    EffectKind.threeBandEq => ThreeEq(),
    EffectKind.channelMix => ChannelMix(),
    EffectKind.objectPan => ObjectPan(),
    EffectKind.multibandEq => MultibandEq(),
    null => null,
  };
  if (dsp == null) return null;
  for (final (i, p) in fx.params.indexed) {
    if (p.value case final v?) dsp.set(i, v);
  }
  if (dsp is Compressor) dsp.useSidechain = fx.sidechainInput;
  dsp.start();
  return dsp;
}

sealed class _Stage {}

class _Fader extends _Stage {}

class _Effect extends _Stage {
  _Effect(this.guid, this.dsp, this.label);
  final String guid;
  final Dsp dsp;

  /// Its DSP type or plugin, for problems.
  final String label;
}

class _Send extends _Stage {
  _Send(this.guid, this.returnBus, this.returnPath, this.level);
  final String guid, returnBus;
  final String? returnPath;
  final double level;
}

class _Tap extends _Stage {
  _Tap(this.targets, this.label);
  final List<String> targets;
  final String label;
}
