import 'dart:convert';
import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:prismarine_lua_native/prismarine_lua_native.dart';
import 'package:test/test.dart';

import 'support/float_config.dart';

/// The float32 build gives the bytes of the reference build for every
/// committed source of the corpus of prismarine_lua. Every corpus program run
/// from source prints what the reference build printed.
void main() {
  const compiler = NativeLuaCompiler(mode: LuaNumberMode.float32);
  const lua = '../prismarine_lua/test';

  String src(String path) => String.fromCharCodes(File(path).readAsBytesSync());

  // luac gives a chunk the path that it got. The corpus and the fixtures
  // were compiled from their own directory. A directory listing on Windows
  // ends in `\name`.
  List<int> compiled(String path) => dumpLua(
    compiler.compile(src(path), '@${path.split(RegExp(r'[/\\]')).last}'),
    sizeT: 4,
    float32: true,
  );

  final corpus = File('$lua/corpus/programs.txt')
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();

  test('corpus sources compile to the committed luac bytes', () {
    expect(corpus, isNotEmpty);
    for (final n in corpus) {
      expect(
        compiled('$lua/corpus/$n.lua'),
        File('$lua/corpus/golden/$n.luac').readAsBytesSync(),
        reason: n,
      );
    }
  });

  test('fixtures compile to their luac bytes', () {
    final fixtures = Directory(
      '$lua/fixtures',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.lua'));
    for (final f in fixtures) {
      expect(
        compiled(f.path),
        File('${f.path}c').readAsBytesSync(),
        reason: f.path,
      );
    }
  });

  test('every corpus program runs from source as in the reference build', () {
    for (final n in corpus) {
      final host = MemoryLuaHost();
      final vm = LuaVm(
        config: const FloatConfig(),
        host: host,
        compiler: compiler,
      );
      final f = vm.load(
        File('$lua/corpus/$n.lua').readAsBytesSync(),
        '@$n.lua',
      );
      try {
        vm.call(f, const []);
      } on LuaError catch (e) {
        host.out.write('error: ${e.message}\n');
      }
      expect(
        host.out.toString(),
        latin1.decode(File('$lua/corpus/golden/$n.out').readAsBytesSync()),
        reason: n,
      );
    }
  });

  test('syntax errors are LuaLoadErrors with Lua\'s message', () {
    expect(
      () => compiler.compile('local function end', '=x'),
      throwsA(
        isA<LuaLoadError>().having(
          (e) => e.message,
          'message',
          "x:1: <name> expected near 'end'",
        ),
      ),
    );
  });
}
