import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'dsp.dart';

/// FMOD_DSP_TYPE_SFXREVERB (19), I3DL2-style: decay ms (0), early delay ms
/// (1), late delay ms (2), HF reference Hz (3), HF decay ratio % (4),
/// diffusion % (5), density % (6), low-shelf Hz (7) and dB (8), high cut Hz
/// (9), early/late mix % (10), wet dB (11), dry dB (12).
///
/// FMOD's algorithm is its own; this one matches what the oracle measured:
/// the wet input is the channels' sum; early reflections start at the early
/// delay, the late tail at early + late delay and decays at the decay time
/// (scaled by the HF ratio at and above the HF reference); the early/late mix
/// is constant-power and each part carries +4.5 dB of energy per channel for
/// an impulse in both channels, whatever the decay time; the two outputs are
/// decorrelated [O statistics; structure I].
class Reverb extends Dsp {
  Reverb()
    : super([1500, 20, 40, 5000, 50, 100, 100, 250, 0, 20000, 50, -6, 0]) {
    _update();
  }

  static const _lines = 8;
  static const _base = [1123, 1291, 1447, 1597, 1777, 1949, 2113, 2311];
  static const _diffusers = [142, 107, 379, 277];

  /// Early taps (ms after the early delay, relative gain), left and right.
  static final _taps = _makeTaps();

  /// [_taps], for the native mixer (drawn from Dart's `Random(19)`).
  static List<(double, double, double)> get earlyTaps => _taps;

  // Delay memory for the input (early taps and the late pre-delay).
  final _pre = Float32List(1 << 16);
  int _prePos = 0;
  final _diff = [for (final n in _diffusers) Float32List(n)];
  final _diffPos = List.filled(_diffusers.length, 0);
  final _line = [for (final n in _base) Float32List((n * 1.2).ceil() + 1)];
  final _linePos = List.filled(_lines, 0);
  final _lineLen = List.filled(_lines, 0);
  final _gain = List.filled(_lines, 0.0);
  final _damp = List.filled(_lines, 0.0);
  final _lp = List.filled(_lines, 0.0);
  final _shelf = _Shelf();
  final _cutState = List.filled(6, 0.0);
  double _cutA = 1;
  double _lateNorm = 1, _earlyNorm = 1;

  @override
  void changed(int index) => _update();

  void _update() {
    final t60 = math.max(params[0], 100) / 1000;
    final density = params[6].clamp(0, 100) / 100;
    final ratio = params[4].clamp(10, 100) / 100;
    final w = 2 * math.pi * params[3].clamp(20, 20000) / mixRate;
    for (var i = 0; i < _lines; i++) {
      final len = (_base[i] * (0.6 + 0.4 * density)).round();
      _lineLen[i] = len;
      final g = libm.dpow(10, -3 * len / (t60 * mixRate));
      _gain[i] = g;
      // A one-pole low-pass in the loop: |H(ω_ref)| / |H(0)| = g_ref / g.
      final gRef = libm.dpow(10, -3 * len / (t60 * ratio * mixRate));
      final rho = (gRef / g).clamp(0.0, 1.0);
      _damp[i] = _solveDamp(rho, w);
    }
    _shelf.set(params[7], params[8]);
    // The high cut is gentle: a one-pole low-pass (O: band energies).
    _cutA = 1 - libm.exp(-2 * math.pi * params[9].clamp(20, 20000) / mixRate);
    // The network's tail energy is mean(g²/(1 − g²)) per unit input (an
    // orthogonal feedback matrix keeps energy; each pass scales line i by
    // gᵢ); FMOD's tail carries a fixed energy whatever the decay time.
    var e = 0.0;
    for (final g in _gain) {
      e += g * g / (1 - g * g) / _lines;
    }
    _lateNorm = math.sqrt(_target / e) / dbGain(_excess(t60));
    var es = 0.0;
    for (final (_, gl, _) in _taps) {
      es += gl * gl;
    }
    _earlyNorm = math.sqrt(_target / es);
  }

