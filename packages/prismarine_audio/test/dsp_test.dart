import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:test/test.dart';

/// The expected values are the FMOD oracle's measurements of the game's FMOD
/// 1.06.02 DSPs (see formats/telltale/fmod-runtime.md, "Built-in DSPs").
const fs = 48000;

/// [dsp]'s response in dB at [f] Hz: an impulse (both channels), DFT of the
/// left output.
double responseDb(Dsp dsp, double f, {int n = 16384}) {
  final buf = Float32List(n * 2);
  buf[0] = 1;
  buf[1] = 1;
  dsp.process(buf, n);
  var re = 0.0, im = 0.0;
  for (var i = 0; i < n; i++) {
    final w = 2 * math.pi * f * i / fs;
    re += buf[i * 2] * math.cos(w);
    im -= buf[i * 2] * math.sin(w);
  }
  return 20 * math.log(math.sqrt(re * re + im * im)) / math.ln10;
}

/// A stereo 1 kHz sine with per-segment peak levels (dBFS) of [seconds] each.
Float32List stairs(List<num> levels, double seconds, {bool right = true}) {
  final seg = (seconds * fs).round();
  final buf = Float32List(levels.length * seg * 2);
  for (var k = 0; k < levels.length; k++) {
    final a = math.pow(10, levels[k] / 20);
    for (var i = 0; i < seg; i++) {
      final v = a * math.sin(2 * math.pi * 1000 * (k * seg + i) / fs);
      buf[(k * seg + i) * 2] = v.toDouble();
      buf[(k * seg + i) * 2 + 1] = right ? v.toDouble() : 0;
    }
  }
  return buf;
}

/// Gain (dB) of [out] over [inp] on the left channel in frames [a, b).
double gainDb(Float32List out, Float32List inp, int a, int b) {
  var so = 0.0, si = 0.0;
  for (var i = a; i < b; i++) {
    so += out[i * 2] * out[i * 2];
    si += inp[i * 2] * inp[i * 2];
  }
  return 10 * math.log(so / si) / math.ln10;
}

Float32List copy(Float32List x) => Float32List.fromList(x);

