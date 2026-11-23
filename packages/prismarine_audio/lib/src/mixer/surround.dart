import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;

/// The surround panning onto 5.1 speakers of the pan DSP in surround mode
/// with a 5.1 target.
///
/// The channels have the order FL FR C LFE SL SR. The speakers are at −30,
/// 30, 0, −110 and 110 degrees, and the LFE takes no part in panning.
abstract final class Surround {
  /// The speakers by angle with their channels, the ring of the panning.
  static const _angle = [-110.0, -30.0, 0.0, 30.0, 110.0];
  static const _chan = [4, 0, 2, 1, 5];

  /// Adds the six 5.1 gains of a mono source at [direction] degrees spread
  /// over [extent] degrees, times [gain], into [out]. The LFE gets the
  /// linear gain [lfe] times [gain].
  ///
  /// A point source pans between the two speakers around it by 2D VBAP at
  /// unit power. An arc is cut at the speakers, and each piece pans as a point
  /// at its middle, weighted by its share of its speaker pair's span, and
  /// the sum is brought back to unit power. An extent of 360 or more puts
  /// gain/√5 on every speaker.
  static void mono(
    double direction,
    double extent,
    double gain,
    double lfe,
    Float64List out,
  ) {
    out[3] += lfe * gain;
    _arc(direction, extent, gain, out, unit: true);
  }

  /// Adds the gains of a stereo source in distributed mode, stereo mode 0.
  /// Each channel fills half the extent, placed by [rotation] against
  /// [direction] as [Spatial.stereo] places it, over the 5.1 ring. A channel
  /// whose half crosses behind is two arcs, summed without weights by power
  /// and brought back to unit power together. The LFE gets lfe·gain/√2 from
  /// each channel.
  static void stereoDistributed(
    double direction,
    double extent,
    double rotation,
    double gain,
    double lfe,
    Float64List outL,
    Float64List outR,
  ) {
    final k = extent / 360, rel = wrap(rotation - direction);
    if (rel >= 0) {
      _arc(direction + (rel - 90) * k, 180 * k, gain, outL, unit: true);
    } else {
      final t = _pair..fillRange(0, 6, 0);
      _arc(
        direction + (rel - 180) * 0.5 * k,
        k * (rel + 180),
        (rel + 180) / 180 * gain,
        t,
        unit: false,
      );
      _arc(
        direction + (rel * 0.5 + 180) * k,
        -rel * k,
        -rel / 180 * gain,
        t,
        unit: false,
      );
      _normalized(t, gain, outL);
    }
    if (rel > 0) {
      final t = _pair..fillRange(0, 6, 0);
      _arc(
        direction + (rel * 0.5 + 90) * k,
        k * (180 - rel),
        (180 - rel) / 180 * gain,
        t,
        unit: false,
      );
      _arc(
        direction + (rel * 0.5 - 180) * k,
        rel * k,
        rel / 180 * gain,
        t,
        unit: false,
      );
      _normalized(t, gain, outR);
    } else {
      _arc(direction + (rel + 90) * k, 180 * k, gain, outR, unit: true);
    }
    outL[3] += lfe * gain * math.sqrt1_2;
    outR[3] += lfe * gain * math.sqrt1_2;
  }

  /// Adds the gains of a stereo source in discrete mode, stereo mode 1. The
  /// channels are points at [axis] ∓ separation/2, and direction, extent and
  /// rotation play no part. The LFE gets lfe·gain/√2 from each channel.
  static void stereoDiscrete(
    double axis,
    double separation,
    double gain,
    double lfe,
    Float64List outL,
    Float64List outR,
  ) {
    mono(axis - separation * 0.5, 0, gain, lfe * math.sqrt1_2, outL);
    mono(axis + separation * 0.5, 0, gain, lfe * math.sqrt1_2, outR);
  }

  /// Adds the gains of one arc times [gain] into [out]. With [unit] they are
  /// brought back to unit power before the gain, else the weighted sum of
  /// the pieces is added as it is.
  static void _arc(
    double direction,
    double extent,
    double gain,
    Float64List out, {
    required bool unit,
  }) {
    final d = wrap(direction);
    if (extent >= 360) {
      final g = gain / math.sqrt(5);
      for (final c in _chan) {
        out[c] += g;
      }
      return;
    }
    if (extent <= 0) {
      for (var p = 0; p < 5; p++) {
        if (_inPair(p, d)) {
          _vbap(p, d, gain, out, unit: unit);
          return;
        }
      }
      return;
    }
    final g = _tmp..fillRange(0, 6, 0);
    final s = wrap(d - extent * 0.5);
    for (var p = 0; p < 5; p++) {
      final a = _angle[p], span = _span(p);
      // The arc from s to s + extent against the pair from a to a + span,
      // unwrapped.
      for (final shift in const [-360.0, 0.0, 360.0]) {
        final lo = math.max(s + shift, a);
        final hi = math.min(s + shift + extent, a + span);
        if (hi <= lo) continue;
        _vbap(p, wrap((lo + hi) * 0.5), (hi - lo) / span, g, unit: true);
      }
    }
    if (unit) {
      _normalized(g, gain, out);
      return;
    }
    for (var c = 0; c < 6; c++) {
      out[c] += g[c] * gain;
    }
  }

  /// Adds [g] at unit power times [gain] into [out]. Gains within 1e-6 of
  /// unit power stay as they are.
  static void _normalized(Float64List g, double gain, Float64List out) {
    var sum = 0.0;
    for (var c = 0; c < 6; c++) {
      sum += g[c] * g[c];
    }
    if (sum == 0) return;
    var k = gain;
    if (sum < 0.999999 || sum > 1.000001) k /= math.sqrt(sum);
    for (var c = 0; c < 6; c++) {
      out[c] += g[c] * k;
    }
  }

  static final _pair = Float64List(6);
  static final _tmp = Float64List(6);

  /// Returns [a] wrapped into [−180, 180).
  static double wrap(double a) {
    while (a < -180) {
      a += 360;
    }
    while (a >= 180) {
      a -= 360;
    }
    return a;
  }

  static double _span(int p) {
    final a = _angle[p], b = _angle[(p + 1) % 5];
    return b > a ? b - a : b - a + 360;
  }

  static bool _inPair(int p, double d) {
    final a = _angle[p], span = _span(p);
    var t = d - a;
    if (t < 0) t += 360;
    return t <= span;
  }

  /// Adds the VBAP gains of [d] between the speakers of pair [p] times [w]
  /// into [out], sin(b − d) and sin(d − a) over sin(b − a), or at unit
  /// power.
  static void _vbap(
    int p,
    double d,
    double w,
    Float64List out, {
    required bool unit,
  }) {
    const rad = math.pi / 180;
    final a = _angle[p], b = _angle[(p + 1) % 5];
    final ga = libm.sin((b - d) * rad), gb = libm.sin((d - a) * rad);
    final n = unit ? math.sqrt(ga * ga + gb * gb) : libm.sin((b - a) * rad);
    out[_chan[p]] += ga / n * w;
    out[_chan[(p + 1) % 5]] += gb / n * w;
  }

  /// The downmix from 5.1 to stereo, L = FL + C/√2 + SL/√2 and
  /// R = FR + C/√2 + SR/√2, without the LFE.
  static const downmix = math.sqrt1_2;
}
