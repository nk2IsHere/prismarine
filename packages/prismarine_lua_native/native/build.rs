//! Compiles stock Lua 5.2.3's core and auxlib (third_party/lua-5.2.3,
//! unmodified) with the package's exe-configured luaconf.h (src/luaconf.h):
//! all the compiler needs (no standard libraries, no lua.c/luac.c).

/// The core and the auxlib.
const CORE: &[&str] = &[
    "lapi", "lcode", "lctype", "ldebug", "ldo", "ldump", "lfunc", "lgc", "llex", "lmem", "lobject",
    "lopcodes", "lparser", "lstate", "lstring", "ltable", "ltm", "lundump", "lvm", "lzio",
    "lauxlib",
];

fn main() {
    let pkg = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let lua = pkg.join("third_party/lua-5.2.3/src");
    let conf = pkg.join("src");
    println!("cargo:rerun-if-changed={}", lua.display());
    println!(
        "cargo:rerun-if-changed={}",
        conf.join("luaconf.h").display()
    );
    // Miri runs no foreign code: the tests that would call Lua don't run
    // under it.
    if std::env::var_os("CARGO_CFG_MIRI").is_some() {
        return;
    }
    let mut b = cc::Build::new();
    for f in CORE {
        b.file(lua.join(format!("{f}.c")));
    }
    // luaconf.h is found through the include path (the vendored copy has
    // none), so the configured one is the only one.
    b.include(&conf).include(&lua).opt_level(3).warnings(false);
    if !std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "windows") {
        b.flag("-fvisibility=hidden");
    }
    // No fused multiply-adds (Apple's clang fuses on arm64 by default; x86-64
    // has none): constant folding of `%` (luai_nummod's a - floor(a/b)*b)
    // gives the same bytecode on every target (portable float: vendored C
    // builds without fused multiply-adds).
    if b.get_compiler().is_like_msvc() {
        b.flag("/fp:precise");
    } else {
        b.flag("-ffp-contract=off");
    }
    b.compile("mcsm_lua52");
}
