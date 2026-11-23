# Lua 5.2.3 (vendored)

Unmodified `src/*.c`/`*.h` from lua.org's `lua-5.2.3.tar.gz` (md5 `dc7f94ec6ff15c985d2d6ad0f1b35654`, sha1 `926b7907bc8d274e063d42804666b40a3f3c124c`), MIT licence (`LICENSE`).

Left out: `lua.c` and `luac.c` (the standalone programs), and `luaconf.h`. The package's configured copy is `../../src/luaconf.h`: it is stock apart from the edits marked `mcsm:`, which configure numbers and integer conversions like GameApp.exe (docs/formats/lua-runtime.md).

`mcsm_lua_native` builds the core and auxlib (no standard libraries) from its Rust crate's `build.rs` (`../../native`), whose `src/lib.rs` is the compiler's thin wrapper. It is not used as a runtime: the VM is `packages/mcsm_lua`.
