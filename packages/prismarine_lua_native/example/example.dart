import 'dart:typed_data';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:prismarine_lua_native/prismarine_lua_native.dart';

void main() {
  final host = MemoryLuaHost();
  final vm = LuaVm(host: host, compiler: const NativeLuaCompiler());
  final source = '''
    local t = {}
    for i = 1, 3 do t[i] = i * 0.5 end
    print(table.concat(t, ' '), 2 ^ 0.5)
  ''';
  vm.call(vm.load(Uint8List.fromList(source.codeUnits), '=example'), []);
  print(host.out);
}
