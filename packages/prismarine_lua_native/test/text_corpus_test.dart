import 'dart:convert';
import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:prismarine_lua_native/prismarine_lua_native.dart';
import 'package:test/test.dart';

import 'support/float_config.dart';

/// Programs that load text chunks print what the reference build printed.
void main() {
  final programs = File('test/corpus/programs.txt')
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'));
  for (final n in programs) {
    test(n, () {
      final host = MemoryLuaHost();
      final vm = LuaVm(
        config: const FloatConfig(),
        host: host,
        compiler: const NativeLuaCompiler(mode: LuaNumberMode.float32),
      );
      vm.call(
        vm.load(
          File('test/corpus/golden/$n.luac').readAsBytesSync(),
          '@golden/$n.luac',
        ),
        const [],
      );
      expect(
        host.out.toString(),
        latin1.decode(File('test/corpus/golden/$n.out').readAsBytesSync()),
      );
    });
  }
}
