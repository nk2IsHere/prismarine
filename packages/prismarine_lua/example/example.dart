import 'package:prismarine_lua/prismarine_lua.dart';

void main() {
  final vm = LuaVm();

  // A host function that adds its two arguments.
  vm.globals.set(
    'add',
    LuaNative((L) {
      L.push(L.checkNumber(1) + L.checkNumber(2));
      return 1;
    }, 'add'),
  );

  final add = vm.globals.get('add');
  final format = (vm.globals.get('string') as LuaTable).get('format');
  final sum = vm.call(add, [0.1, 0.2]).single;
  print(vm.call(format, ['%.17g', sum]).single);
}
