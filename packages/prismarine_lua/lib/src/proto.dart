// Function prototypes, the `Proto` of lobject.h, as a chunk or the compiler
// gives them.

import 'dart:typed_data';

import 'table.dart' show luaHashSeed, luaStringHash;

/// An upvalue descriptor. The upvalue is the register [index] of the
/// enclosing function when [inStack], else its upvalue [index].
class UpvalDesc {
  UpvalDesc(this.inStack, this.index, [this.name]);
  final bool inStack;
  final int index;
  String? name;
}

/// The name of a local variable and the range of instructions in which it is
/// active.
class LocVar {
  LocVar(this.name, this.startPc, this.endPc);
  final String? name;
  final int startPc;
  final int endPc;
}

/// Returns one String object for each constant text of the loaded chunks. A
/// table key and a later lookup by the same constant are then the same
/// object, and the key compare is an identity test.
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

  /// `is_vararg != 0`. [varargFlags] keeps the raw byte for an exact dump.
  final bool isVararg;
  final int? varargFlags;
  final int maxStackSize;
  final Uint32List code;

  /// Each constant is nil, a bool, a double or a String.
  final List<Object?> constants;

  /// The [luaStringHash] of each String constant with the fixed seed, and 0
  /// for the other constants. A table read by a constant key takes it.
  late final Int32List constHash = Int32List.fromList([
    for (final k in constants) k is String ? luaStringHash(k, luaHashSeed) : 0,
  ]);
  final List<LuaProto> protos;
  final List<UpvalDesc> upvalues;
  final String? source;
  final Int32List lineInfo;
  final List<LocVar> locVars;

  /// The closure cache of `getcached` and `pushclosure` in lvm.c.
  Object? cache;

  /// The chunk of this prototype and its index among the prototypes of the
  /// chunk in pre-order. A snapshot writes a prototype as both and loads the
  /// chunk again.
  LuaChunk? chunk;
  int chunkIndex = 0;

  /// The line of instruction [pc], or 0 without debug info.
  int lineAt(int pc) => pc < lineInfo.length ? lineInfo[pc] : 0;

  /// `luaF_getlocalname`. Returns the name of the local [n], counted from 1,
  /// that is active at [pc], or null.
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

/// A loaded chunk with the name and bytes that `lua_load` got and its
/// prototypes in pre-order, the main function first.
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

  /// True when [bytes] are the resource [name] of the host. A snapshot then
  /// refers to the resource and does not carry the bytes. Found once.
  bool? fromHost;
}

/// A chunk that does not load, `LUA_ERRSYNTAX`, such as a truncated binary
/// chunk or source with a syntax error.
class LuaLoadError implements Exception {
  LuaLoadError(this.message);
  final String message;
  @override
  String toString() => message;
}
