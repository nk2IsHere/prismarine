// Ported from Lua 5.2.3 lundump.c and ldump.c (MIT, see LICENSE-lua).

import 'dart:typed_data';

import 'opcodes.dart';
import 'proto.dart';

/// `luaU_header` for a `size_t` of [sizeT] bytes and float numbers when
/// [float32], else doubles. The header has the signature, version 5.2,
/// format 0, little endian, a 4-byte `int` and instruction, no integral
/// numbers and LUAC_TAIL.
List<int> luaHeader({int sizeT = 8, bool float32 = false}) => [
  0x1B, 0x4C, 0x75, 0x61, 0x52, 0x00, 0x01, 0x04, sizeT, 0x04, //
  float32 ? 4 : 8, 0x00, 0x19, 0x93, 0x0D, 0x0A, 0x1A, 0x0A,
];

class _Loader {
  _Loader(this.b, this.name, this.sizeT, this.float32)
    : bd = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData bd;
  final String name;
  final int sizeT;
  final bool float32;
  int pos = 0;

  Never error(String why) =>
      throw LuaLoadError('$name: $why precompiled chunk');

  void need(int n) {
    if (pos + n > b.length) error('truncated');
  }

  int byte() {
    need(1);
    return b[pos++];
  }

  int int32() {
    need(4);
    final x = bd.getInt32(pos, Endian.little);
    pos += 4;
    if (x < 0) error('corrupted');
    return x;
  }

  double number() {
    if (!float32) {
      need(8);
      final x = bd.getFloat64(pos, Endian.little);
      pos += 8;
      return x;
    }
    need(4);
    final x = bd.getFloat32(pos, Endian.little);
    pos += 4;
    return x;
  }

  String? string() {
    need(sizeT);
    final size = sizeT == 8
        ? bd.getUint64(pos, Endian.little)
        : bd.getUint32(pos, Endian.little);
    pos += sizeT;
    if (size == 0) return null;
    need(size);
    final s = String.fromCharCodes(b, pos, pos + size - 1);
    pos += size;
    return s;
  }

  void header() {
    final h = luaHeader(sizeT: sizeT, float32: float32);
    need(1);
    // The loader has already seen the first byte, LUA_SIGNATURE[0].
    final got = List<int>.filled(h.length, 0)..[0] = h[0];
    pos = 1;
    for (var i = 1; i < h.length; i++) {
      got[i] = byte();
    }
    bool same(int n) {
      for (var i = 0; i < n; i++) {
        if (got[i] != h[i]) return false;
      }
      return true;
    }

    if (same(18)) return;
    if (!same(4)) error('not a');
    if (!same(6)) error('version mismatch in');
    if (!same(12)) error('incompatible');
    error('corrupted');
  }

  LuaProto function() {
    final lineDefined = int32();
    final lastLineDefined = int32();
    final numParams = byte();
    final vararg = byte();
    final maxStack = byte();
    final ncode = int32();
    need(ncode * 4);
    final code = Uint32List(ncode);
    for (var i = 0; i < ncode; i++) {
      code[i] = bd.getUint32(pos, Endian.little);
      pos += 4;
    }
    final nk = int32();
    final constants = List<Object?>.filled(nk, null);
    for (var i = 0; i < nk; i++) {
      final t = byte();
      constants[i] = switch (t) {
        0 => null,
        1 => byte() != 0,
        3 => number(),
        4 => switch (string()) {
          final String s => internConstant(s),
          null => null,
        },
        _ => error('corrupted'),
      };
    }
    final np = int32();
    final protos = [for (var i = 0; i < np; i++) function()];
    final nu = int32();
    final upvalues = <UpvalDesc>[];
    for (var i = 0; i < nu; i++) {
      final inStack = byte();
      upvalues.add(UpvalDesc(inStack != 0, byte()));
    }
    final source = string();
    final nl = int32();
    need(nl * 4);
    final lineInfo = Int32List(nl);
    for (var i = 0; i < nl; i++) {
      lineInfo[i] = bd.getInt32(pos, Endian.little);
      pos += 4;
    }
    final nv = int32();
    final locVars = <LocVar>[];
    for (var i = 0; i < nv; i++) {
      locVars.add(LocVar(string(), int32(), int32()));
    }
    final nn = int32();
    for (var i = 0; i < nn; i++) {
      final name = string();
      if (i < upvalues.length) upvalues[i].name = name;
    }
    return LuaProto(
      lineDefined: lineDefined,
      lastLineDefined: lastLineDefined,
      numParams: numParams,
      isVararg: vararg != 0,
      varargFlags: vararg,
      maxStackSize: maxStack,
      code: code,
      constants: constants,
      protos: protos,
      upvalues: upvalues,
      source: source,
      lineInfo: lineInfo,
      locVars: locVars,
    );
  }
}

