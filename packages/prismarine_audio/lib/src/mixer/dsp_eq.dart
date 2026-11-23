import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'dsp.dart';

/// The multiband EQ, five bands A to E in series. Band b has its filter
/// type, frequency in Hz, Q and gain in dB at 4·b + 0 to 4·b + 3.
///
/// Every type is an RBJ cookbook biquad in transposed direct form II. The
/// 24 and 48 dB low-passes and high-passes are 2 and 4 identical sections at
/// Q^(1/2) and Q^(1/4). The shelves ignore Q with S = 1 and the peaking
/// filter uses A = 10^(gain/40). A shelf or peak at 0 dB and a disabled band
/// pass the input untouched. A change of coefficients interpolates them
/// linearly, sample by sample, over the next block.
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

/// One band of the multiband EQ, up to four identical TDF2 sections whose
/// shared coefficients glide to a new design over one block.
class EqBand {
  /// The sections in series, 0 for a band that passes its input.
  int sections = 0;

  /// The coefficients now (b0 b1 b2 a1 a2) and the design they glide to.
  final c = Float64List(5)..[0] = 1, to = Float64List(5)..[0] = 1;
  final _from = Float64List(5), _k = Float64List(5);
  bool _gliding = false;

  /// The TDF2 state z1 and z2 by section and channel.
  final _z1 = Float64List(4 * 6), _z2 = Float64List(4 * 6);

  /// Designs band [b] from the DSP's parameters [p] as the target.
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
      // A band coming on starts from a pass-through, with fresh sections.
      if (sections == 0) c.setAll(0, const [1.0, 0, 0, 0, 0]);
      _z1.fillRange(0, _z1.length, 0);
      _z2.fillRange(0, _z2.length, 0);
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

  /// Jumps to the target, as for the stored parameters of a new DSP.
  void settle() {
    c.setAll(0, to);
    _gliding = false;
  }

  /// Runs [frames] frames of [buf], [ch] channels interleaved, through the
  /// sections.
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
        var z1 = _z1[j], z2 = _z2[j];
        for (var i = 0; i < frames; i++) {
          final x = buf[i * ch + k];
          final y = b0 * x + z1;
          z1 = b1 * x - a1 * y + z2;
          z2 = b2 * x - a2 * y;
          buf[i * ch + k] = y;
        }
        _z1[j] = z1;
        _z2[j] = z2;
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
          final y = k0[0] * x + _z1[j];
          _z1[j] = k0[1] * x - k0[3] * y + _z2[j];
          _z2[j] = k0[2] * x - k0[4] * y;
          buf[i * ch + k] = y;
        }
      }
    }
    settle();
  }
}
