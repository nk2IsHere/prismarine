import 'dart:typed_data';
import 'package:prismarine_math/libm.dart' as libm;

/// The mixer rate.
const mixRate = 48000;

/// An FMOD built-in DSP, rebuilt from the FMOD oracle's measurements of the
/// game's FMOD 1.06.02 (see formats/telltale/fmod-runtime.md, "Built-in DSPs").
/// Parameters use FMOD's indices; buffers are stereo, interleaved, processed in
/// place.
abstract class Dsp {
  Dsp(List<double> defaults) : params = [...defaults];

  final List<double> params;

  void set(int index, double value) {
    if (index < 0 || index >= params.length) return;
    if (params[index] == value) return;
    params[index] = value;
    changed(index);
  }

  double get(int index) => params[index];

  /// A parameter changed: recompute coefficients.
  void changed(int index) {}

  /// The stored parameters are set: a DSP that glides to new parameters
  /// starts at these instead.
  void start() {}

  /// [frames] of silence went by unprocessed (a skipped strip): advance
  /// envelopes and phases as silence would.
  void idle(int frames) {}

  /// Sound still held inside (a delay line) that silence in would bring
  /// out: the strip must keep processing.
  bool get ringing => false;

  /// Processes [frames] frames of [buf]. [mono]: the signal is mono, held
  /// dual-mono (L = R). Returns whether the output is still mono.
  bool process(Float32List buf, int frames, {bool mono = false});

  /// Processes [frames] frames of a 5.1 buffer (six channels interleaved:
  /// FL FR C LFE SL SR), as on an S2 bus whose input format is 5.1; false
  /// when the DSP has no 5.1 form (the strip passes the signal on and
  /// reports it).
  bool process51(Float32List buf, int frames) => false;

  /// The twins that run a per-channel DSP's other two channel pairs of a
  /// 5.1 buffer (C/LFE and SL/SR), each with its own state.
  List<Dsp>? _twins;
  Float32List _pair = Float32List(0);

  /// 5.1 as three stereo pairs through this DSP and two twins [make] builds,
  /// for DSPs that treat every channel alike and on its own (FMOD's
  /// filters, echo and distortion run per channel [O: c51_echo, c51_eq3,
  /// mb51]).
  bool processPairs51(Float32List buf, int frames, Dsp Function() make) {
    final twins = _twins ??= [make()..start(), make()..start()];
    if (_pair.length < frames * 2) _pair = Float32List(frames * 2);
    for (var k = 0; k < 3; k++) {
      final d = k == 0 ? this : twins[k - 1];
      for (var i = 0; d != this && i < params.length; i++) {
        d.set(i, params[i]);
      }
      for (var i = 0; i < frames; i++) {
        _pair[i * 2] = buf[i * 6 + k * 2];
        _pair[i * 2 + 1] = buf[i * 6 + k * 2 + 1];
      }
      d.process(_pair, frames);
      for (var i = 0; i < frames; i++) {
        buf[i * 6 + k * 2] = _pair[i * 2];
        buf[i * 6 + k * 2 + 1] = _pair[i * 2 + 1];
      }
    }
    return true;
  }
}

/// dB → amplitude; −80 dB and below is silence.
double dbGain(double db) => db <= -80 ? 0 : libm.dpow(10, db / 20);

/// A one-pole smoothing coefficient for time constant [ms].
double onePole(double ms) =>
    ms <= 0 ? 1 : 1 - libm.exp(-1 / (ms * 1e-3 * mixRate));
