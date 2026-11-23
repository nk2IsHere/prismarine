import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'biquad.dart';
import 'dsp.dart';
import 'spatial.dart';
import 'surround.dart';

/// FMOD_DSP_TYPE_LOWPASS (3): cutoff Hz (0), resonance (1). A 4th-order
/// Butterworth: two RBJ biquads, each Q × resonance (O: exact to 16-bit).
///
/// FMOD 1.06 bypasses it at a cut-off of 22000 Hz (O); 1.09 doesn't, so an
/// S2 event's "LowPass CutOff" at its default still filters [O: FMOD 1.09,
/// 22000 Hz renders as the two biquads to 1e-6; ([keep22k])].
class Lowpass extends Dsp {
  Lowpass({this.keep22k = false}) : super([5000, 1]) {
    _update();
  }

  /// FMOD 1.09's: no bypass at 22000 Hz.
  final bool keep22k;
  final _s = [Biquad(), Biquad()];

  @override
  void changed(int index) => _update();

  void _update() {
    for (var k = 0; k < 2; k++) {
      _s[k].lowpass(params[0], butterworth4[k] * params[1]);
    }
  }

  @override
  bool process51(Float32List buf, int frames) =>
      processPairs51(buf, frames, () => Lowpass(keep22k: keep22k));

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    if (params[0] >= 22000 && params[1] <= 1 && !keep22k) return mono;
    for (var i = 0; i < frames; i++) {
      for (var ch = 0; ch < 2; ch++) {
        buf[i * 2 + ch] = _s[1].tick(ch, _s[0].tick(ch, buf[i * 2 + ch]));
      }
    }
    return mono;
  }
}

/// FMOD_DSP_TYPE_THREE_EQ (28): low/mid/high gain dB (0–2), low and high
/// crossovers Hz (3, 4), slope (5: 1 = 24 dB/oct). Linkwitz-Riley crossovers
/// in parallel: low = LR4 low-pass at f1, mid = LR4 high-pass f1 then
/// low-pass f2, high = LR4 high-pass at f2 (O: exact to 16-bit).
class ThreeEq extends Dsp {
  ThreeEq() : super([0, 0, 0, 400, 4000, 1]) {
    _update();
  }
  final _low = [Biquad(), Biquad()];
  final _mid = [Biquad(), Biquad(), Biquad(), Biquad()];
  final _high = [Biquad(), Biquad()];
  static final _q = 1 / math.sqrt2;

  @override
  void changed(int index) => _update();

  void _update() {
    for (final b in _low) {
      b.lowpass(params[3], _q);
    }
    _mid[0].highpass(params[3], _q);
    _mid[1].highpass(params[3], _q);
    _mid[2].lowpass(params[4], _q);
    _mid[3].lowpass(params[4], _q);
    for (final b in _high) {
      b.highpass(params[4], _q);
    }
  }

  @override
  bool process51(Float32List buf, int frames) =>
      processPairs51(buf, frames, ThreeEq.new);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final gl = dbGain(params[0]),
        gm = dbGain(params[1]),
        gh = dbGain(params[2]);
    for (var i = 0; i < frames; i++) {
      for (var ch = 0; ch < 2; ch++) {
        final x = buf[i * 2 + ch];
        final lo = _low[1].tick(ch, _low[0].tick(ch, x));
        var m = x;
        for (final b in _mid) {
          m = b.tick(ch, m);
        }
        final hi = _high[1].tick(ch, _high[0].tick(ch, x));
        buf[i * 2 + ch] = gl * lo + gm * m + gh * hi;
      }
    }
    return mono;
  }
}

/// FMOD_DSP_TYPE_PAN (27). 2D: stereo position −100..100 (1). A mono input
/// pans at constant power (L = cos θ, R = sin θ); a stereo input is balanced
/// per channel by √2·cos θ and √2·sin θ, with no cross-feed (O). In surround
/// mode (0 = 2) with a 3D pan blend (17) above 0, the source at [azimuth]
/// and [distance] (the event's position relative to the listener, set by
/// the event's 3D attributes) is panned and attenuated as FMOD 1.06 does
/// ([Spatial]); a blend below 1 mixes in the 2D pan [I: S1 uses 0 or 1].
/// The output is stereo.
class Pan extends Dsp {
  Pan()
    : super([
        1, 0, 0, 360, 0, 0, 1, 60, 0, 255, 0, 0, 1, 20, 0, 0, 0, 0, 0, 0, 3, //
      ]);

