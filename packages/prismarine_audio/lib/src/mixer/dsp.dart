import 'dart:typed_data';
import 'package:prismarine_math/libm.dart' as libm;

/// The rate of the mix in frames per second.
const mixRate = 48000;

/// An effect DSP. Its parameters have the order of its [EffectKind]. It
/// processes interleaved stereo buffers in place.
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

  /// Recomputes the coefficients after parameter [index] changed.
  void changed(int index) {}

  /// Takes the parameters set so far as its start values. A DSP that glides
  /// to new parameters starts at these.
  void start() {}

  /// Advances envelopes and phases over [frames] frames of silence that a
  /// skipped strip did not process.
  void idle(int frames) {}

  /// The DSP holds sound, as in a delay line, that silence at its input
  /// would bring out. The strip keeps processing it.
  bool get ringing => false;

  /// Processes [frames] frames of [buf]. With [mono] the signal is mono,
  /// held with equal channels. Returns whether the output is still mono.
  bool process(Float32List buf, int frames, {bool mono = false});

  /// Processes [frames] frames of a 5.1 buffer, six channels interleaved in
  /// the order FL FR C LFE SL SR. Returns false when the DSP has no 5.1
  /// form. The strip then passes the signal on and reports a problem.
  bool process51(Float32List buf, int frames) => false;

  /// The twins that run the other two channel pairs of a 5.1 buffer, C with
  /// LFE and SL with SR, each with its own state.
  List<Dsp>? _twins;
  Float32List _pair = Float32List(0);

  /// Processes a 5.1 buffer as three stereo pairs through this DSP and two
  /// twins that [make] builds. It suits DSPs that treat every channel alike
  /// and on its own, such as the filters, the echo and the distortion.
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

/// Converts dB to an amplitude. −80 dB and less is silence.
double dbGain(double db) => db <= -80 ? 0 : libm.dpow(10, db / 20);

/// Returns the one-pole smoothing coefficient of the time constant [ms].
double onePole(double ms) =>
    ms <= 0 ? 1 : 1 - libm.exp(-1 / (ms * 1e-3 * mixRate));
