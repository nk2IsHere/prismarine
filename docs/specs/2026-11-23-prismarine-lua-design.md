# prismarine_lua: an embeddable Lua for Dart

`prismarine_lua` is a Lua 5.2.3 virtual machine in pure Dart, with the standard libraries, the binary chunk format,
snapshot codecs and a C-API style embedding interface. `prismarine_lua_native` compiles Lua source with the stock
5.2.3 C compiler. Numbers are doubles by default. Two float32 number modes exist for games whose maths must match a
float32 engine.

mcsm is the first user. Its Lua runs the whole game and must not change by a single bit, in its results, its text, its
table order and its snapshots. mcsm keeps its exe profiles, its C runtime text and its library patches in `mcsm_lua`,
which becomes a configuration of `prismarine_lua`.

## Goals

- A Lua for any Dart program, configured per VM, with no game code in it.
- Doubles by default, with the stock behaviour of Lua 5.2.3 on a 64-bit POSIX system.
- The float32 modes run at the speed of today's VM of mcsm. No instruction does a test of the number mode.
- mcsm's behaviour stays bit-identical: D1, the regression corpus, the route fingerprints, its snapshots and saves.
- The snapshot stream of a Lua state stays byte-identical. Every recorded route and save of mcsm still loads.

## Not in scope

- Unboxed numbers on the Lua stack. The stack holds Dart objects. A number is a boxed `double`. An unboxed stack
  is a later change to the VM, measured on its own.
- Lua 5.3 or 5.4 semantics, such as integer subtypes.
- A per-VM object id counter. The counter stays per isolate. A per-VM counter would change the snapshot stream and
  needs a versioned read path.
- Garbage collection semantics, weak tables and `__gc`. The VM does not run finalizers, as today.

## Packages

| Package | Contents |
|---|---|
| `prismarine_lua` | The VM, the standard libraries, the chunk codec, the snapshot codecs, the configuration interface and the default C runtime. Pure Dart. Depends on `prismarine_math` and `prismarine_snap` |
| `prismarine_lua_native` | Stock Lua 5.2.3 in vendored C with a thin Rust wrapper, built twice: a double build and a float32 build. Implements the compiler interface of `prismarine_lua` |

In mcsm, `mcsm_lua` keeps the three profiles (`stock`, `gameApp`, `minecraft2`), the two exe C runtimes, the
library patches of the engine, the x64 maths library on the UCRT float functions and the tests that need game data.
It re-exports `prismarine_lua`. The imports of `mcsm_game` stay as they are. `mcsm_lua_native` is removed. mcsm
compiles source with the float32 build of `prismarine_lua_native`.

## Values

A Lua value is a Dart object. `nil` is `null`, a boolean is a `bool`, a number is a `double`, a string is a `String`
whose code units are bytes. Tables, functions, threads and userdata extend `LuaObject`. The representation is the
same in every number mode. A float32 mode keeps float32 values in doubles and rounds at each operation. The snapshot
codecs therefore write the same bytes in every mode.

## Number modes

A VM has one of three number modes. `LuaNumberMode.float64` is the default.

| Mode | `lua_Number` | An operation | A NaN result |
|---|---|---|---|
| `float64` | double | is the IEEE double operation | is the canonical NaN |
| `float32` | float | is computed in double and rounded once to float | is the canonical NaN |
| `float32Single` | float | is a single-precision operation | takes the first NaN operand, made quiet, or else the canonical NaN |

A number key of a table hashes with the float formula of `luai_hashnum` in every mode. The `next` order of a table
with number keys in `float64` therefore differs from a double build of stock Lua. Lua leaves that order open and the
float formula keeps the table code free of a mode test.

The canonical NaN is the quiet NaN with the sign bit set, which an x86-64 CPU produces for an invalid operation. Lua
code then gets the same bits and the same text on x86-64 and on ARM.

The modes differ in these places.

| Place | `float64` | `float32` | `float32Single` |
|---|---|---|---|
| `+ - * /` | a op b | round(a op b) | round(a op b), NaN operands passed on |
| `%` | a − floor(a/b)·b | a/b and the product in double, floor(a/b) rounded to float, the result rounded | every step in float |
| `^` | `pow` of `prismarine_math` | `pow` in double, rounded | `powf` of the C runtime |
| Numeric `for` | idx + step | round(idx + step) | round(idx + step) |
| String to number | double | rounded to float | rounded to float |
| `tonumber(s, base)` | n·base + d | round(n·base + d) | round(round(base·n) + d) |
| A library result | the double | rounded to float | rounded to float |
| Chunk constants | 8 bytes | 4 bytes | 4 bytes |

`float32` is a C build with float numbers that evaluates float expressions in double, as x87 code does.
`float32Single` is a C build that evaluates them in float, as SSE code does. The `%` row of `float32` is that of an x87
build that stores the floor in a float variable.