void main() {
  group('lowpass (dsp 3): two Butterworth biquads, Q × resonance', () {
    test('1 kHz: −3.01 at fc, −24.27 at 2 fc, −49.1 at 4 fc', () {
      Dsp lp() => Lowpass()
        ..set(0, 1000)
        ..set(1, 1);
      expect(responseDb(lp(), 1000), closeTo(-3.01, 0.05));
      expect(responseDb(lp(), 2000), closeTo(-24.27, 0.1));
      expect(responseDb(lp(), 4000), closeTo(-49.10, 0.3));
      expect(responseDb(lp(), 707), closeTo(-0.26, 0.05));
    });
    test('resonance 5 peaks +24.95 dB at fc', () {
      final lp = Lowpass()
        ..set(0, 1000)
        ..set(1, 5);
      expect(responseDb(lp, 1000), closeTo(24.95, 0.1));
    });
  });

  group('three-band EQ (dsp 28): Linkwitz-Riley 24 dB/oct, parallel bands', () {
    Dsp eq(
      double lo,
      double mid,
      double hi, [
      double f1 = 400,
      double f2 = 4000,
    ]) => ThreeEq()
      ..set(0, lo)
      ..set(1, mid)
      ..set(2, hi)
      ..set(3, f1)
      ..set(4, f2)
      ..set(5, 1);
    test('0 dB gains: flat within the crossovers\' 0.11 dB ripple', () {
      for (final (f, want) in [
        (100.0, 0.0), (566.0, -0.11), (1600.0, -0.07), (2828.0, -0.11), //
        (8000.0, 0.0),
      ]) {
        expect(responseDb(eq(0, 0, 0), f), closeTo(want, 0.03), reason: '$f');
      }
    });
    test('cut bands: −6.03 dB at each crossover', () {
      expect(responseDb(eq(-80, 0, 0), 400), closeTo(-6.03, 0.05));
      expect(responseDb(eq(-80, 0, 0), 200), closeTo(-24.62, 0.1));
      expect(responseDb(eq(0, -80, 0), 1600), closeTo(-33.14, 0.2));
      expect(responseDb(eq(0, 0, -80), 4000), closeTo(-6.03, 0.05));
    });
    test('Reuben\'s low −9.5 dB at 620 Hz', () {
      final r = eq(-9.5, 0, 0, 620);
      expect(responseDb(r, 50), closeTo(-9.50, 0.05));
      expect(responseDb(r, 400), closeTo(-7.34, 0.05));
      expect(responseDb(r, 1600), closeTo(-0.28, 0.05));
    });
  });

  group('pan (dsp 27), 2D', () {
    (double, double) pan(double pos, {required bool mono, bool left = false}) {
      final buf = Float32List.fromList([1, left ? 0 : 1]);
      Pan()
        ..set(1, pos)
        ..process(buf, 1, mono: mono);
      return (buf[0], buf[1]);
    }

    test('mono input: constant power, −3 dB per side at the centre', () {
      final (l, r) = pan(0, mono: true);
      expect(l, closeTo(0.7071, 1e-4));
      expect(r, closeTo(0.7071, 1e-4));
      final (l50, r50) = pan(50, mono: true);
      expect(l50, closeTo(0.3827, 1e-4));
      expect(r50, closeTo(0.9239, 1e-4));
    });
    test('stereo input: unity at the centre, √2·cos/sin balance, no '
        'cross-feed', () {
      final (c0, c1) = pan(0, mono: false);
      expect(c0, closeTo(1, 1e-6));
      expect(c1, closeTo(1, 1e-6));
      final (l, r) = pan(50, mono: false);
      expect(l, closeTo(0.5412, 1e-4));
      expect(r, closeTo(1.3066, 1e-4));
      final (ll, lr) = pan(-100, mono: false, left: true);
      expect(ll, closeTo(1.4142, 1e-4));
      expect(lr, 0);
    });
  });

  group('compressor (dsp 18): power-sum detector', () {
    Compressor comp(double thr, double ratio, double att, double rel) =>
        Compressor()
          ..set(0, thr)
          ..set(1, ratio)
          ..set(2, att)
          ..set(3, rel)
          ..set(4, 0);

    test('static curve: slope 1 − 1/ratio over the threshold; both channels '
        'add', () {
      const levels = [-40.0, -35, -30, -25, -20, -15, -10, -5, 0];
      final want = [0.0, 0, 0, 0, -1.0, -4.0, -6.96, -9.98, -13.01];
      final x = stairs(levels, 0.5);
      final y = copy(x);
      comp(-20, 2.5, 20, 100).process(y, y.length ~/ 2);
      for (var k = 0; k < levels.length; k++) {
        final g = gainDb(y, x, k * 24000 + 12000, k * 24000 + 23900);
        expect(g, closeTo(want[k], 0.15), reason: '${levels[k]} dBFS');
      }
      final xl = stairs(levels, 0.5, right: false);
      final yl = copy(xl);
      comp(-20, 2.5, 20, 100).process(yl, yl.length ~/ 2);
      expect(
        gainDb(yl, xl, 5 * 24000 + 12000, 5 * 24000 + 23900),
        closeTo(-2.22, 0.15),
      );
    });

    test('a +14 dB burst: attack to −9.38 dB, release past −5.03 dB after '
        '100 ms', () {
      final x = stairs([-24, -6, -24], 1);
      final y = copy(x);
      comp(-20, 2.5, 20, 100).process(y, y.length ~/ 2);
      expect(gainDb(y, x, 48000 + 24000, 96000 - 100), closeTo(-9.38, 0.1));
      expect(gainDb(y, x, 96000 + 4776, 96000 + 4824), closeTo(-5.03, 0.7));
      expect(gainDb(y, x, 96000 + 14400, 96000 + 24000), closeTo(0, 0.05));
    });

    test('a sidechain keys the gain: the input ducks while the key plays', () {
      final x = stairs([-12, -12, -12], 1);
      final key = Float32List(x.length);
      // Gaussian noise of RMS 0.25, as the oracle's key.
      final rnd = math.Random(1);
      for (var i = 48000; i < 96000; i++) {
        final v =
            0.25 *
            math.sqrt(-2 * math.log(1 - rnd.nextDouble())) *
            math.cos(2 * math.pi * rnd.nextDouble());
        key[i * 2] = v;
        key[i * 2 + 1] = v;
      }
      final y = copy(x);
      final c = comp(-30, 2.5, 20, 200)..useSidechain = true;
      c.sidechain = key;
      c.process(y, y.length ~/ 2);
      expect(gainDb(y, x, 24000, 47000), closeTo(0, 0.05));
      expect(gainDb(y, x, 96000 - 2400, 96000), closeTo(-15.05, 0.6));
    });
  });

  group('limiter (dsp 11)', () {
    test('holds the peak at the ceiling, releases at 8.686 dB per release '
        'time', () {
      final x = stairs([-12, 6, -12], 1);
      final y = copy(x);
      Limiter()
        ..set(0, 5)
        ..set(1, -2)
        ..set(2, 0)
        ..process(y, y.length ~/ 2);
      var peak = 0.0;
      for (var i = 48000; i < 96000; i++) {
        peak = math.max(peak, y[i * 2].abs());
      }
      expect(20 * math.log(peak) / math.ln10, closeTo(-2, 0.01));
      expect(gainDb(y, x, 96000 + 48, 96000 + 96), closeTo(-4.94, 0.4));
      expect(gainDb(y, x, 96000 + 480, 96000 + 960), closeTo(0, 0.05));
    });
    test('a new limiter starts at the ceiling\'s gain', () {
      final y = Float32List.fromList([0.1, 0.1]);
      Limiter()
        ..set(0, 100)
        ..set(1, -2)
        ..process(y, 1);
      expect(y[0], closeTo(0.1 * math.pow(10, -2 / 20), 1e-4));
    });
  });

  group('SFX reverb (dsp 19): measured statistics', () {
    Float32List impulse(List<double> p, {int seconds = 4}) {
      final r = Reverb();
      for (final (i, v) in p.indexed) {
        r.set(i, v);
      }
      final buf = Float32List(seconds * fs * 2);
      buf[0] = 1;
      buf[1] = 1;
      r.process(buf, seconds * fs);
      return buf;
    }

    int onset(Float32List h) {
      for (var i = 0; i < h.length ~/ 2; i++) {
        if (h[i * 2].abs() > 1e-3) return i;
      }
      return -1;
    }

    double energyDb(Float32List h) {
      var s = 0.0;
      for (var i = 0; i < h.length ~/ 2; i++) {
        s += h[i * 2] * h[i * 2];
      }
      return 10 * math.log(s) / math.ln10;
    }

    /// Broadband RT60 from the Schroeder curve (−5 to −25 dB).
    double rt60(Float32List h) {
      final n = h.length ~/ 2;
      final e = List.filled(n + 1, 0.0);
      for (var i = n - 1; i >= 0; i--) {
        e[i] = e[i + 1] + h[i * 2] * h[i * 2];
      }
      int at(double db) {
        for (var i = 0; i < n; i++) {
          if (10 * math.log(e[i] / e[0]) / math.ln10 < db) return i;
        }
        return n;
      }

      return 60 * (at(-25) - at(-5)) / 20 / fs;
    }

    const late = <double>[
      1500.0,
      20,
      40,
      5000,
      100,
      100,
      100,
      250,
      0,
      20000,
      100,
      0,
      -80,
    ];
    test('late only: starts at early + late delay, decays at DecayTime', () {
      final h = impulse(late);
      expect(onset(h) / 48, closeTo(61.5, 2));
      expect(rt60(h), closeTo(1.49, 0.15));
      expect(energyDb(h), closeTo(4.5, 1));
    });
    test('early only: starts at the early delay, same energy', () {
      final p = [...late]..[10] = 0;
      final h = impulse(p);
      expect(onset(h) / 48, closeTo(20, 1));
      expect(energyDb(h), closeTo(4.5, 1));
    });
    test('decay 3000 ms decays twice as slowly', () {
      final p = [...late]..[0] = 3000;
      expect(rt60(impulse(p, seconds: 6)), closeTo(3.0, 0.3));
    });
    test('jesseTreehouse\'s room: energy and 50 ms envelope as measured', () {
      const jt = <double>[
        170,
        12.5,
        11.5,
        1550,
        43,
        30,
        46.5,
        280,
        -12.5,
        7500,
        37,
        -0.5,
        -80,
      ];
      final h = impulse(jt, seconds: 1);
      expect(onset(h) / 48, closeTo(12.5, 0.5));
      expect(energyDb(h), closeTo(-0.02, 1.5));
      const oracle = [-35.7, -38.5, -53.8, -79.1];
      for (var k = 0; k < oracle.length; k++) {
        var e = 0.0;
        for (var i = k * 2400; i < (k + 1) * 2400; i++) {
          e += h[i * 2] * h[i * 2];
        }
        expect(
          10 * math.log(e / 2400) / math.ln10,
          closeTo(oracle[k], 3),
          reason: 'window $k',
        );
      }
    });
    test('dry 0 dB, wet −80 dB is the input', () {
      final p = [...late]
        ..[11] = -80
        ..[12] = 0;
      final h = impulse(p, seconds: 1);
      expect(h[0], closeTo(1, 1e-6));
      expect(energyDb(h), closeTo(0, 0.01));
    });
  });

  test('tremolo (dsp 22) defaults: a 5 Hz triangle from 0 to 1', () {
    final t = Tremolo()
      ..set(0, 5)
      ..set(1, 1);
    final buf = Float32List(9600 * 2)..fillRange(0, 19200, 1);
    t.process(buf, 9600);
    expect(buf[0], closeTo(0, 0.01));
    expect(buf[4800 * 2], closeTo(1, 0.01));
    expect(buf[2400 * 2], closeTo(0.5, 0.01));
  });

  test('tremolo duty ≥ 0.5 is a trapezoid; spread offsets L/R by ±spread/4 '
      '(O: 0.1 Hz, depth 0.48, duty 0.765, spread 0.38)', () {
    final t = Tremolo()
      ..set(0, 0.1)
      ..set(1, 0.48)
      ..set(4, 0.765)
      ..set(7, 0.38);
    const n = 48000 * 11;
    final buf = Float32List(n * 2)..fillRange(0, n * 2, 1);
    t.process(buf, n);
    double at(int ch, double s) {
      var sum = 0.0;
      final a = (s * 48000).round();
      for (var i = a; i < a + 4800; i++) {
        sum += buf[i * 2 + ch];
      }
      return sum / 4800;
    }

    // The oracle's 100 ms windows (left, right).
    final left = {0.0: 0.718, 1.0: 0.929, 3.0: 1.0, 7.0: 0.929, 9.0: 0.525};
    final right = {0.0: 0.697, 0.9: 0.525, 2.0: 0.745, 5.0: 1.0};
    for (final MapEntry(:key, :value) in left.entries) {
      expect(at(0, key), closeTo(value, 0.02), reason: 'L $key s');
    }
    for (final MapEntry(:key, :value) in right.entries) {
      expect(at(1, key), closeTo(value, 0.02), reason: 'R $key s');
    }
  });

  group('oracle-measured effects (fmod.dll 1.06.02 on our test signals)', () {
    Float32List impulse(int n, {int at = 0, double v = 0.5}) =>
        Float32List(n * 2)
          ..[at * 2] = v
          ..[at * 2 + 1] = v;

    test('echo: taps every delay·48 samples, each feedback × the last; dry '
        'and wet in dB', () {
      final e = Echo()
        ..set(0, 37)
        ..set(1, 30)
        ..set(2, -6)
        ..set(3, -12);
      final b = impulse(6000);
      e.process(b, 6000);
      // The oracle's samples (16-bit): 0.25058, 0.12561, 0.03769.
      expect(b[0], closeTo(0.25058, 4e-5));
      expect(b[1776 * 2], closeTo(0.12561, 4e-5));
      expect(b[3552 * 2], closeTo(0.03769, 4e-5));
      expect(b[1775 * 2], 0);
    });

    test('echo keeps its strip awake while its line holds sound', () {
      final e = Echo()
        ..set(0, 100)
        ..set(1, 0);
      e.process(impulse(1024), 1024);
      expect(e.ringing, isTrue);
      final silence = Float32List(2048 * 2);
      e.process(silence, 2048);
      e.process(Float32List(4800 * 2), 4800);
      expect(e.ringing, isFalse);
    });

    test('highpass: one RBJ biquad, Q = resonance (oracle at 500 Hz)', () {
      final h = Highpass()
        ..set(0, 500)
        ..set(1, 1);
      final b = impulse(4);
      h.process(b, 4);
      expect(b[0], closeTo(0.48364, 4e-5));
    });

    test('parameq: the centre moves by twice the gain (A = 10^(g/20)), Q = '
        '1/bandwidth', () {
      final q = ParamEq()
        ..set(0, 1000)
        ..set(1, 1)
        ..set(2, 6);
      const n = 48000;
      final b = Float32List(n * 2);
      for (var i = 0; i < n; i++) {
        b[i * 2] = b[i * 2 + 1] =
            0.1 * math.sin(2 * math.pi * 1000 * i / 48000);
      }
      q.process(b, n);
      var peak = 0.0;
      for (var i = n ~/ 2; i < n; i++) {
        peak = math.max(peak, b[i * 2].abs());
      }
      expect(20 * math.log(peak / 0.1) / math.ln10, closeTo(12, 0.05));
      // The oracle's first impulse sample: 0.5 × 1.0944.
      final i = ParamEq()
        ..set(0, 1000)
        ..set(1, 1)
        ..set(2, 6);
      final b2 = impulse(2);
      i.process(b2, 2);
      expect(b2[0], closeTo(0.54721, 4e-5));
    });

    test('distortion: (1 + k)x / (1 + k|x|), k = 2·level/(1 − level)', () {
      final d = Distortion()..set(0, 0.5);
      final b = Float32List.fromList([0.1, 0.25, 0.5, 0.75]);
      d.process(b, 2);
      expect(b, [
        closeTo(0.25, 1e-6),
        closeTo(0.5, 1e-6),
        closeTo(0.75, 1e-6),
        closeTo(0.9, 1e-6),
      ]);
    });

    test('flange: (1 − mix)·dry + mix·the input 480·(1 − cos 2πφ) samples '
        'back; depth changes nothing', () {
      Float32List run(double depth) {
        final f = Flange()
          ..set(0, 50)
          ..set(1, depth)
          ..set(2, 1);
        final b = impulse(6000, at: 4800);
        f.process(b, 6000);
        return b;
      }

      final b = run(1);
      // The oracle: 0.25 dry, then taps 95: 0.20642 and 96: 0.05734.
      expect(b[4800 * 2], closeTo(0.25, 1e-6));
      // Its interpolated delay is 95.217 samples; ours lands within 0.02
      // (the oracle's two taps sum 2 % over linear interpolation here).
      final a = b[4895 * 2], c = b[4896 * 2];
      expect(95 + c / (a + c), closeTo(95.217, 0.02));
      expect(a + c, closeTo(0.2638, 0.006));
      expect(run(0.05), b);
    });
  });
}
