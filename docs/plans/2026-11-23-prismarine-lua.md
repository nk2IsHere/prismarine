# Plan: prismarine_lua

From [the design](../specs/2026-11-23-prismarine-lua-design.md). The work is on the branch `prismlua` in both
repositories. The coordinator lands mcsm's seam first, with D1 and the corpus. The move follows as one landing in each
repository, prismarine first.

## Step 1: the seam inside mcsm

Each item is one commit in `mcsm_lua`. The tests of `mcsm_lua`, `mcsm_lua_native` and `mcsm_game` pass after each.

1. `LuaConfig`, `LuaNumberMode` and `LuaCRuntime` with their defaults. `LuaProfile` mixes in `LuaConfig`. `LuaVm` takes
   `config:` in place of `profile:` and copies the members into final fields. The callers in mcsm change the argument
   name. An extension keeps `vm.profile` for mcsm's code.
2. The C runtime. The number formatting, `string.format`, `os.date`, `tostring` and `string.rep` read the runtime of
   the VM. The old MSVC runtime and the UCRT become subclasses in their own files.
3. The number modes. The opcode rewrite at load, the specialised cases of the execute loop, the `float32Single`
   arithmetic of the x64 profile as a built-in mode, the table key rule and the rule of one mode per isolate.
   Library results round through the mode.
4. The library hooks. The engine patches run from `patchLibs`. The math library of the x64 profile and the stock
   random functions come from `openMath`. Mixed-type equality and the missing-file text
   read the configuration.
5. A file split. The files of the generic core import nothing of the profiles, the exe runtimes or `mcsm_math`.

Checks: `route_bench --fingerprint` on an S1 and an S2 route and snapshots at fixed times on both, before and after,
byte for byte. `route_bench` timings of the Lua phases on the workstation, base and branch on the same cores.

## Step 2: the move

1. prismarine: `packages/prismarine_lua` with the generic files of step 1, moved as they are. Imports and the package
   name change. The licence of Lua 5.2.3 comes along.
2. prismarine: the double default. `LuaConfig` defaults to `float64`, 64-bit integers and an 8-byte `size_t`. Tests of
   the double mode and of the float32 modes without game data.
3. prismarine: the area page `docs/areas/lua.md`, the state page and the workspace list.
4. mcsm: `mcsm_lua` keeps the profiles, the exe runtimes, the patches, the x64 maths and their tests. It depends on
   `prismarine_lua` and re-exports it. The moved files are deleted.

## Step 3: the native compiler

1. prismarine: `packages/prismarine_lua_native` with the vendored C, the Rust wrapper as two crates (double and
   float32) and `NativeLuaCompiler(mode)`. The float32 `luaconf.h` is mcsm's with neutral comments. Tests: the
   compiler's bytes for the committed sources match `luac`'s.
2. mcsm: the callers use `prismarine_lua_native`. The tests that need game data or the reference build move to
   `mcsm_lua`. `mcsm_lua_native` is removed. The compiled bytes of every committed source stay equal.

## Step 4: hand-back

The pin in mcsm set to the tip of prismarine's branch, the locks committed, the alloc totals, the area docs of both
repositories and the list of changes that could move timing, snapshots or saves.
