import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:test/test.dart';
import 'support/float_config.dart';

void main() {
  final goldens = Directory('test/corpus/golden')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.luac'))
      .toList();

  test('every fixture of the reference build re-dumps byte-identically', () {
    expect(goldens, isNotEmpty);
    for (final f in goldens) {
      final bytes = f.readAsBytesSync();
      final p = undumpFloat(bytes, '@${f.path}');
      expect(dumpFloat(p), bytes, reason: f.path);
    }
  });

  test('protos carry code, constants and debug info', () {
    final bytes = File('test/corpus/golden/tbl_len.luac').readAsBytesSync();
    final p = undumpFloat(bytes, '=x');
    expect(p.source, '@tbl_len.lua');
    expect(p.isVararg, isTrue);
    expect(p.upvalues.single.name, '_ENV');
    expect(p.upvalues.single.inStack, isTrue);
    expect(p.lineInfo.length, p.code.length);
    expect(opOf(p.code.last), Op.RETURN);
    expect(p.constants, contains(200.0));
    expect(p.locVars.first.name, 't');
  });

  test('stock undump errors', () {
    final good = File('test/corpus/golden/tbl_len.luac').readAsBytesSync();
    Matcher err(String m) =>
        throwsA(isA<LuaLoadError>().having((e) => e.message, 'message', m));
    expect(
      () => undumpFloat(Uint8List.sublistView(good, 0, 40), '@f.lua'),
      err('f.lua: truncated precompiled chunk'),
    );
    final badSig = Uint8List.fromList(good)..[1] = 0x58;
    expect(
      () => undumpFloat(badSig, '=lit'),
      err('lit: not a precompiled chunk'),
    );
    final badVer = Uint8List.fromList(good)..[4] = 0x51;
    expect(
      () => undumpFloat(badVer, 'name'),
      err('name: version mismatch in precompiled chunk'),
    );
    final badSize = Uint8List.fromList(good)..[10] = 8;
    expect(
      () => undumpFloat(badSize, '\x1bLua'),
      err('binary string: incompatible precompiled chunk'),
    );
    final badTail = Uint8List.fromList(good)..[17] = 0;
    expect(
      () => undumpFloat(badTail, '@f'),
      err('f: corrupted precompiled chunk'),
    );
  });

  test('instruction fields (lopcodes.h)', () {
    // LOADK A=3 Bx=70000; EQ A=1 B=K(5) C=2; JMP sBx=-2
    final loadk = Op.LOADK | (3 << 6) | (70000 << 14);
    expect(opOf(loadk), Op.LOADK);
    expect(argA(loadk), 3);
    expect(argBx(loadk), 70000);
    final eq = Op.EQ | (1 << 6) | ((0x100 | 5) << 23) | (2 << 14);
    expect(argB(eq), 0x105);
    expect(isK(argB(eq)), isTrue);
    expect(indexK(argB(eq)), 5);
    expect(argC(eq), 2);
    final jmp = Op.JMP | ((131071 - 2) << 14);
    expect(argSBx(jmp), -2);
    expect(opNames[Op.TFORLOOP], 'TFORLOOP');
  });
}