The width of `lua_Integer` is a separate setting, 64 bits by default and 32 bits as an option. A number converts to an
integer by truncation. A NaN or a number outside the range gives the smallest integer of the width, as the x86
conversion instructions do. `luaL_checkint` keeps the low 32 bits of the `lua_Integer`.

### Float and double numbers per isolate

Tables and the object id counter are shared by the VMs of an isolate. An integer table key above 2^24 has a float value
in a float32 mode and an exact one in `float64`. The first VM of an isolate therefore decides between float and double
numbers for the isolate. A VM with the other kind of numbers in the same isolate throws a `StateError`. The two float32
modes can share an isolate. Tests of both kinds run in separate test files, which `dart test` runs in separate
isolates.

### Specialised opcodes

A VM rewrites the arithmetic and numeric `for` instructions of a prototype when it loads the chunk. `ADD`, `SUB`,
`MUL`, `DIV`, `MOD`, `POW`, `FORLOOP` and `FORPREP` keep their standard opcodes in `float64`. In `float32` they become
the internal opcodes 40 to 47. In `float32Single` the arithmetic becomes 48 to 53 and the loops take 46 and 47 of
`float32`. The execute loop has a group of cases for the arithmetic of each mode and a case for each loop opcode of a
mode. No instruction tests the mode.

`opOf` returns the standard opcode of an instruction. The debug functions use it. `dumpLua` and `string.dump` write the
standard opcodes. A prototype is loaded for one VM, which has one mode.

## The C runtime

`LuaCRuntime` holds the behaviour of the C library under the Lua build. The default is the C library of a 64-bit POSIX
system and is checked against stock Lua on macOS by mcsm's differential tests. A configuration can supply another.

| Member | Default |
|---|---|
| `numberToString(n)` | `"%.14g"` with exact digits |
| `formatE`, `formatF`, `formatG` | exact digits, rounded half to even, at least two exponent digits |
| `formatA` | null. `string.format` then refuses `%a` |
| `nonFiniteText` | `inf`, `-inf`, `nan`, `-nan`, upper case for `%E` and `%G` |
| `specialText`, `pointNonFinite`, `zeroPadsNonFinite` | the plain text of inf and NaN, without a point or zeros |
| `toLong`, `toULong` | the 64-bit `long` of `%d` and `%x`, saturating |
| `sizeMax` | 2^63 − 1 |
| `pointerText(id)` | `0x` and at least eight hex digits |
| `powf(a, b)` | `pow` in double, rounded to float |
| The conversions of `os.date` | the POSIX set with the `E` and `O` modifiers |
| The range of `gmtime` | unlimited |

mcsm supplies the old static MSVC runtime of its first exe and the UCRT of its second exe as subclasses. The digit
rounding, the exponent width, the zero exponent of `%g` and the special text are members that a subclass overrides.
The formatting code stays one copy.

## Configuration

A VM takes a `LuaConfig`. It is an abstract mixin class with a default for every member. An enum of profiles can
mix it in. The VM copies the members into final fields when it is made. A hot path reads a field.

| Member | Default | Effect |
|---|---|---|
| `numberMode` | `float64` | The number mode |
| `integer64` | true | The width of `lua_Integer` |
| `chunkSizeT` | 8 | The `size_t` width in the header of a binary chunk that `load` accepts |
| `runtime` | `LuaCRuntime()` | The C runtime |
| `mixedTypeEquality` | false | `==` of values of different types calls the `__eq` metamethod of the first operand, then of the second |
| `missingFileText(name)` | `cannot open <name>: No such file or directory` | The message of `loadfile` and `dofile` for a missing file |
| `openMath(vm, table)` | the standard `math` library | Fills the `math` table |
| `patchLibs(vm)` | nothing | Runs after the standard libraries are open |

`math.random` uses the VM's generator (`LuaRng`, Marsaglia's xorshift128). `random()` is the next value over 2^32,
`random(n)` is `next % n + 1` and `random(m, n)` maps the next value onto the range. `randomseed(0)` restores the
default state. The generator belongs to the host and can outlive a VM.

## Embedding

The interface follows the C API of Lua 5.2, which an embedder already knows.

- `LuaVm` is the global state: the registry, the globals, the main thread, the metatables of the basic types, the
  configuration and the host.
- `LuaHost` supplies output, logs, resources by name, the clock and the time.
- A host function is a `LuaNative` around `int Function(LuaThread L)`. It reads its arguments with `L.checkNumber(1)`,
  `L.checkString(2)` and the other `check` and `opt` functions, pushes its results and returns their count.
- A host object is a `LuaUserdata` with a payload, a metatable and a user value.
- `L.luaError(message)` raises a Lua error with the position. `LuaError` carries the error value out of a protected
  call. `LuaLoadError` reports a chunk that does not load.
