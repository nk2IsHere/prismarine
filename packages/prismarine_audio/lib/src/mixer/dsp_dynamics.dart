import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'dsp.dart';

/// FMOD_DSP_TYPE_COMPRESSOR (18): threshold dB (0), ratio (1), attack ms (2),
/// release ms (3), make-up gain dB (4), sidechain (5, data: enable), and in
/// FMOD 1.09 linked (6, default on): off, each channel is detected and
/// compressed on its own [I: as the limiter's unlinked mode; S2 sets it off
/// on one bus, `bus:/Voice/Langs ALT`].
///
/// O: the detector is the channels' summed power Σx² (stereo L = R reads
/// +3 dB over one channel), followed by a one-pole attack/release follower;
/// the gain reduction is (1 − 1/ratio)·(10·log10(env) − threshold) above the
/// threshold. Static curves match to 0.05 dB with the follower's time
/// constants at half the attack/release (as amplitude-domain constants would
/// give) plus 2 ms of gain smoothing; transients match to about 0.6 dB.
class Compressor extends Dsp {
  Compressor() : super([0, 2.5, 20, 100, 0, 0, 1]);

  bool useSidechain = false;

  /// The sidechain input for the next [process] (stereo, same frames), or
  /// null for none (the input keys itself when the sidechain is off).
  Float32List? sidechain;

  double _env = 0, _gr = 0;

  /// Unlinked: each channel's follower and reduction.
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
      // The detector sums every channel's power [O: c51_comp: one gain on
      // all six channels].
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
        // A mono signal held dual-mono is one channel's power.
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

/// FMOD_DSP_TYPE_LIMITER (11): release ms (0), ceiling dB (1), maximizer gain
/// dB (2), mode (3: linked). O: no lookahead; the gain drops at once to
/// ceiling/|x| and recovers by e^(1/(release·fs)) per sample (8.686 dB per
/// release time); a new limiter starts at the ceiling's gain. Mode 0 limits
/// each channel on its own.
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

  /// 5.1: linked, one gain from the loudest of the six channels [O:
  /// c51_lim], else each channel on its own.
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

/// FMOD_DSP_TYPE_TREMOLO (22), also Studio's "FMOD Tremolo": frequency Hz
/// (0), depth (1), shape (2), skew (3), duty (4), square (5), phase (6),
/// spread (7). O: gain = 1 − depth + depth·lfo; at phase 0 the LFO starts its
/// rise from 0; duty d ≥ 0.5 makes a trapezoid (rise over 1 − d of the
/// period, hold at 1 for 2d − 1, fall over 1 − d; 0.5 is the triangle);
/// spread puts L ahead and R behind by spread/4 of the period. Duty below
/// 0.5 (mirrored: rise d, fall d, hold 0), shape (→ sine), square and skew
/// are approximations [I].
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
