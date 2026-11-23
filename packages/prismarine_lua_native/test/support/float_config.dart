import 'package:prismarine_lua/prismarine_lua.dart';

/// Stock Lua 5.2.3 built with float numbers, a 32-bit `lua_Integer` and a
/// 4-byte `size_t`, the build that made the test corpus of prismarine_lua.
class FloatConfig with LuaConfig {
  const FloatConfig();

  @override
  LuaNumberMode get numberMode => LuaNumberMode.float32;

  @override
  bool get integer64 => false;

  @override
  int get chunkSizeT => 4;
}