  /// The source's direction (degrees, 0 ahead, +90 right) and distance.
  double azimuth = 0, distance = 0;
  final _g = Float64List(4);

  /// Surround mode with a 5.1 target ("Output Speaker" 6, as S2's events
  /// set it): the output is 5.1 ([toSurround]).
  bool get surround => params[0].round() == 2 && params[20].round() == 6;

  final _l = Float64List(6), _r = Float64List(6);

  /// [frames] of [src] (stereo, or mono held dual-mono) panned onto 5.1
  /// into [dst] (six channels) by FMOD 1.09's surround panner ([Surround]):
  /// a mono source by direction (2) and extent (3), a stereo one by its
  /// stereo mode (6: 0 distributed with rotation 4, 1 discrete at axis 8 ∓
  /// separation 7 / 2). The LFE level (5) applies to a source without an
  /// LFE only with the LFE upmix (18) on [traced: formats/telltale/fmod-runtime.md "FMOD 1.09 (S2)"]. With a 3D pan
  /// blend (17) the event's direction and the distance's extent and
  /// attenuation pan a share of it [I: S2 has one such panner].
  void toSurround(Float32List src, bool mono, Float32List dst, int frames) {
    final l = _l..fillRange(0, 6, 0), r = _r..fillRange(0, 6, 0);
    final lfe = params[18] >= 0.5 ? dbGain(params[5]) : 0.0;
    final blend = params[17].clamp(0.0, 1.0).toDouble();
    void pan(double dir, double extent, double gain) {
      if (gain <= 0) return;
      if (mono) {
        Surround.mono(dir, extent, gain, lfe, l);
      } else if (params[6].round() == 1 && blend < 1) {
        Surround.stereoDiscrete(params[8], params[7], gain, lfe, l, r);
      } else {
        Surround.stereoDistributed(dir, extent, params[4], gain, lfe, l, r);
      }
    }

    pan(params[2], params[3], 1 - blend);
    if (blend > 0) {
      final att = Spatial.attenuation(
        params[11].round(),
        distance,
        params[12],
        params[13],
      );
      final e = Spatial.extent(
        params[14].round(),
        distance,
        params[12],
        params[15],
        params[16],
      );
      pan(azimuth, e, att * blend);
    }
    for (var i = 0; i < frames; i++) {
      final x = src[i * 2], y = mono ? 0.0 : src[i * 2 + 1];
      for (var c = 0; c < 6; c++) {
        dst[i * 6 + c] = l[c] * x + r[c] * y;
      }
    }
  }

  /// A 5.1 input (an S2 bus's panner, at its defaults) passes unchanged
  /// [O: c51_pan_bus].
  @override
  bool process51(Float32List buf, int frames) => true;

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final th = (params[1].clamp(-100, 100) + 100) / 200 * math.pi / 2;
    final k = mono ? 1.0 : math.sqrt2;
    final l = k * libm.cos(th), r = k * libm.sin(th);
    final blend = params[17];
    if (params[0] != 2 || blend <= 0) {
      for (var i = 0; i < frames; i++) {
        buf[i * 2] *= l;
        buf[i * 2 + 1] *= r;
      }
      return false;
    }
    final g = _g;
    Spatial.gains(params, azimuth, distance, mono, g);
    final b = blend > 1 ? 1.0 : blend, d2 = 1 - b;
    final ll = g[0] * b + d2 * l, rr = g[3] * b + d2 * r;
    final rl = g[1] * b, lr = g[2] * b;
    if (mono) {
      final mr = lr + d2 * r;
      for (var i = 0; i < frames; i++) {
        buf[i * 2] *= ll;
        buf[i * 2 + 1] *= mr;
      }
      return false;
    }
    for (var i = 0; i < frames; i++) {
      final x = buf[i * 2], y = buf[i * 2 + 1];
      buf[i * 2] = x * ll + y * rl;
      buf[i * 2 + 1] = x * lr + y * rr;
    }
    return false;
  }
}
