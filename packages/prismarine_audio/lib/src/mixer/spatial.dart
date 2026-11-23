import 'dart:math' as math;
import 'dart:typed_data';
import 'package:prismarine_math/libm.dart' as libm;

/// FMOD 1.06's 3D panning on a stereo output, as the PAN DSP (27) in surround
/// mode does it with a 3D pan blend (see formats/telltale/fmod-runtime.md, "3D
/// events"): distance attenuation by the rolloff, an extent from the distance,
/// and the source's direction panned across the extent. Traced in the game's
/// fmod.dll and measured with the oracle (the mono law).
abstract final class Spatial {
  /// FMOD_DSP_PAN_3D_ROLLOFF [rolloff] at distance [d] (the system's rolloff
  /// scale is 1: GameApp.exe never calls set3DSettings).
  static double attenuation(int rolloff, double d, double min, double max) {
    if (min >= d) return 1;
    switch (rolloff) {
      case 0 || 1:
        if (d >= max) return 0;
        final v = (max - d) / (max - min);
        return rolloff == 0 ? v * v : v;
      case 2:
        return min / (max > d ? d : max);
      case 3:
        if (d >= max) return 0;
        final v = (max - d) / (max - min);
        final lin = v * v, inv = min / d;
        return lin > inv ? inv : lin;
      default:
        return 1;
    }
  }

  /// The 3D extent in degrees at distance [d]: extent mode
  /// [mode] 0 auto (a sound size of twice the min distance), 1 user
  /// ([size], at least [minExtent]), 2 off.
  static double extent(
    int mode,
    double d,
    double min,
    double size,
    double minExtent,
  ) {
    double fromSize(double s) =>
        s > 0 && s * 5 > d ? 360 / (d * d / (s * s) * 4 + 1) : 0;
    switch (mode) {
      case 0:
        return fromSize(min * 2);
      case 1:
        final e = fromSize(size);
        return minExtent > e ? minExtent : e;
      default:
        return 0;
    }
  }

  /// A mono source at [direction] degrees (0 ahead, +90 right) spread over
  /// [extent] degrees, on the stereo speakers: (left, right) at constant
  /// power. The lateral position is the mean of sin over the arc,
  /// s = sin(direction)·sinc(extent/2), and the gains are (√(2 − s²) ∓ s)/2
  /// [ORACLE fmod: exact to 0.001° over 42 low-level cases].
  static (double, double) mono(double direction, double extent) {
    var s = libm.sin(direction * math.pi / 180);
    if (extent >= 360) {
      s = 0;
    } else if (extent > 0) {
      final h = extent * math.pi / 360;
      s = s * (libm.sin(h) / h);
    }
    final g = math.sqrt(2 - s * s);
    return ((g - s) * 0.5, (g + s) * 0.5);
  }

  /// [a] in [−180, 180).
  static double wrap(double a) {
    while (a < -180) {
      a += 360;
    }
    while (a >= 180) {
      a -= 360;
    }
    return a;
  }

  /// Two arcs' pans weighted by [w1] and [w2], back to unit power.
  static (double, double) _join(
    double w1,
    (double, double) p1,
    double w2,
    (double, double) p2,
  ) {
    final l = w1 * p1.$1 + w2 * p2.$1, r = w1 * p1.$2 + w2 * p2.$2;
    final n = math.sqrt(l * l + r * r);
    return n > 0 ? (l / n, r / n) : (0, 0);
  }

  /// A stereo source (distributed): each input channel fills
  /// half the extent, placed by the image's [rotation] against the
  /// [direction] (the event's forward azimuth; Telltale sends no event
  /// orientation, so it stays 0). Returns ((L→left, L→right), (R→left,
  /// R→right)) [O: within 0.001 of 24 low-level cases].
  static ((double, double), (double, double)) stereo(
    double direction,
    double extent,
    double rotation,
  ) {
    final k = extent / 360, rel = wrap(rotation - direction);
    final (double, double) l, r;
    if (rel < 0) {
      l = _join(
        (rel + 180) / 180,
        mono(direction + (rel - 180) * 0.5 * k, k * (rel + 180)),
        -rel / 180,
        mono(direction + (rel * 0.5 + 180) * k, -rel * k),
      );
    } else {
      l = mono(direction + (rel - 90) * k, k * 180);
    }
    if (rel > 0) {
      r = _join(
        (180 - rel) / 180,
        mono(direction + (rel + 180) * 0.5 * k, k * (180 - rel)),
        rel / 180,
        mono(direction + (rel * 0.5 - 180) * k, rel * k),
      );
    } else {
      r = mono(direction + (rel + 90) * k, k * 180);
    }
    return (l, r);
  }

  /// The PAN DSP's 3D gains for its parameters [p] (FMOD indices) with the
  /// source at [azimuth]/[distance]: into [out] = (L→left, R→left, L→right,
  /// R→right), times the attenuation; a [mono] input uses the first column.
  static void gains(
    List<double> p,
    double azimuth,
    double distance,
    bool mono,
    Float64List out,
  ) {
    final min = p[12], max = p[13];
    final att = attenuation(p[11].round(), distance, min, max);
    final e = extent(p[14].round(), distance, min, p[15], p[16]);
    if (mono) {
      final (l, r) = Spatial.mono(azimuth, e);
      out[0] = l * att;
      out[1] = 0;
      out[2] = r * att;
      out[3] = 0;
    } else {
      final (sl, sr) = stereo(azimuth, e, 0);
      out[0] = sl.$1 * att;
      out[1] = sr.$1 * att;
      out[2] = sl.$2 * att;
      out[3] = sr.$2 * att;
    }
  }
}
