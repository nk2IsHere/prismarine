import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'dsp.dart';

/// The compressor, with the threshold in dB (0), the ratio (1), the attack
/// and release in ms (2, 3), the make-up gain in dB (4), the sidechain
/// switch (5) and the link switch (6, on by default). Unlinked, each channel
/// is detected and compressed on its own.
///
/// The detector is the summed power Σx² of the channels, where stereo with
/// L = R reads +3 dB over one channel, followed by a one-pole follower. The
/// gain reduction above the threshold is
/// (1 − 1/ratio)·(10·log10(env) − threshold). The follower's time constants
/// are half the attack and release, and the gain is smoothed over 2 ms.
class Compressor extends Dsp {
  Compressor() : super([0, 2.5, 20, 100, 0, 0, 1]);

  bool useSidechain = false;

  /// The stereo sidechain input of the next [process], or null for none.
  /// The input keys itself when the sidechain is off.
  Float32List? sidechain;

  double _env = 0, _gr = 0;

  /// The follower and reduction of each channel when unlinked.
  final _envs = Float64List(6), _grs = Float64List(6);
  static final _smooth = onePole(2);

  @override
  void idle(int frames) {
    if (useSidechain && sidechain != null) return;
    _env *= libm.dpow(1 - onePole(params[3] / 2), frames.toDouble());
    _gr *= libm.dpow(1 - _smooth, frames.toDouble());
    sidechain = null;
  }

  @override
  bool process51(Float32List buf, int frames) {
    if (params[6] < 0.5) {
      _unlinked(buf, frames, 6);
      return true;
    }
    final aa = onePole(params[2] / 2), ar = onePole(params[3] / 2);
    final s = 1 - 1 / math.max(1, params[1]);
    final thr = params[0], makeup = params[4];
    for (var i = 0; i < frames; i++) {
      // The detector sums the power of every channel, and one gain applies
      // to all six.
      var e = 0.0;
      for (var c = 0; c < 6; c++) {
        final x = buf[i * 6 + c];
        e += x * x;
      }
      _env += (e - _env) * (e > _env ? aa : ar);
      final lvl = 10 * libm.log(_env + 1e-30) / math.ln10;
      final gr = lvl > thr ? s * (lvl - thr) : 0.0;
      _gr += (gr - _gr) * _smooth;
      final g = libm.dpow(10, (makeup - _gr) / 20);
      for (var c = 0; c < 6; c++) {
        buf[i * 6 + c] *= g;
      }
    }
    sidechain = null;
    return true;
  }

  void _unlinked(Float32List buf, int frames, int ch) {
    final aa = onePole(params[2] / 2), ar = onePole(params[3] / 2);
    final s = 1 - 1 / math.max(1, params[1]);
    final thr = params[0], makeup = params[4];
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < ch; c++) {
        final x = buf[i * ch + c], e = x * x;
        _envs[c] += (e - _envs[c]) * (e > _envs[c] ? aa : ar);
        final lvl = 10 * libm.log(_envs[c] + 1e-30) / math.ln10;
        final gr = lvl > thr ? s * (lvl - thr) : 0.0;
        _grs[c] += (gr - _grs[c]) * _smooth;
        buf[i * ch + c] *= libm.dpow(10, (makeup - _grs[c]) / 20);
      }
    }
    sidechain = null;
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    if (params[6] < 0.5 && !useSidechain) {
      _unlinked(buf, frames, 2);
      return mono;
    }
    final key = useSidechain ? sidechain : buf;
    final aa = onePole(params[2] / 2), ar = onePole(params[3] / 2);
    final s = 1 - 1 / math.max(1, params[1]);
    final thr = params[0], makeup = params[4];
    for (var i = 0; i < frames; i++) {
      final double e;
      if (key == null) {
        e = 0;
      } else {
        final l = key[i * 2], r = key[i * 2 + 1];
        // A mono signal held in both channels has the power of one.
        e = identical(key, buf) && mono ? l * l : l * l + r * r;
      }
      _env += (e - _env) * (e > _env ? aa : ar);
      final lvl = 10 * libm.log(_env + 1e-30) / math.ln10;
      final gr = lvl > thr ? s * (lvl - thr) : 0.0;
      _gr += (gr - _gr) * _smooth;
      final g = libm.dpow(10, (makeup - _gr) / 20);
      buf[i * 2] *= g;
      buf[i * 2 + 1] *= g;
    }
    sidechain = null;
    return mono;
  }
}