  /// What correlation between the lines adds over the series estimate
  /// (dB, by decay time; calibrated on this network).
  static double _excess(double t60) {
    const pts = [
      (0.17, 0.2),
      (0.5, 1.25),
      (1.5, 2.15),
      (3.0, 2.5),
      (6.0, 2.75),
    ];
    final x = libm.log(t60);
    if (x <= libm.log(pts.first.$1)) return pts.first.$2;
    for (var i = 1; i < pts.length; i++) {
      final x1 = libm.log(pts[i].$1);
      if (x <= x1) {
        final x0 = libm.log(pts[i - 1].$1);
        return pts[i - 1].$2 +
            (pts[i].$2 - pts[i - 1].$2) * (x - x0) / (x1 - x0);
      }
    }
    return pts.last.$2;
  }

  /// +4.5 dB.
  static final _target = libm.dpow(10, 0.45);

  /// d for a one-pole (1 − d)/(1 − d·z⁻¹) whose gain at ω is [rho].
  static double _solveDamp(double rho, double w) {
    if (rho >= 0.9999) return 0;
    // ρ² (1 − 2d cos ω + d²) = (1 − d)²  →  a d² + b d + c = 0.
    final c0 = libm.cos(w), r2 = rho * rho;
    final a = r2 - 1, b = 2 - 2 * r2 * c0, c = r2 - 1;
    final disc = b * b - 4 * a * c;
    if (disc < 0 || a == 0) return 0;
    final d1 = (-b + math.sqrt(disc)) / (2 * a),
        d2 = (-b - math.sqrt(disc)) / (2 * a);
    for (final d in [d1, d2]) {
      if (d >= 0 && d < 1) return d;
    }
    return 0;
  }

  /// The early stage: a diffused burst. O (early-only impulse, 10 ms bins
  /// from the early delay): it builds over 30 ms, holds within ~6 dB to
  /// 90 ms, then falls ~5 dB per 10 ms, whatever the decay time.
  static const _earlyEnvelope = [
    -3.1, -1.4, 0.0, -2.7, -6.4, -2.4, -4.9, -6.4, -11.8, -16.9, -21.3, //
    -25.7, -31.5, -36.6, -41.5, -46.9, -51.8, -57.2, -63.2, -68.8, -73.3,
  ];

  static List<(double, double, double)> _makeTaps() {
    final rnd = math.Random(19);
    const perBin = 8;
    final taps = <(double, double, double)>[(0, 0.4, 0.4)];
    for (final (k, db) in _earlyEnvelope.indexed) {
      final a = math.sqrt(libm.dpow(10, db / 10) / perBin);
      for (var j = 0; j < perBin; j++) {
        taps.add((
          k * 10 + rnd.nextDouble() * 10,
          a * (rnd.nextBool() ? 1 : -1),
          a * (rnd.nextBool() ? 1 : -1),
        ));
      }
    }
    return taps;
  }

  double _delayed(int samples) => _pre[(_prePos - samples) & (_pre.length - 1)];

