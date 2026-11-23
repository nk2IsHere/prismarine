import 'dart:convert';
import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:prismarine_lua_native/prismarine_lua_native.dart';
import 'package:test/test.dart';

/// The native compiler gives luac's bytes for every committed source, and every
/// corpus program run from source prints what the oracle printed.
void main() {
  const compiler = NativeLuaCompiler();
  const lua = '../mcsm_lua/test';

  String src(String path) => String.fromCharCodes(File(path).readAsBytesSync());

  /// luac names a chunk after the path it was given: the corpus and fixtures
  /// were compiled from their own directory, the harness from the package.
  /// (Directory listings on Windows end in `\name`.)
  List<int> compiled(String path, [String? name]) => dumpChunk(
    compiler.compile(
      src(path),
      '@${name ?? path.split(RegExp(r'[/\\]')).last}',
    ),
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

  test('fixtures and the trace harness compile to their luac bytes', () {
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
    expect(
      compiled(
        '$lua/support/trace_harness.lua',
        'test/support/trace_harness.lua',
      ),
      File('$lua/support/trace_harness.luac').readAsBytesSync(),
    );
  });

  test('every corpus program runs from source like the oracle', () {
    for (final n in corpus) {
      final host = MemoryLuaHost();
      final vm = LuaVm(
        config: LuaProfile.stock,
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
