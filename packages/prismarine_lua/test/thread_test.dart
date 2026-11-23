import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:test/test.dart';

void main() {
  late LuaVm vm;
  late List<Object?> fns;
  setUp(() {
    vm = LuaVm(config: LuaProfile.stock);
    final wait = LuaNative((L) => L.yield(1), 'wait');
    fns = vm.call(
      vm.load(
        File('test/fixtures/waiter.luac').readAsBytesSync(),
        '@waiter.lua',
      ),
      [wait],
    );
  });

  test('a native yields; Dart resumes it with values', () {
    final t = vm.newThread(fns[0]);
    final r1 = t.resume([5.0]);
    expect(r1.yielded, isTrue);
    expect(r1.values, [5.0]);
    expect(t.statusFrom(vm.mainThread), 'suspended');
    final r2 = t.resume([42.0]);
    expect(r2.status, luaOk);
    expect(r2.values, [43.0]);
    expect(t.statusFrom(vm.mainThread), 'dead');
  });

  test('yield from the main thread is refused', () {
    expect(
      () => vm.call(fns[0], [1.0]),
      throwsA(
        isA<LuaError>().having(
          (e) => e.message,
          'message',
          'attempt to yield from outside a coroutine',
        ),
      ),
    );
  });

  test('yield inside a metamethod is refused (ruling: nested call)', () {
    final t = LuaTable()..metatable = (LuaTable()..set('__index', fns[1]));
    final r = vm.newThread(fns[2]).resume([t]);
    expect(r.ok, isFalse);
    expect(r.error, 'attempt to yield across a C-call boundary');
  });

  test('an error kills the thread; resuming it again is refused', () {
    final t = vm.newThread(fns[0]);
    t.resume([1.0]);
    final r = t.resume(['not a number']);
    expect(r.ok, isFalse);
    expect(r.error, contains("attempt to perform arithmetic on local 'r'"));
    expect(t.statusFrom(vm.mainThread), 'dead');
    final again = t.resume(const []);
    expect(again.error, 'cannot resume dead coroutine');
  });
}