  /// On a 5.1 bus (S2's `bus:/Reverb`, its snapshots' reverbs): the wet
  /// input is all six channels' sum; each of the six outputs (the LFE too)
  /// carries the reverb at equal energy, uncorrelated with the others, at
  /// [_wet51] of the stereo form's level for the same input; the dry part
  /// is each channel × dry [ORACLE fmod109 rv51_imp_*, rv51_noise*,
  /// rv51_dry]. The outputs are the network's lines through rows 2–7 of
  /// the 8-point Hadamard matrix (row 1, which feeds the input in, carries
  /// more) and the early taps a, b, a·sign b and their alternations by tap
  /// [I: decorrelated, equal and at the level measured].
  @override
  bool process51(Float32List buf, int frames) {
    final wet = dbGain(params[11]), dry = dbGain(params[12]);
    if (wet == 0 && dry == 0) {
      buf.fillRange(0, frames * 6, 0);
      return true;
    }
    final mix = params[10].clamp(0, 100) / 100;
    final ge = libm.cos(mix * math.pi / 2) * _earlyNorm * wet * _wet51;
    final gl = libm.sin(mix * math.pi / 2) * _lateNorm * wet * _wet51;
    final early = (params[1].clamp(0, 300) * mixRate / 1000).round();
    final late = math.max(
      0,
      early +
          (params[2].clamp(0, 100) * mixRate / 1000).round() -
          _lineLen.reduce(math.min),
    );
    final diffusion = 0.7 * params[5].clamp(0, 100) / 100;
    final cut = params[9] < 20000;
    final s = 1 / math.sqrt(_lines);
    final y = List.filled(_lines, 0.0);
    final e = List.filled(6, 0.0), l = List.filled(6, 0.0);
    for (var i = 0; i < frames; i++) {
      var sum = 0.0;
      for (var c = 0; c < 6; c++) {
        sum += buf[i * 6 + c];
      }
      _pre[_prePos] = _shelf.tick(sum / 2);
      e.fillRange(0, 6, 0);
      if (ge != 0) {
        for (final (k, (t, a, b)) in _taps.indexed) {
          final v = _delayed(early + (t * mixRate / 1000).round());
          final alt = k.isEven ? v : -v;
          e[0] += a * v;
          e[1] += b * v;
          e[2] += a * b.sign * v;
          e[3] += a * b.sign * alt;
          e[4] += a * alt;
          e[5] += b * alt;
        }
      }
      var x = _delayed(late);
      for (var k = 0; k < _diff.length; k++) {
        final d = _diff[k], p = _diffPos[k];
        final z = d[p];
        final v = x + diffusion * z;
        d[p] = v;
        x = z - diffusion * v;
        _diffPos[k] = (p + 1) % d.length;
      }
      l.fillRange(0, 6, 0);
      for (var j = 0; j < _lines; j++) {
        final d = _line[j];
        final out = d[(_linePos[j] - _lineLen[j]) % d.length];
        _lp[j] = (1 - _damp[j]) * out + _damp[j] * _lp[j];
        y[j] = _lp[j] * _gain[j];
        for (var c = 0; c < 6; c++) {
          l[c] += _row(c + 2, j) * y[j];
        }
      }
      _hadamard(y);
      for (var j = 0; j < _lines; j++) {
        final d = _line[j];
        d[_linePos[j] % d.length] = y[j] * s + x * (j.isEven ? 1 : -1);
        _linePos[j] = (_linePos[j] + 1) % d.length;
      }
      for (var c = 0; c < 6; c++) {
        var w = ge * e[c] + gl * l[c] * s;
        if (cut) w = _cutState[c] += (w - _cutState[c]) * _cutA;
        buf[i * 6 + c] = dry * buf[i * 6 + c] + w;
      }
      _prePos = (_prePos + 1) & (_pre.length - 1);
    }
    return true;
  }

  /// Row [r] of the 8-point Hadamard matrix at column [j]: the parity of
  /// the bits they share.
  static double _row(int r, int j) {
    var b = r & j, p = 1.0;
    while (b != 0) {
      if (b & 1 == 1) p = -p;
      b >>= 1;
    }
    return p;
  }

