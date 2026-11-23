import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'biquad.dart';
import 'dsp.dart';
import 'spatial.dart';
import 'surround.dart';

/// The lowpass, with the cutoff in Hz (0) and the resonance (1). It is a
/// 4th-order Butterworth of two RBJ biquads, each with Q times the
/// resonance. Without [keep22k] it passes its input unchanged at a cutoff of
/// 22000 Hz or more and a resonance of 1 or less.
class Lowpass extends Dsp {
  Lowpass({this.keep22k = false}) : super([5000, 1]) {
    _update();
  }

  /// The filter runs at 22000 Hz too.
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

/// The three-band EQ, with the low, mid and high gains in dB (0 to 2), the
/// low and high crossovers in Hz (3, 4) and the slope (5), where 1 is
/// 24 dB per octave. The bands are Linkwitz-Riley crossovers in parallel.
/// The low band is an LR4 low-pass at f1, the mid band an LR4 high-pass at
/// f1 and a low-pass at f2, the high band an LR4 high-pass at f2.
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

/// The panner. In 2D it takes the stereo position from −100 to 100 (1). A
/// mono input pans at constant power, L = cos θ and R = sin θ. A stereo
/// input is balanced per channel by √2·cos θ and √2·sin θ, without a cross
/// feed. In surround mode (0 is 2) with a 3D pan blend (17) above 0, the
/// source at [azimuth] and [distance] relative to the listener is panned
/// and attenuated by [Spatial]. A blend below 1 mixes in the 2D pan. The
/// output is stereo.
class Pan extends Dsp {
  Pan()
    : super([
        1, 0, 0, 360, 0, 0, 1, 60, 0, 255, 0, 0, 1, 20, 0, 0, 0, 0, 0, 0, 3, //
      ]);

  /// The direction of the source in degrees, 0 ahead and +90 to the right,
  /// and its distance.
  double azimuth = 0, distance = 0;
  final _g = Float64List(4);

  /// Surround mode with a 5.1 target, the output speaker parameter (20) at
  /// 6. The output is 5.1, from [toSurround].
  bool get surround => params[0].round() == 2 && params[20].round() == 6;

  final _l = Float64List(6), _r = Float64List(6);

  /// Pans [frames] frames of [src], stereo or mono with equal channels,
  /// onto 5.1 into the six channels of [dst] with [Surround]. A mono source
  /// pans by direction (2) and extent (3). A stereo one pans by its stereo
  /// mode (6), 0 distributed with the rotation (4) and 1 discrete at the axis
  /// (8) plus and minus half the separation (7). The LFE level (5) applies to
  /// a source without an LFE only with the LFE upmix (18) on. With a 3D pan
  /// blend (17) the direction of the event and the extent and attenuation
  /// of its distance pan a share of it.
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

  /// A 5.1 input passes unchanged.
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
