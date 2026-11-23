import 'proto.dart';

/// Compiles Lua source text into a prototype. A VM without a compiler loads
/// binary chunks only. `prismarine_lua_native` has the compiler of stock Lua
/// 5.2.3.
abstract interface class LuaCompiler {
  /// Returns the main function of [source], whose code units are bytes, as
  /// the chunk [chunkName]. Throws [LuaLoadError] with Lua's message on a
  /// syntax error.
  LuaProto compile(String source, String chunkName);
}
