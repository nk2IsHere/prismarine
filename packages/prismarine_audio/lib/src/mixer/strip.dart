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

/// Returns the value of a property of a mixer object now, or null for its
/// stored value. The property is the volume of a bus, the level of a send
/// or effect parameter n as 1000 + n.
typedef PropertyValue = double? Function(String owner, int index);

/// The receiver of the sends and sidechain taps of a strip in a block.
abstract class StripSink {
  /// Adds [buf] times the send level into the return bus [returnBus], with
  /// the path [returnPath] when it is known. [buf] is stereo, mono with
  /// equal channels when [mono], or 5.1 when [channels] is 6.
  void send(
    String returnBus,
    String? returnPath,
    Float32List buf,
    bool mono, {
    int channels = 2,
  });

  /// Feeds [buf] into the sidechain input of the compressors [targets],
  /// given by effect id.
  void sidechain(List<String> targets, Float32List buf);
}

/// The gain per side of the upmix from mono to stereo and of the matching
/// downmix.
const upmixGain = math.sqrt1_2;

/// A bus with its input sum, its effect chain and its output. The chain has
/// the pre-fader effects, the fader and the post-fader effects, with sends
/// and sidechain taps at their places. Buffers are stereo, and a mono bus
/// holds its signal with equal channels. A 5.1 bus and the part of a strip
/// after a surround pan run in 5.1.
class BusStrip {
  /// [format], 1 for mono, 2 for stereo and 6 for 5.1, overrides the layout
  /// of the bus. An event strip runs in the widest format of its sources.
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

  /// The input format of the bus is mono.
  final bool mono;
  late final List<_Stage> _stages;
  Float32List input = Float32List(0), output = Float32List(0);

  /// The 5.1 input sum of a strip that runs in 5.1, beside the stereo
  /// [input].
  Float32List input51 = Float32List(0);

  /// The strip runs in 5.1, as a 5.1 bus or an event strip of format 5.1.
  final bool _wide;
  int _surround = -1;
  final void Function(String)? _problem;

  /// The channels of the output, 6 on a strip that runs in 5.1 or ends in
  /// 5.1 after a surround pan, else 2.
  int get outputChannels => _wide || _surround >= 0 ? 6 : 2;

  /// The strip mixes its input in 5.1, in [input51].
  bool get wide => _wide;

  /// The output of the block is mono, with equal channels.
  bool outputMono = false;
  double? _gain;

  /// A gain ramp that the owner applies at the fader in this block, on top
  /// of the bus volume. The master track of an event takes the instance
  /// volume here. Post-fader sends and effects follow it and pre-fader ones
  /// do not.
  double faderFrom = 1, faderTo = 1;

  String get guid => def.guid;

  /// Returns the DSP of effect [guid] on this strip, or null.
  Dsp? effect(String guid) {
    for (final s in _stages) {
      if (s case _Effect(guid: final g, :final dsp) when g == guid) return dsp;
    }
    return null;
  }

  /// The pan DSPs of the strip, which take the position of the event.
  Iterable<Pan> get pans sync* {
    for (final s in _stages) {
      if (s case _Effect(:final Pan dsp)) yield dsp;
    }
  }

  /// The compressors of the strip with their effect ids, the targets of
  /// sidechain taps.
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

  /// Adds [buf] into the input. [buf] is stereo, mono with equal channels
  /// when [srcMono], or 5.1 when [srcCh] is 6. Mono into stereo upmixes,
  /// stereo into mono downmixes and 5.1 into stereo folds down.
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

  /// The peak of the final 64 frames of the last block.
  double _endPeak = 0;

  /// Nothing sounds at the end of the last block and no effect holds a
  /// tail.
  bool get quiet => _endPeak < 1e-7 && !_keyed;

  /// A compressor of the strip has a sidechain key in this block and must
  /// track it.
  bool get _keyed {
    for (final (_, c) in compressors) {
      if (c.useSidechain && c.sidechain != null) return true;
    }
    for (final s in _stages) {
      if (s case _Effect(:final dsp) when dsp.ringing) return true;
    }
    return false;
  }

  /// Runs the chain over the input of the block into [output]. The chain
  /// is skipped for a silent input after an output under 1e-7, which lets
  /// tails finish first.
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
          // The fader follows its target while skipped. A change made in
          // silence holds when sound resumes, without a stale ramp.
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

/// Returns a DSP for [fx] with its stored parameters, or null for a kind
/// that the engine does not have.
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

  /// The label of the effect in problems.
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
