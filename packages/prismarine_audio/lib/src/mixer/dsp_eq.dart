import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'dsp.dart';

/// FMOD_DSP_TYPE_MULTIBAND_EQ (36, FMOD 1.09): five bands A–E in series,
/// each a filter type (0), frequency Hz (1), Q (2) and gain dB (3) at
/// 4·band + k. Measured with S2's fmod64.dll [O: formats/telltale/
/// fmod-runtime.md "FMOD 1.09 (S2)"]:
///
/// - every type is an RBJ-cookbook biquad in transposed direct form II;
///   the 24 and 48 dB low- and high-passes are 2 and 4 identical sections
///   at Q^(1/2) and Q^(1/4);
/// - shelves ignore Q (S = 1: α = sin ω/√2), peaking uses A = 10^(gain/40);
/// - a shelf or peak at 0 dB, and a disabled band, pass the input untouched;
/// - a change of coefficients interpolates them linearly, sample by sample,
///   over the next block.
class MultibandEq extends Dsp {
  MultibandEq() : super(_defaults) {
    for (var b = 0; b < 5; b++) {
      _bands[b].design(params, b);
    }
    start();
  }

  static const _defaults = <double>[
    1.0, 8000, 0.707, 0, //
    0, 8000, 0.707, 0,
    0, 8000, 0.707, 0,
    0, 8000, 0.707, 0,
    0, 8000, 0.707, 0,
  ];

  final _bands = List.generate(5, (_) => EqBand());

  @override
  void changed(int index) => _bands[index ~/ 4].design(params, index ~/ 4);

  @override
  void start() {
    for (final b in _bands) {
      b.settle();
    }
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    for (final b in _bands) {
      b.run(buf, frames, 2);
    }
    return mono;
  }

  @override
  bool process51(Float32List buf, int frames) {
    for (final b in _bands) {
      b.run(buf, frames, 6);
    }
    return true;
  }
}

/// One band of the multiband EQ: up to four identical TDF2 sections whose
/// shared coefficients glide to a new design over one block.
class EqBand {
  /// Sections in series (0: the band passes its input).
  int sections = 0;

  /// The coefficients now (b0 b1 b2 a1 a2) and the design they glide to.
  final c = Float64List(5)..[0] = 1, to = Float64List(5)..[0] = 1;
  final _from = Float64List(5), _k = Float64List(5);
  bool _gliding = false;

  /// TDF2 state: [section][channel] s1 and s2.
  final _s1 = Float64List(4 * 6), _s2 = Float64List(4 * 6);

  /// Designs band [b] from [p] (the DSP's parameters) as the target.
  void design(List<double> p, int b) {
    final type = p[b * 4].round(), q = p[b * 4 + 2], gain = p[b * 4 + 3];
    final f = p[b * 4 + 1].clamp(20.0, 22000.0).toDouble();
    final n = switch (type) {
      1 || 4 || 10 || 11 || 12 => 1,
      2 || 5 => 2,
      3 || 6 => 4,
      7 || 8 || 9 => gain == 0 ? 0 : 1,
      _ => 0,
    };
    if (n == 0) {
      sections = 0;
      _gliding = false;
      return;
    }
    final w = 2 * math.pi * f / mixRate;
    final cw = libm.cos(w), sw = libm.sin(w);
    final a = libm.dpow(10, gain / 40);
    final qq = n == 1 ? q : libm.dpow(q, 1 / n);
    var al = sw / (2 * qq);
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
      case 1 || 2 || 3:
        b0 = (1 - cw) / 2;
        b1 = 1 - cw;
        b2 = b0;
        a0 = 1 + al;
        a1 = -2 * cw;
        a2 = 1 - al;
      case 4 || 5 || 6:
        b0 = (1 + cw) / 2;
        b1 = -(1 + cw);
        b2 = b0;
        a0 = 1 + al;
        a1 = -2 * cw;
        a2 = 1 - al;
      case 7 || 8:
        al = sw * math.sqrt1_2;
        final sq = 2 * math.sqrt(a) * al, s = type == 7 ? 1.0 : -1.0;
        b0 = a * ((a + 1) - s * (a - 1) * cw + sq);
        b1 = s * 2 * a * ((a - 1) - s * (a + 1) * cw);
        b2 = a * ((a + 1) - s * (a - 1) * cw - sq);
        a0 = (a + 1) + s * (a - 1) * cw + sq;
        a1 = -s * 2 * ((a - 1) + s * (a + 1) * cw);
        a2 = (a + 1) + s * (a - 1) * cw - sq;
      case 9:
        b0 = 1 + al * a;
        b1 = -2 * cw;
        b2 = 1 - al * a;
        a0 = 1 + al / a;
        a1 = -2 * cw;
        a2 = 1 - al / a;
      case 10:
        b0 = al;
        b1 = 0;
        b2 = -al;
        a0 = 1 + al;
        a1 = -2 * cw;
        a2 = 1 - al;
      case 11:
        b0 = 1;
        b1 = -2 * cw;
        b2 = 1;
        a0 = 1 + al;
        a1 = -2 * cw;
        a2 = 1 - al;
      default:
        b0 = 1 - al;
        b1 = -2 * cw;
        b2 = 1 + al;
        a0 = 1 + al;
        a1 = -2 * cw;
        a2 = 1 - al;
    }
    if (sections != n) {
      // A band coming on starts from a pass-through, with fresh sections [I].
      if (sections == 0) c.setAll(0, const [1.0, 0, 0, 0, 0]);
      _s1.fillRange(0, _s1.length, 0);
      _s2.fillRange(0, _s2.length, 0);
    }
    sections = n;
    to
      ..[0] = b0 / a0
      ..[1] = b1 / a0
      ..[2] = b2 / a0
      ..[3] = a1 / a0
      ..[4] = a2 / a0;
    _gliding = true;
  }

  /// Jumps to the target (a new DSP's stored parameters apply at once).
  void settle() {
    c.setAll(0, to);
    _gliding = false;
  }

  /// [frames] of [buf] ([ch] channels interleaved) through the sections.
  void run(Float32List buf, int frames, int ch) {
    if (sections == 0) return;
    if (_gliding) {
      _glide(buf, frames, ch);
      return;
    }
    final b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4];
    for (var s = 0; s < sections; s++) {
      for (var k = 0; k < ch; k++) {
        final j = s * 6 + k;
        var s1 = _s1[j], s2 = _s2[j];
        for (var i = 0; i < frames; i++) {
          final x = buf[i * ch + k];
          final y = b0 * x + s1;
          s1 = b1 * x - a1 * y + s2;
          s2 = b2 * x - a2 * y;
          buf[i * ch + k] = y;
        }
        _s1[j] = s1;
        _s2[j] = s2;
      }
    }
  }

  void _glide(Float32List buf, int frames, int ch) {
    final from = _from..setAll(0, c), k0 = _k;
    for (var i = 0; i < frames; i++) {
      final t = i / frames;
      for (var m = 0; m < 5; m++) {
        k0[m] = from[m] + (to[m] - from[m]) * t;
      }
      for (var s = 0; s < sections; s++) {
        for (var k = 0; k < ch; k++) {
          final j = s * 6 + k;
          final x = buf[i * ch + k];
          final y = k0[0] * x + _s1[j];
          _s1[j] = k0[1] * x - k0[3] * y + _s2[j];
          _s2[j] = k0[2] * x - k0[4] * y;
          buf[i * ch + k] = y;
        }
      }
    }
    settle();
  }
}
