import 'proto.dart';

/// Compiles Lua source text (Script nodes, visibility conditions, `DoString`,
/// `.lua` scripts). The implementation is stock Lua 5.2.3's own compiler
/// (mcsm_lua_native); `mcsm_lua` itself only runs bytecode.
abstract interface class LuaCompiler {
  /// The main function of [source] (bytes as code units) named [chunkName].
  /// Throws [LuaLoadError] with Lua's message on a syntax error.
  LuaProto compile(String source, String chunkName);
}
