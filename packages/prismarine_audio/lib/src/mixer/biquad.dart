import 'dart:math' as math;

import 'package:prismarine_math/libm.dart' as libm;
import 'dsp.dart';

/// An RBJ biquad (direct form I) with stereo state.
class Biquad {
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  final _x1 = [0.0, 0.0], _x2 = [0.0, 0.0], _y1 = [0.0, 0.0], _y2 = [0.0, 0.0];

  void lowpass(double fc, double q) => _set(fc, q, false);
  void highpass(double fc, double q) => _set(fc, q, true);

  /// Sets a peaking section with A = 10^([gainDb]/20) and Q = 1/[bandwidth].
  /// The centre moves by twice [gainDb].
  void peaking(double fc, double bandwidth, double gainDb) {
    final f = fc.clamp(1.0, mixRate / 2 - 1).toDouble();
    final w = 2 * math.pi * f / mixRate;
    final c = libm.cos(w);
    final al = libm.sin(w) * math.max(bandwidth, 1e-3) / 2;
    final a = libm.dpow(10, gainDb / 20);
    final a0 = 1 + al / a;
    _b0 = (1 + al * a) / a0;
    _b1 = -2 * c / a0;
    _b2 = (1 - al * a) / a0;
    _a1 = -2 * c / a0;
    _a2 = (1 - al / a) / a0;
  }

  void _set(double fc, double q, bool high) {
    final f = fc.clamp(1.0, mixRate / 2 - 1).toDouble();
    final w = 2 * math.pi * f / mixRate;
    final c = libm.cos(w), al = libm.sin(w) / (2 * q);
    final a0 = 1 + al;
    final b = high ? (1 + c) / 2 : (1 - c) / 2;
    _b0 = b / a0;
    _b1 = (high ? -(1 + c) : 1 - c) / a0;
    _b2 = b / a0;
    _a1 = -2 * c / a0;
    _a2 = (1 - al) / a0;
  }

  double tick(int ch, double x) {
    final y =
        _b0 * x + _b1 * _x1[ch] + _b2 * _x2[ch] - _a1 * _y1[ch] - _a2 * _y2[ch];
    _x2[ch] = _x1[ch];
    _x1[ch] = x;
    _y2[ch] = _y1[ch];
    _y1[ch] = y;
    return y;
  }
}

/// The Butterworth Qs of a 4th-order section pair.
final butterworth4 = [
  1 / (2 * libm.cos(math.pi / 8)),
  1 / (2 * libm.cos(3 * math.pi / 8)),
];