/// `luaU_undump`. Returns the main function of a binary chunk with a
/// `size_t` of [sizeT] bytes and float numbers when [float32]. [chunkName]
/// is the name that `load` got. An error message gives "x" for "@x" and
/// "=x", and "binary string" for a binary string.
LuaProto undumpLua(
  Uint8List bytes,
  String chunkName, {
  int sizeT = 8,
  bool float32 = false,
}) {
  final name = chunkName.startsWith('@') || chunkName.startsWith('=')
      ? chunkName.substring(1)
      : chunkName.startsWith('\x1b')
      ? 'binary string'
      : chunkName;
  final l = _Loader(bytes, name, sizeT, float32)..header();
  return l.function();
}

class _Dumper {
  _Dumper(this.sizeT, this.float32);
  final int sizeT;
  final bool float32;
  final out = BytesBuilder(copy: false);
  final _w = ByteData(8);

  void byte(int x) => out.addByte(x & 0xFF);
  void _emit(int n) => out.add(Uint8List.fromList(_w.buffer.asUint8List(0, n)));

  void int32(int x) {
    _w.setInt32(0, x, Endian.little);
    _emit(4);
  }

  void uint32(int x) {
    _w.setUint32(0, x, Endian.little);
    _emit(4);
  }

  void size(int x) {
    if (sizeT == 4) return uint32(x);
    _w.setUint64(0, x, Endian.little);
    _emit(8);
  }

  void number(double x) {
    if (float32) {
      _w.setFloat32(0, x, Endian.little);
      _emit(4);
    } else {
      _w.setFloat64(0, x, Endian.little);
      _emit(8);
    }
  }

  void string(String? s) {
    if (s == null) {
      size(0);
      return;
    }
    size(s.length + 1);
    out.add(Uint8List.fromList(s.codeUnits));
    out.addByte(0);
  }

  void function(LuaProto f) {
    int32(f.lineDefined);
    int32(f.lastLineDefined);
    byte(f.numParams);
    byte(f.varargFlags ?? (f.isVararg ? 1 : 0));
    byte(f.maxStackSize);
    int32(f.code.length);
    for (final i in f.code) {
      uint32((i & ~0x3F) | opOf(i));
    }
    int32(f.constants.length);
    for (final k in f.constants) {
      switch (k) {
        case null:
          byte(0);
        case final bool b:
          byte(1);
          byte(b ? 1 : 0);
        case final double d:
          byte(3);
          number(d);
        case final String s:
          byte(4);
          string(s);
        default:
          throw StateError('bad constant ${k.runtimeType}');
      }
    }
    int32(f.protos.length);
    for (final p in f.protos) {
      function(p);
    }
    int32(f.upvalues.length);
    for (final u in f.upvalues) {
      byte(u.inStack ? 1 : 0);
      byte(u.index);
    }
    string(f.source);
    int32(f.lineInfo.length);
    for (final l in f.lineInfo) {
      int32(l);
    }
    int32(f.locVars.length);
    for (final v in f.locVars) {
      string(v.name);
      int32(v.startPc);
      int32(v.endPc);
    }
    int32(f.upvalues.length);
    for (final u in f.upvalues) {
      string(u.name);
    }
  }
}

/// `luaU_dump` without stripping. Returns the chunk of [main] with a
/// `size_t` of [sizeT] bytes and float numbers when [float32]. A specialised
/// opcode is written as its standard one.
Uint8List dumpLua(LuaProto main, {int sizeT = 8, bool float32 = false}) {
  final d = _Dumper(sizeT, float32);
  for (final b in luaHeader(sizeT: sizeT, float32: float32)) {
    d.byte(b);
  }
  d.function(main);
  return d.out.takeBytes();
}
