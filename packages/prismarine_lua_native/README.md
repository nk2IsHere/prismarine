# prismarine_lua_native

prismarine_lua_native compiles Lua source for prismarine_lua with the compiler of stock Lua 5.2.3. The build hook
builds the vendored C twice, with double numbers and with float numbers, into two native libraries. The details are on
[the area page](../../docs/areas/lua.md).

## Usage

`NativeLuaCompiler(mode:)` takes the number mode of the VM and goes into the `compiler` of a `LuaVm`. `vm.load` then
accepts source text. A syntax error throws a `LuaLoadError` with the message of Lua.

## Example

The example runs a short program from source. It is [`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The libraries build with Cargo and a C compiler on macOS, Linux and Windows. Both build without fused multiply-adds
and give the same bytecode on every platform.