  /// Each 5.1 output against the stereo form's per-channel level.
  static final _wet51 = libm.dpow(10, -5.2 / 20);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final wet = dbGain(params[11]), dry = dbGain(params[12]);
    final mix = params[10].clamp(0, 100) / 100;
    final ge = libm.cos(mix * math.pi / 2) * _earlyNorm * wet;
    final gl = libm.sin(mix * math.pi / 2) * _lateNorm * wet;
    final early = (params[1].clamp(0, 300) * mixRate / 1000).round();
    // The network's shortest line delays the tail once more.
    final late = math.max(
      0,
      early +
          (params[2].clamp(0, 100) * mixRate / 1000).round() -
          _lineLen.reduce(math.min),
    );
    final diffusion = 0.7 * params[5].clamp(0, 100) / 100;
    final cut = params[9] < 20000;
    final s = 1 / math.sqrt(_lines);
    final y = List.filled(_lines, 0.0);
    for (var i = 0; i < frames; i++) {
      final l0 = buf[i * 2], r0 = buf[i * 2 + 1];
      _pre[_prePos] = _shelf.tick((l0 + r0) / 2);
      // Early reflections.
      var el = 0.0, er = 0.0;
      if (ge != 0) {
        for (final (t, a, b) in _taps) {
          final v = _delayed(early + (t * mixRate / 1000).round());
          el += a * v;
          er += b * v;
        }
      }
      // Late: pre-delay, diffusion, then the feedback network.
      var x = _delayed(late);
      for (var k = 0; k < _diff.length; k++) {
        final d = _diff[k], p = _diffPos[k];
        final z = d[p];
        final v = x + diffusion * z;
        d[p] = v;
        x = z - diffusion * v;
        _diffPos[k] = (p + 1) % d.length;
      }
      var ll = 0.0, lr = 0.0;
      for (var j = 0; j < _lines; j++) {
        final d = _line[j];
        final out = d[(_linePos[j] - _lineLen[j]) % d.length];
        _lp[j] = (1 - _damp[j]) * out + _damp[j] * _lp[j];
        y[j] = _lp[j] * _gain[j];
        ll += (j.isEven ? 1 : -1) * y[j];
        lr += (j % 4 < 2 ? 1 : -1) * y[j];
      }
      // Hadamard feedback (orthogonal, lossless) plus the input.
      _hadamard(y);
      for (var j = 0; j < _lines; j++) {
        final d = _line[j];
        d[_linePos[j] % d.length] = y[j] * s + x * (j.isEven ? 1 : -1);
        _linePos[j] = (_linePos[j] + 1) % d.length;
      }
      var wl = ge * el + gl * ll * s, wr = ge * er + gl * lr * s;
      if (cut) {
        wl = _cutState[0] += (wl - _cutState[0]) * _cutA;
        wr = _cutState[1] += (wr - _cutState[1]) * _cutA;
      }
      buf[i * 2] = dry * l0 + wl;
      buf[i * 2 + 1] = dry * r0 + wr;
      _prePos = (_prePos + 1) & (_pre.length - 1);
    }
    return false;
  }

  static void _hadamard(List<double> v) {
    for (var h = 1; h < v.length; h <<= 1) {
      for (var i = 0; i < v.length; i += h << 1) {
        for (var j = i; j < i + h; j++) {
          final a = v[j], b = v[j + h];
          v[j] = a + b;
          v[j + h] = a - b;
        }
      }
    }
  }
}

/// An RBJ low shelf (S = 1), mono.
class _Shelf {
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;
  bool _flat = true;

  void set(double f, double db) {
    _flat = db.abs() < 1e-6;
    if (_flat) return;
    final a = libm.dpow(10, db / 40);
    final w = 2 * math.pi * f.clamp(20, 1000) / mixRate;
    final c = libm.cos(w), al = libm.sin(w) / 2 * math.sqrt2;
    final sq = 2 * math.sqrt(a) * al;
    final a0 = (a + 1) + (a - 1) * c + sq;
    _b0 = a * ((a + 1) - (a - 1) * c + sq) / a0;
    _b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0;
    _b2 = a * ((a + 1) - (a - 1) * c - sq) / a0;
    _a1 = -2 * ((a - 1) + (a + 1) * c) / a0;
    _a2 = ((a + 1) + (a - 1) * c - sq) / a0;
  }

  double tick(double x) {
    if (_flat) return x;
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
