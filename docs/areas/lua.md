# prismarine_lua and prismarine_lua_native

`prismarine_lua` is Lua 5.2.3 in pure Dart, with the standard libraries, the binary chunks of Lua 5.2 and codecs that
write a Lua state into a `prismarine_snap` snapshot. `prismarine_lua_native` compiles Lua source with the compiler of
stock Lua 5.2.3, built from its C as a native library. A VM without a compiler loads binary chunks only. The design is
in [the spec](../specs/2026-11-23-prismarine-lua-design.md).

## Embedding

You make a `LuaVm` with a `LuaHost`, which supplies output, logs, resources by name and the clocks, and a
`LuaCompiler`, usually `NativeLuaCompiler()`. `vm.load(bytes, name)` returns a function and `vm.call(fn, args)` calls
it. A script thread is `vm.newThread(fn)`, which `thread.resume(args)` runs until it yields or ends.

A host function is a `LuaNative` around `int Function(LuaThread L)`, in the style of the C API of Lua. It reads its
arguments with `L.checkNumber(1)`, `L.checkString(2)` and the other `check` and `opt` functions, pushes its results and
returns their count. A host object is a `LuaUserdata` with a payload, a metatable and a user value. `L.luaError(text)`
raises an error with the position of the caller, and a `LuaError` carries an error out of a protected call.

## Configuration

A `LuaConfig` sets the build of a VM. The defaults are stock Lua 5.2.3 on a 64-bit POSIX system.

| Member | Default | Effect |
|---|---|---|
| `numberMode` | `float64` | Double numbers, or float numbers in `float32` (each operation computed in double and rounded once) and `float32Single` (single-precision operations that pass a NaN operand on) |
| `integer64` | true | A 64-bit `lua_Integer`, else 32-bit |
| `chunkSizeT` | 8 | The `size_t` width of the binary chunks that `load` accepts |
| `runtime` | `LuaCRuntime()` | The C library under the build: the number text of printf, the widths of `long` and `size_t`, `%p`, strftime and gmtime |
| `mixedTypeEquality` | false | `==` of values of different types calls `__eq` |
| `missingFileText` | the stock text | The message of `loadfile` and `dofile` for a missing file |
| `openMath`, `patchLibs` | the standard libraries | Replace the `math` library, or change the libraries after they are open |

The VMs of an isolate all have float numbers or all have doubles. A VM of the other kind throws a `StateError`. A NaN
result is the quiet NaN with the sign set, the same on every CPU. A number key of a table hashes in float arithmetic
in every mode, which gives a `next` order that differs from a double build of stock Lua.

The float modes keep their numbers in Dart doubles and round at each operation. A loaded chunk has its arithmetic and
numeric `for` instructions rewritten to opcodes of its mode, and the execute loop tests no mode. `opOf`, `dumpLua` and
`string.dump` give the standard opcodes.

`math.random` draws from the xorshift128 generator of the VM, which the host can share between VMs.

## Compiler

`NativeLuaCompiler(mode:)` picks one of two builds of the stock C. The double build serves `float64`, and the float32
build serves both float modes. The two differ only in their `luaconf.h` in `native/f64/` and `native/f32/`. Both take
`pow` from the Rust `libm` crate and build without fused multiply-adds, which gives the same bytecode on every target.
The build hook builds both libraries through `prismarine_cargo`.

## Snapshots

`registerLuaSnap(registry)` adds the codecs of tables, closures, natives, threads, userdata, upvalues, prototypes,
chunks, the generator and the VM. A prototype is written as its chunk and index. A chunk that the host has as a
resource is written as its name and hash. The objects that the host made while it built a state are its boot objects,
which `luaWithBoot` collects. A snapshot refers to them by creation order. `LuaSnapEnv` carries the current state to
the codecs, and a write that reaches an object of a closed state fails. `luaNextId` is the object id counter of the
isolate, which a snapshot must save and restore.

## Checks

Run `dart test` in `packages/prismarine_lua` and in `packages/prismarine_lua_native`. The test corpus in
`prismarine_lua/test/corpus` has its programs, their chunks and their output from stock Lua 5.2.3 built with the float
`luaconf.h` (`golden/`), and their output from the double `luaconf.h` (`golden64/`). The float32 build must give the
bytes of every chunk of `golden/`. The double build runs every program but `tbl_next` to the output of `golden64/`.
Run `cargo clippy` and `cargo test` in `native/f64` and `native/f32`.
