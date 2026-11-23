# prismarine_lua

prismarine_lua is Lua 5.2.3 in pure Dart, with the standard libraries, the binary chunks of Lua 5.2 and codecs that
write a Lua state into a snapshot. Numbers are doubles by default, and a VM can have float numbers for maths that must
match a float32 engine. The details are on [the area page](../../docs/areas/lua.md).

## Usage

You make a `LuaVm` with a `LuaHost` for its output and resources. A host function is a `LuaNative` that reads its
arguments from the stack of the thread, pushes its results and returns their count, in the style of the C API of Lua.
`vm.call` calls a Lua function or a native, and `vm.load` loads a binary chunk. Source text needs a compiler, which
`prismarine_lua_native` has. A `LuaConfig` sets the number mode, the width of `lua_Integer`, the C runtime and the
patches of the libraries.

## Example

The example calls a host function and `string.format` of the standard library. It is
[`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools. A program
gives the same results and the same snapshot bytes on every platform.