- `vm.load(bytes, name)` loads a binary chunk, or source text through the VM's `LuaCompiler`. `vm.call(fn, args)` calls
  a function. `vm.newThread(fn)` and `thread.resume(args)` run a coroutine.

## Chunks

The chunk codec reads and writes the binary chunks of Lua 5.2. The header has 4 for `int` and the instruction, the
`size_t` width of the configuration and the number width of the mode. `undumpLua` also reads the host layout of the
native compiler, with an 8-byte `size_t`.

`prismarine_lua_native` builds the vendored C of Lua 5.2.3 twice. The double build has the stock configuration on a
64-bit host. The float32 build has float numbers, the conversions of the number modes, the `%` of `float32`, `pow`
from the Rust `libm` crate in the order of `prismarine_math` and a 32-bit `lua_Integer`. Both builds compile without
fused multiply-adds. Constant folding then gives the same bytecode on every target. `NativeLuaCompiler(mode)` picks
the build. The float32 build serves both float32 modes. Its constant folding follows `float32`, which differs from
`float32Single` only for a constant `%` or `^` of non-integers.

The vendored C stays unmodified. The two builds differ only in their `luaconf.h`.

## Snapshots

`registerLuaSnap` registers the codecs `lua.Table`, `lua.Closure`, `lua.Native`, `lua.Thread`, `lua.Userdata`,
`lua.UpVal`, `lua.Proto`, `lua.Chunk`, `lua.Rng` and `lua.Vm` on a `SnapRegistry` of `prismarine_snap`. Their tags,
field order and encodings do not change. A prototype is written as its chunk and its index and is loaded again on
read, which rewrites its opcodes for the reader's mode. A chunk that the host has as a resource is written as its name,
length and FNV-1a hash.

`LuaSnapState` and `LuaSnapEnv` keep the boot objects of a state, which a snapshot refers to by creation order, and
refuse an object of a closed state. `luaWithBoot` collects the boot objects while a state is built. `luaNextId` is the
object id counter of the isolate. A replay framework, such as `prismarine_replay`, composes these codecs into its own
state and has no dependency on `prismarine_lua`.

## The configuration of mcsm

| Profile | Mode | `lua_Integer` | `size_t` | Runtime | Other members |
|---|---|---|---|---|---|
| `stock` | `float32` | 32 | 4 | default | `openMath` with the Park–Miller `math.random` of mcsm's reference build |
| `gameApp` | `float32` | 32 | 4 | old MSVC | mixed-type equality, the engine's library patches, the engine's missing-script text |
| `minecraft2` | `float32Single` | 64 | 4 | UCRT | as `gameApp`, `openMath` with the UCRT float functions |

`mcsm_lua` keeps its public functions with the profile parameter, such as `numberToString(n, profile)` and
`cFormatF(x, 6, profile)`, as one-line forwards to the runtime of the profile. The `stock` seed of `math.random`
moves to `mcsm_lua`. `luaSnapCounters` and `luaRestoreCounters` keep their names and their two integers. The
object order of a new state stays the same. The patches run at the end of `openLibs`, where they run today. The
random functions of `stock` are made at their place in the `math` table.

## Proof of fidelity

The seam is cut inside mcsm first. One commit moves each profile branch behind the configuration. The next commit moves
the files. Each step is checked in this way.

- The tests of `mcsm_lua`, of `mcsm_lua_native` until its removal and of `mcsm_game`. They cover the three profiles,
  the CRT text, the S2 probe of about 95,000 cases and the compiler's bytes for every committed source.
- `route_bench --fingerprint` on routes of both seasons, before and after, with identical files.
- Snapshots of the same routes written at the same game times, before and after, compared byte for byte.
- The coordinator's D1 and regression corpus before landing.

The tests of `prismarine_lua` cover the double mode against the stock behaviour of Lua 5.2.3 and the float32 modes with
cases copied from mcsm's tests that use no game data.

## Speed

The specialised opcodes add no test per instruction. The float32 arithmetic is the code of today's VM without its test
of the x64 profile. The float32Single arithmetic takes the fast path in place of today's general path. A float32 table key
up to 2^24 converts without the float rounding of today's VM. The load of a chunk in a float32 mode adds one pass over
its instructions. `route_bench` on the workstation times the Lua phases of a heavy scene of each season before and
after, on the same cores and load. The result must not be slower.

## Risks

- **A behaviour change in a branch that no test reaches.** The seam commit changes conditions into virtual members,
  one profile branch at a time. The fingerprints and snapshots of real routes cover the paths that the game uses.
- **The opcode rewrite.** A tool that reads the code of a loaded prototype sees internal opcodes. `opOf` and
  `dumpLua` map them back. Tools that read chunks with `undumpLua` see the standard ones.
- **Two native builds.** Both builds are compiled for every app that depends on `prismarine_lua_native`. The cost is
  one more build of 20,000 lines of C, cached by the build hook.
