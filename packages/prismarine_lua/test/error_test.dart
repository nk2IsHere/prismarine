import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:test/test.dart';

void main() {
  test('luaO_chunkid (LUA_IDSIZE 60)', () {
    expect(chunkId('=stdin'), 'stdin');
    expect(chunkId('=${'x' * 70}'), 'x' * 59);
    expect(chunkId('@file.lua'), 'file.lua');
    expect(
      chunkId('@${'d/' * 40}f.lua'),
      '...${('d/' * 40 + 'f.lua').substring(85 - 56)}',
    );
    expect(chunkId('return 1'), '[string "return 1"]');
    expect(chunkId('line1\nline2'), '[string "line1..."]');
    expect(chunkId('y' * 50), '[string "${'y' * 45}..."]');
  });

  test('a native argument error names the call site (luaL_argerror)', () {
    final vm = LuaVm(config: LuaProfile.stock);
    final fns = vm.call(
      vm.load(File('test/fixtures/multi.luac').readAsBytesSync(), '@multi.lua'),
      const [],
    );
    final needsNumber = LuaNative((L) {
      L.checkNumber(1);
      return 0;
    });
    expect(
      () => vm.call(fns[1], [needsNumber, 'x']),
      throwsA(
        isA<LuaError>().having(
          (e) => e.message,
          'message',
          "multi.lua:2: bad argument #1 to 'cb' (number expected, got string)",
        ),
      ),
    );
  });

  test('errors carry a traceback taken before the stack unwound', () {
    final vm = LuaVm(config: LuaProfile.stock);
    final f = vm
        .call(
          vm.load(
            File('test/fixtures/recurse.luac').readAsBytesSync(),
            '@recurse.lua',
          ),
          const [],
        )
        .single;
    try {
      vm.call(f, const []);
      fail('no error');
    } on LuaError catch (e) {
      expect(e.traceback, startsWith('stack traceback:\n\trecurse.lua:2: in '));
      expect(e.traceback, contains('\n\t...'));
    }
  });
}
