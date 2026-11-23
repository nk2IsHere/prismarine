import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';

import 'raw.dart';

/// A [LuaCompiler] with the compiler of stock Lua 5.2.3 in this package's
/// native libraries. The double build serves the float64 mode and the
/// float32 build serves both float32 modes. Give it the [mode] of the VM.
class NativeLuaCompiler implements LuaCompiler {
  const NativeLuaCompiler({this.mode = LuaNumberMode.float64});

  final LuaNumberMode mode;

  @override
  LuaProto compile(String source, String chunkName) {
    final float32 = mode.isFloat32;
    final (status, bytes) = compileRaw(
      source.codeUnits,
      chunkName.codeUnits,
      float32: float32,
    );
    if (status != 0) {
      throw LuaLoadError(
        status == 4 ? 'not enough memory' : String.fromCharCodes(bytes),
      );
    }
    // The layout of the host has an 8-byte size_t on a 64-bit host.
    final sizeT = bytes.length > 8 ? bytes[8] : 8;
    return undumpLua(
      Uint8List.fromList(bytes),
      chunkName,
      sizeT: sizeT,
      float32: float32,
    );
  }
}
