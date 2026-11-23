import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:test/test.dart';

/// FMOD 1.06's 3D panning against the oracle (the game's fmod.dll under
/// CrossOver; docs/formats/fmod-bank.md "3D events").
void main() {
  double deg(double l, double r) => math.atan2(r, l) * 180 / math.pi;

  test('rolloffs as fmod.dll\'s 3D panner', () {
    // sfx_smolder_burn_costume_lp (linear, 3–18): 0.8 / 0.6 / 0.4 / 0.2 at
    // 6 / 9 / 12 / 15, 1 inside the min distance, 0 from the max on.
    expect(Spatial.attenuation(1, 6, 3, 18), closeTo(0.8, 1e-12));
    expect(Spatial.attenuation(1, 15, 3, 18), closeTo(0.2, 1e-12));
    expect(Spatial.attenuation(1, 2, 3, 18), 1);
    expect(Spatial.attenuation(1, 25, 3, 18), 0);
    expect(Spatial.attenuation(0, 9, 3, 15), closeTo(0.25, 1e-12));
    expect(Spatial.attenuation(2, 6, 3, 18), closeTo(0.5, 1e-12));
    expect(Spatial.attenuation(4, 100, 3, 18), 1);
  });

  test('auto extent: 360 / (1 + d² / min²)', () {
    expect(Spatial.extent(0, 6, 3, 0, 0), closeTo(72, 1e-9));
    expect(Spatial.extent(0, 0, 3, 0, 0), 360);
    expect(Spatial.extent(0, 31, 3, 0, 0), 0);
    expect(Spatial.extent(1, 6, 3, 0, 30), 30);
    expect(Spatial.extent(2, 1, 3, 0, 0), 0);
  });

  test('the mono law matches the low-level oracle (degrees of pan)', () {
    // (extent, direction) → the oracle's atan2(R, L) in degrees.
    final cases = {
      (0.0, 30.0): 65.704,
      (30.0, 60.0): 82.258,
      (90.0, 30.0): 63.561,
      (180.0, 90.0): 71.754,
      (270.0, 120.0): 55.59,
    };
    for (final MapEntry(key: (e, a), value: o) in cases.entries) {
      final (l, r) = Spatial.mono(a, e);
      expect(deg(l, r), closeTo(o, 0.002), reason: '$e $a');
      expect(l * l + r * r, closeTo(1, 1e-12));
    }
  });

  test('the stereo image matches the low-level oracle', () {
    // extent 60, direction 30: L→(left, right), R→(left, right).
    final ((ll, lr), (rl, rr)) = Spatial.stereo(30, 60, 0);
    expect(ll, closeTo(0.5260, 0.001));
    expect(lr, closeTo(0.8505, 0.001));
    expect(rl, closeTo(0.3137, 0.001));
    expect(rr, closeTo(0.9495, 0.001));
  });

  test('a PAN DSP in surround mode with a 3D blend pans its event like '
      'Studio (sfx_smolder_burn_costume_lp, 6 m, 30° to the left)', () {
    final pan = Pan();
    final stored = <double>[
      2, 0, 0, 360, 0, 0, 1, 60, 0, 4095, 0, 1, 3, 18, 0, 0, 0, 1, 0, 0, 0, //
    ];
    for (final (i, v) in stored.indexed) {
      pan.set(i, v);
    }
    pan
      ..azimuth = -30
      ..distance = 6;
    final buf = Float32List.fromList([1, 1]);
    pan.process(buf, 1, mono: true);
    // The oracle's gains against the centred source inside the min distance.
    expect(buf[0] / math.sqrt1_2, closeTo(1.0196, 0.0005));
    expect(buf[1] / math.sqrt1_2, closeTo(0.4904, 0.0005));
  });
}
