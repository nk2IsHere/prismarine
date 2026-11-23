import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:prismarine_lua_native/prismarine_lua_native.dart';
import 'package:test/test.dart';

void main() {
  test('the float32 build compiles text to a float-number chunk', () {
    final (status, bytes) = compileRaw(
      'return 0.1 + 16777217'.codeUnits,
      '=t'.codeUnits,
      float32: true,
    );
    expect(status, 0);
    expect(bytes.sublist(0, 4), [0x1B, 0x4C, 0x75, 0x61]);
    expect(bytes[10], 4, reason: 'sizeof(lua_Number)');
    expect(bytes[11], 0, reason: 'not integral');
  });

  test('returns the 5.2.3 syntax error text', () {
    final (status, bytes) = compileRaw('x = = 1'.codeUnits, '=t'.codeUnits);
    expect(status, 1);
    expect(String.fromCharCodes(bytes), "t:1: unexpected symbol near '='");
  });

  test('source and chunk names must be byte strings (code units <= 255)', () {
    expect(
      () => const NativeLuaCompiler().compile('x = "\u013d"', '=y'),
      throwsArgumentError,
    );
    expect(
      () => const NativeLuaCompiler().compile('x = 1', '=\u2019'),
      throwsArgumentError,
    );
    expect(
      const NativeLuaCompiler().compile('x = "\u00e9"', '=y'),
      isA<LuaProto>(),
    );
  });

  test('the double build compiles text to a double chunk', () {
    final (status, bytes) = compileRaw(
      'return 0.1 + 16777217'.codeUnits,
      '=t'.codeUnits,
    );
    expect(status, 0);
    expect(bytes[10], 8, reason: 'sizeof(lua_Number)');
    final p = const NativeLuaCompiler().compile('return 0.1 + 16777217', '=t');
    expect(p.constants, contains(0.1 + 16777217));
  });
}