/// The limiter, with the release in ms (0), the ceiling and maximizer gain
/// in dB (1, 2) and the link mode (3). It has no lookahead. The gain drops
/// at once to ceiling/|x| and recovers by e^(1/(release·fs)) per sample,
/// 8.686 dB per release time. A new limiter starts at the gain of the
/// ceiling. Mode 0 limits each channel on its own.
class Limiter extends Dsp {
  Limiter() : super([10, 0, 0, 0]) {
    _g.fillRange(0, 6, dbGain(params[1]));
  }
  final _g = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0];
  bool _fresh = true;

  @override
  void idle(int frames) {
    _fresh = false;
    final up = libm.exp(frames / (math.max(params[0], 0.01) * 1e-3 * mixRate));
    for (var ch = 0; ch < 6; ch++) {
      _g[ch] = math.min(1, _g[ch] * up);
    }
  }

  @override
  void changed(int index) {
    if (index == 1 && _fresh) _g.fillRange(0, 6, dbGain(params[1]));
  }

  /// Limits 5.1 with one gain from the loudest of the six channels when
  /// linked, else each channel on its own.
  @override
  bool process51(Float32List buf, int frames) {
    _fresh = false;
    final c = dbGain(params[1]);
    final up = libm.exp(1 / (math.max(params[0], 0.01) * 1e-3 * mixRate));
    final pre = dbGain(params[2]);
    final linked = params[3] >= 0.5;
    for (var i = 0; i < frames; i++) {
      var peak = 0.0;
      for (var ch = 0; ch < 6; ch++) {
        final a = (buf[i * 6 + ch] * pre).abs();
        if (a > peak) peak = a;
      }
      for (var ch = 0; ch < 6; ch++) {
        final a = linked ? peak : (buf[i * 6 + ch] * pre).abs();
        final t = a > c ? c / a : 1.0;
        final g = _g[ch];
        _g[ch] = t < g ? t : math.min(t, g * up);
        buf[i * 6 + ch] *= pre * _g[ch];
      }
    }
    return true;
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    _fresh = false;
    final c = dbGain(params[1]);
    final up = libm.exp(1 / (math.max(params[0], 0.01) * 1e-3 * mixRate));
    final pre = dbGain(params[2]);
    final linked = params[3] >= 0.5;
    for (var i = 0; i < frames; i++) {
      var a0 = (buf[i * 2] * pre).abs(), a1 = (buf[i * 2 + 1] * pre).abs();
      if (linked) a0 = a1 = math.max(a0, a1);
      for (var ch = 0; ch < 2; ch++) {
        final a = ch == 0 ? a0 : a1;
        final t = a > c ? c / a : 1.0;
        final g = _g[ch];
        _g[ch] = t < g ? t : math.min(t, g * up);
        buf[i * 2 + ch] *= pre * _g[ch];
      }
    }
    return mono;
  }
}

/// The tremolo, with the frequency in Hz (0), the depth (1), the shape (2),
/// the skew (3), the duty (4), the square (5), the phase (6) and the spread
/// (7). The gain is 1 − depth + depth·lfo. At phase 0 the LFO starts its
/// rise from 0. A duty d of 0.5 or more makes a trapezoid that rises over
/// 1 − d of the period, holds at 1 for 2d − 1 and falls over 1 − d, and 0.5
/// is the triangle. A duty below 0.5 rises over d, falls over d and holds
/// at 0. The shape bends the wave toward a sine. The spread puts L ahead
/// and R behind by a quarter of the spread of the period.
class Tremolo extends Dsp {
  Tremolo() : super([5, 1, 0, 0, 0.5, 0, 0, 0]);
  double _t = 0;

  @override
  void idle(int frames) => _t += frames / mixRate;

  double _lfo(double p) {
    p %= 1;
    if (p < 0) p += 1;
    final d = params[4].clamp(0.01, 0.99).toDouble();
    double v;
    if (d >= 0.5) {
      final r = 1 - d;
      v = p < r ? p / r : (p < d ? 1.0 : (1 - p) / r);
    } else {
      v = p < d ? p / d : (p < 2 * d ? (2 * d - p) / d : 0.0);
    }
    final sine = 0.5 - 0.5 * libm.cos(math.pi * v);
    v += (sine - v) * params[2].clamp(0, 1);
    final sq = params[5].clamp(0, 1);
    if (sq > 0) v += ((v < 0.5 ? 0.0 : 1.0) - v) * sq;
    return v;
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final f = math.max(params[0], 0.1), depth = params[1].clamp(0, 1);
    final ph = params[6], spread = params[7] / 4;
    for (var i = 0; i < frames; i++) {
      final p = _t * f + ph;
      final gl = 1 - depth + depth * _lfo(p + spread);
      final gr = spread == 0 ? gl : 1 - depth + depth * _lfo(p - spread);
      buf[i * 2] *= gl;
      buf[i * 2 + 1] *= gr;
      _t += 1 / mixRate;
    }
    return mono && spread == 0;
  }
}
