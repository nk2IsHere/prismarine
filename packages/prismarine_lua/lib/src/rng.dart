// GameApp.exe's random generator: Marsaglia's xorshift128 on four uint32s
// (see formats/telltale/lua-runtime.md, "The engine generator").

class LuaRng {
  LuaRng() {
    reset();
  }

  int x = 0, y = 0, z = 0, w = 0;

  /// The default state.
  void reset() {
    x = 123456789;
    y = 362436069;
    z = 521288629;
    w = 88675123;
  }

  /// Seed(a, b, c, d): a zero argument is derived from `a`.
  void seed(int a, [int b = 0, int c = 0, int d = 0]) {
    a &= 0xFFFFFFFF;
    x = a;
    y = b != 0 ? b & 0xFFFFFFFF : (a * a) & 0xFFFFFFFF;
    z = c != 0 ? c & 0xFFFFFFFF : (y * a) & 0xFFFFFFFF;
    w = d != 0 ? d & 0xFFFFFFFF : (z * a) & 0xFFFFFFFF;
  }

  /// Step: the next uint32.
  int next() {
    final t = (x ^ (x << 11)) & 0xFFFFFFFF;
    x = y;
    y = z;
    z = w;
    w = (w ^ (w >> 19) ^ t ^ (t >> 8)) & 0xFFFFFFFF;
    return w;
  }
}
