import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'float_config.dart';

/// The corpus programs listed in test/corpus/programs.txt.
List<String> corpusPrograms() => File('test/corpus/programs.txt')
    .readAsLinesSync()
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('#'))
    .toList();

/// Runs `golden/<name>.luac` like `lua52f golden/<name>.luac` and returns its
/// output (an uncaught error is printed as lua.c does, plus "exit 1").
String runCorpus(String name) {
  final host = MemoryLuaHost();
  final vm = LuaVm(config: floatConfig, host: host);
  final bytes = File('test/corpus/golden/$name.luac').readAsBytesSync();
  try {
    vm.call(vm.load(bytes, '@golden/$name.luac'), const []);
  } on LuaError catch (e) {
    host.out.write('lua52f: ${e.message}\n${e.traceback ?? ''}\nexit 1\n');
  }
  return host.out.toString();
}
