import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';

/// Stock Lua 5.2.3 built with float numbers, a 32-bit `lua_Integer` and a
/// 4-byte `size_t`, the build that made the test corpus. [single] selects
/// the float32Single mode.
class FloatConfig with LuaConfig {
  const FloatConfig({this.single = false});
  final bool single;

  @override
  LuaNumberMode get numberMode =>
      single ? LuaNumberMode.float32Single : LuaNumberMode.float32;

  @override
  bool get integer64 => false;

  @override
  int get chunkSizeT => 4;
}

const floatConfig = FloatConfig();

/// Reads a chunk of the corpus build.
LuaProto undumpFloat(Uint8List bytes, String name, {int sizeT = 4}) =>
    undumpLua(bytes, name, sizeT: sizeT, float32: true);

/// Writes a chunk in the layout of the corpus build.
Uint8List dumpFloat(LuaProto p) => dumpLua(p, sizeT: 4, float32: true);
