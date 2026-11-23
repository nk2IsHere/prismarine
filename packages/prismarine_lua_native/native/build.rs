//! Compiles the core and the auxlib of stock Lua 5.2.3 (third_party/lua-5.2.3,
//! unmodified) with the luaconf.h in the directory of the crate, f64/ or f32/.
//! The compiler needs nothing else: no standard libraries, no lua.c or luac.c.

/// The core and the auxlib.
const CORE: &[&str] = &[
    "lapi", "lcode", "lctype", "ldebug", "ldo", "ldump", "lfunc", "lgc", "llex", "lmem", "lobject",
    "lopcodes", "lparser", "lstate", "lstring", "ltable", "ltm", "lundump", "lvm", "lzio",
    "lauxlib",
];

fn main() {
    let conf = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let lua = conf.join("../../third_party/lua-5.2.3/src");
    println!("cargo:rerun-if-changed={}", lua.display());
    println!(
        "cargo:rerun-if-changed={}",
        conf.join("luaconf.h").display()
    );
    let float32 = conf.ends_with("f32");
    if float32 {
        println!("cargo:rustc-cfg=lua_float32");
    }
    // Miri runs no foreign code. The tests that call Lua do not run under it.
    if std::env::var_os("CARGO_CFG_MIRI").is_some() {
        return;
    }
    let mut b = cc::Build::new();
    for f in CORE {
        b.file(lua.join(format!("{f}.c")));
    }
    // The vendored copy has no luaconf.h. The include path finds the one of
    // the crate.
    b.include(&conf).include(&lua).opt_level(3).warnings(false);
    if !std::env::var("CARGO_CFG_TARGET_OS").is_ok_and(|os| os == "windows") {
        b.flag("-fvisibility=hidden");
    }
    // No fused multiply-adds. Apple's clang fuses on arm64 by default. The
    // constant folding of `%` then gives the same bytecode on every target.
    if b.get_compiler().is_like_msvc() {
        b.flag("/fp:precise");
    } else {
        b.flag("-ffp-contract=off");
    }
    b.compile(if float32 { "lua52_f32" } else { "lua52_f64" });
}
