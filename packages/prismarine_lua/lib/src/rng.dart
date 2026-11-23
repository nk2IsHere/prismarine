// Marsaglia's xorshift128 generator on four 32-bit words.

class LuaRng {
  LuaRng() {
    reset();
  }

  int x = 0, y = 0, z = 0, w = 0;

  /// Restores the default state.
  void reset() {
    x = 123456789;
    y = 362436069;
    z = 521288629;
    w = 88675123;
  }

  /// Seeds the generator with [a] to [d]. An argument of 0 is derived from
  /// [a].
  void seed(int a, [int b = 0, int c = 0, int d = 0]) {
    a &= 0xFFFFFFFF;
    x = a;
    y = b != 0 ? b & 0xFFFFFFFF : (a * a) & 0xFFFFFFFF;
    z = c != 0 ? c & 0xFFFFFFFF : (y * a) & 0xFFFFFFFF;
    w = d != 0 ? d & 0xFFFFFFFF : (z * a) & 0xFFFFFFFF;
  }

  /// Returns the next 32-bit value.
  int next() {
    final t = (x ^ (x << 11)) & 0xFFFFFFFF;
    x = y;
    y = z;
    z = w;
    w = (w ^ (w >> 19) ^ t ^ (t >> 8)) & 0xFFFFFFFF;
    return w;
  }
}
