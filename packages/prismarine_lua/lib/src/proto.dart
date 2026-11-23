// Function prototypes (lobject.h `Proto`), as undumped or compiled.

import 'dart:typed_data';

import 'table.dart' show luaHashSeed, luaStringHash;

/// An upvalue descriptor: captured from the enclosing function's registers
/// ([inStack]) or from its upvalues, at [index].
class UpvalDesc {
  UpvalDesc(this.inStack, this.index, [this.name]);
  final bool inStack;
  final int index;
  String? name;
}

/// A local variable's name and the pc range it is active in.
class LocVar {
  LocVar(this.name, this.startPc, this.endPc);
  final String? name;
  final int startPc;
  final int endPc;
}

/// One String object per distinct constant text across loaded chunks
/// (perf: a table key and a later lookup by the same constant are then
/// the same object, so the key compare is an identity test; Lua can't tell
/// equal strings apart).
String internConstant(String s) => _interned.putIfAbsent(s, () => s);
final _interned = <String, String>{};

class LuaProto {
  LuaProto({
    required this.lineDefined,
    required this.lastLineDefined,
    required this.numParams,
    required this.isVararg,
    required this.maxStackSize,
    required this.code,
    required this.constants,
    required this.protos,
    required this.upvalues,
    required this.source,
    required this.lineInfo,
    required this.locVars,
    this.varargFlags,
  });

  final int lineDefined;
  final int lastLineDefined;
  final int numParams;

  /// `is_vararg != 0`. [varargFlags] keeps the raw byte (5.2 compilers write
  /// 1) so a re-dump is exact.
  final bool isVararg;
  final int? varargFlags;
  final int maxStackSize;
  final Uint32List code;

  /// nil, bool, double (float32 value) or String.
  final List<Object?> constants;

  /// Each String constant's Lua hash (`luaStringHash`, the fixed seed), 0
  /// for the rest: table reads by a constant key skip hashing it (perf).
  late final Int32List constHash = Int32List.fromList([
    for (final k in constants) k is String ? luaStringHash(k, luaHashSeed) : 0,
  ]);
  final List<LuaProto> protos;
  final List<UpvalDesc> upvalues;
  final String? source;
  final Int32List lineInfo;
  final List<LocVar> locVars;

  /// The 5.2.3 closure cache (lvm.c `getcached`/`pushclosure`), set by the
  /// VM.
  Object? cache;

  /// The chunk this prototype was loaded from and its place in the chunk's
  /// prototypes (pre-order): a snapshot names a prototype so and loads the
  /// chunk again.
  LuaChunk? chunk;
  int chunkIndex = 0;

  /// The line of instruction [pc], or 0 without debug info.
  int lineAt(int pc) => pc < lineInfo.length ? lineInfo[pc] : 0;

  /// `luaF_getlocalname`: the name of the [n]-th (1-based) local active at
  /// [pc], or null.
  String? localName(int n, int pc) {
    for (final v in locVars) {
      if (v.startPc > pc) break;
      if (pc < v.endPc) {
        n--;
        if (n == 0) return v.name;
      }
    }
    return null;
  }
}

/// A loaded chunk: its name and bytes (as `lua_load` got them) and its
/// prototypes in pre-order (the main function first).
class LuaChunk {
  LuaChunk(this.name, this.bytes, LuaProto main) {
    void walk(LuaProto p) {
      p
        ..chunk = this
        ..chunkIndex = protos.length;
      protos.add(p);
      p.protos.forEach(walk);
    }

    walk(main);
  }

  final String name;
  final Uint8List bytes;
  final protos = <LuaProto>[];

  /// Whether [bytes] are the host's resource of [name] (a snapshot then
  /// names the resource instead of carrying the bytes); found once.
  bool? fromHost;
}

/// A chunk that cannot be loaded (`LUA_ERRSYNTAX`): bad or truncated
/// precompiled chunks, and later syntax errors.
class LuaLoadError implements Exception {
  LuaLoadError(this.message);
  final String message;
  @override
  String toString() => message;
}
