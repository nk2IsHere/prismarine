import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:test/test.dart';

import 'support/float_config.dart';

void main() {
  LuaClosure fixture(LuaVm vm, String name) =>
      vm.load(File('test/fixtures/$name.luac').readAsBytesSync(), '@$name.lua');

  test('vm.call returns all results', () {
    final vm = LuaVm(config: floatConfig);
    final fns = vm.call(fixture(vm, 'multi'), const []);
    expect(vm.call(fns[0], [1.0, 2.0]), [1.0, 2.0, 3.0]);
    expect(vm.mainThread.top, 1);
  });

  test('C stack overflow for deeply nested native -> Lua calls', () {
    final vm = LuaVm(config: floatConfig);
    final fns = vm.call(fixture(vm, 'multi'), const []);
    late LuaNative deeper;
    deeper = LuaNative((L) {
      final n = L.checkNumber(1);
      L.push(fns[1]);
      L.push(deeper);
      L.push(n + 1);
      L.call(2, 1);
      return 1;
    });
    expect(
      () => vm.call(deeper, [0.0]),
      throwsA(
        isA<LuaError>().having(
          (e) => e.message,
          'message',
          contains('C stack overflow'),
        ),
      ),
    );
    // The main thread is usable again afterwards.
    expect(vm.call(fns[0], [1.0, 1.0]), [1.0, 1.0, 2.0]);
  });

  test('stack overflow for runaway recursion', () {
    final vm = LuaVm(config: floatConfig);
    final f = vm.call(fixture(vm, 'recurse'), const []).single;
    expect(
      () => vm.call(f, const []),
      throwsA(
        isA<LuaError>().having(
          (e) => e.message,
          'message',
          'recurse.lua:2: stack overflow',
        ),
      ),
    );
  });

  test('text chunks without a compiler are a clear LuaLoadError', () {
    expect(
      () => LuaVm(
        config: floatConfig,
      ).load(Uint8List.fromList('return 1'.codeUnits), '=x'),
      throwsA(
        isA<LuaLoadError>().having(
          (e) => e.message,
          'message',
          contains('LuaCompiler'),
        ),
      ),
    );
  });

  test('text chunks go through the LuaCompiler', () {
    final vm = LuaVm(config: floatConfig, compiler: _Fixed(vm0Proto()));
    final f = vm.load(Uint8List.fromList('ignored'.codeUnits), '=x');
    expect(vm.call(f, const []), [1.0, 2.0, 3.0]);
  });
}

/// A compiler that returns a fixed proto (multi.lua's first function wrapped).
class _Fixed implements LuaCompiler {
  _Fixed(this.p);
  final LuaProto p;
  @override
  LuaProto compile(String source, String chunkName) => p;
}

LuaProto vm0Proto() => undumpFloat(
  File('test/fixtures/compile_fixed.luac').readAsBytesSync(),
  '=f',
);
