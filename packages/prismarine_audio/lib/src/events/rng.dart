/// A small deterministic generator (mulberry32: 32-bit arithmetic only, so it
/// gives the same sequence on every platform).
class Rng {
  Rng(int seed) : _s = seed & 0xffffffff;
  int _s;

  /// The next value in [0, 1).
  double next() {
    _s = (_s + 0x6d2b79f5) & 0xffffffff;
    var t = _s;
    t = _imul(t ^ (t >>> 15), t | 1);
    t ^= (t + _imul(t ^ (t >>> 7), t | 61)) & 0xffffffff;
    return ((t ^ (t >>> 14)) & 0xffffffff) / 4294967296.0;
  }

  /// Uniform in [lo, hi].
  double range(double lo, double hi) => lo + (hi - lo) * next();

  static int _imul(int a, int b) {
    final ah = (a >>> 16) & 0xffff, al = a & 0xffff;
    final bh = (b >>> 16) & 0xffff, bl = b & 0xffff;
    return (al * bl + (((ah * bl + al * bh) << 16) & 0xffffffff)) & 0xffffffff;
  }
}
