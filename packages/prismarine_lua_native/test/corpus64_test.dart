import 'dart:convert';
import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:prismarine_lua_native/prismarine_lua_native.dart';
import 'package:test/test.dart';

/// Every corpus program of prismarine_lua runs from source in the float64
/// mode and prints what stock Lua 5.2.3 with the double build's luaconf.h
/// printed. The VMs of this file have doubles and run in its own isolate.
void main() {
  const lua = '../prismarine_lua/test/corpus';
  final programs = File('$lua/programs.txt')
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'));
  for (final n in programs) {
    // Number keys hash in float arithmetic in every mode. The `next` order of
    // a table with number keys then differs from a double build, and Lua
    // leaves that order open.
    if (n == 'tbl_next') continue;
    test(n, () {
      final host = MemoryLuaHost();
      final vm = LuaVm(host: host, compiler: const NativeLuaCompiler());
      try {
        vm.call(
          vm.load(File('$lua/$n.lua').readAsBytesSync(), '@$n.lua'),
          const [],
        );
      } on LuaError catch (e) {
        host.out.write('lua52: ${e.message}\n');
      }
      expect(
        host.out.toString(),
        latin1.decode(File('$lua/golden64/$n.out').readAsBytesSync()),
      );
    });
  }
}
