import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';

import 'raw.dart';

/// [LuaCompiler] backed by stock Lua 5.2.3 (configured like GameApp.exe),
/// compiled into this package's native library.
class NativeLuaCompiler implements LuaCompiler {
  const NativeLuaCompiler();

  @override
  LuaProto compile(String source, String chunkName) {
    final (status, bytes) = compileRaw(source.codeUnits, chunkName.codeUnits);
    if (status != 0) {
      throw LuaLoadError(
        status == 4 ? 'not enough memory' : String.fromCharCodes(bytes),
      );
    }
    // Host layout: 8-byte size_t on 64-bit hosts, 4 on 32-bit.
    final sizeT = bytes.length > 8 ? bytes[8] : 8;
    return undumpChunk(Uint8List.fromList(bytes), chunkName, sizeT: sizeT);
  }
}
