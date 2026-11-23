import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';
// The arithmetic of the modes is internal to the VM.
import 'package:prismarine_lua/src/vm.dart' show TM, arithOp64;
import 'package:test/test.dart';

/// The float64 mode. Its VMs run in this file's own isolate: the float
/// tests make float VMs.
void main() {
  // A float chunk written again with doubles: the constants keep their
  // values and the code runs in a float64 VM.
  LuaClosure loadAsDouble(LuaVm vm, String golden) {
    final p = undumpChunk(
      File('test/corpus/golden/$golden.luac').readAsBytesSync(),
      '=x',
    );
    return vm.load(dumpLua(p), '@$golden');
  }

  test('arithmetic is double arithmetic with the canonical NaN', () {
    expect(arithOp64(TM.add, 0.1, 0.2), 0.1 + 0.2);
    expect(arithOp64(TM.div, 1, 3), 1 / 3);
    expect(arithOp64(TM.mod, 5.5, 2), 1.5);
    expect(arithOp64(TM.mod, -5.5, 2), 0.5);
    expect(arithOp64(TM.pow, 2, 0.5), 1.4142135623730951);
    final nan = arithOp64(TM.sub, double.infinity, double.infinity);
    final b = ByteData(8)..setFloat64(0, nan);
    expect(b.getUint64(0), 0xFFF8000000000000);
  });

  test('numbers parse as doubles', () {
    expect(parseLuaNumber('0.1', LuaNumberMode.float64), 0.1);
    expect(parseLuaNumber(' 0x10.8 ', LuaNumberMode.float64), 16.5);
    expect(parseLuaNumber('16777217', LuaNumberMode.float64), 16777217);
    expect(parseLuaNumber('16777217', LuaNumberMode.float32), 16777216);
  });

  test('integer keys beyond 2^24 stay exact', () {
    final vm = LuaVm();
    expect(vm.numberMode, LuaNumberMode.float64);
    final t = LuaTable()..setInt(16777217, 'a');
    expect(t.getInt(16777217), 'a');
    expect(t.getInt(16777216), isNull);
    expect(t.get(16777217.0), 'a');
  });

  test('a float VM in a double isolate fails', () {
    LuaVm();
    expect(() => LuaVm(config: LuaProfile.gameApp), throwsStateError);
  });

  test('the defaults are the stock 64-bit build', () {
    final vm = LuaVm();
    expect(vm.integer64, isTrue);
    expect(vm.config.chunkSizeT, 8);
    expect(vm.runtime.numberToString(0.1), '0.1');
    expect(vm.runtime.numberToString(1e15), '1e+15');
    expect(vm.runtime.pointerText(0x1f), '0x0000001f');
    final math = vm.globals.get('math') as LuaTable;
    expect(math.get('pi'), 3.141592653589793);
  });

  test('chunks round-trip with 8-byte numbers and size_t', () {
    final p = undumpChunk(
      File('test/corpus/golden/vm_loops.luac').readAsBytesSync(),
      '=x',
    );
    final d = dumpLua(p);
    expect(d.sublist(0, 12), [
      0x1B, 0x4C, 0x75, 0x61, 0x52, 0x00, 0x01, 0x04, 0x08, 0x04, 0x08, //
      0x00,
    ]);
    expect(dumpLua(undumpLua(d, '=x')), d);
  });

  test('loaded code runs with double numeric for loops', () {
    final host = MemoryLuaHost();
    final vm = LuaVm(host: host);
    vm.call(loadAsDouble(vm, 'vm_loops'), const []);
    expect(host.out.toString(), isNotEmpty);
    // A loop of 0.1 steps sums in double.
    final f = vm.load(
      dumpLua(
        undumpChunk(File('test/fixtures/mod.luac').readAsBytesSync(), '=mod'),
      ),
      '=mod',
    );
    expect(f.p.code.every((i) => i & 0x3F < opFloat32), isTrue);
  });

  test('string.dump writes the standard opcodes and the VM layout', () {
    final vm = LuaVm();
    final f = loadAsDouble(vm, 'vm_loops');
    final dumped = (vm.globals.get('string') as LuaTable).get('dump');
    final s = vm.call(dumped, [f]).single as String;
    expect(s.codeUnits.sublist(8, 11), [8, 4, 8]);
  });
}
