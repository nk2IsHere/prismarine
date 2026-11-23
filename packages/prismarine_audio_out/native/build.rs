//! Compiles the vendored decoders (third_party/minimp3, third_party/stb:
//! unmodified, public domain) into the library; Rust calls them through
//! src/decode/codec.rs.
//!
//! Decoded PCM is the same on every target:
//! - no fused multiply-adds (`-ffp-contract=off`; MSVC: `/fp:precise`):
//!   Apple's clang fuses them on arm64 by default and x86-64 has none, so
//!   the two Mac builds would decode every file differently;
//! - stb_vorbis's tables (window, twiddle factors, codebook sizes) come from
//!   `sin`, `cos`, `exp`, `log` and `pow`, which the build renames to the
//!   libm crate's (decode/codec.rs) instead of the platform's C maths;
//! - `M_PI` is math.h's double everywhere (MSVC hides it without
//!   `_USE_MATH_DEFINES`, and stb_vorbis's fallback is a float);
//! - Windows on arm64 compiles with clang-cl: MSVC can't build minimp3's
//!   NEON code, and its plain C path computes different bits.
//!
//! minimp3 calls no maths functions.

fn main() {
    let third = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../third_party");
    println!("cargo:rerun-if-changed={}", third.display());
    // Miri runs no foreign code: the tests that would call the decoders
    // don't run under it.
    if std::env::var_os("CARGO_CFG_MIRI").is_some() {
        return;
    }
    let mut mp3 = build();
    // A header: compiled as C, with its implementation switched on.
    let as_c = if mp3.get_compiler().is_like_msvc() {
        "/TC"
    } else {
        "-xc"
    };
    mp3.file(third.join("minimp3/minimp3_ex.h"))
        .flag(as_c)
        .define("MINIMP3_IMPLEMENTATION", None)
        .define("MINIMP3_FLOAT_OUTPUT", None)
        .compile("prismarine_minimp3");
    let mut ogg = build();
    // MSVC's cl takes no function-like macros on its command line; its
    // headers declare these functions plainly, so the names alone do. glibc's
    // math.h builds other names from them, so elsewhere only calls are
    // renamed.
    let cl = ogg.get_compiler().is_like_msvc() && !ogg.get_compiler().is_like_clang_cl();
    for (f, args) in [
        ("sin", "x"),
        ("cos", "x"),
        ("exp", "x"),
        ("log", "x"),
        ("pow", "x,y"),
    ] {
        if cl {
            ogg.define(f, Some(format!("prismarine_vorbis_{f}").as_str()));
        } else {
            ogg.define(
                &format!("{f}({args})"),
                Some(format!("prismarine_vorbis_{f}({args})").as_str()),
            );
        }
    }
    ogg.file(third.join("stb/stb_vorbis.c"))
        .define("STB_VORBIS_NO_PUSHDATA_API", None)
        .define("STB_VORBIS_NO_STDIO", None)
        .compile("prismarine_stb_vorbis");
}

/// The common setup: -O3, no warnings, no fused multiply-adds (each
/// multiply and add rounds on its own, as on x86-64 without FMA), math.h's
/// `M_PI`, clang-cl on Windows arm64.
fn build() -> cc::Build {
    let mut b = cc::Build::new();
    let target = std::env::var("TARGET").unwrap_or_default();
    if target == "aarch64-pc-windows-msvc"
        && std::env::var_os("CC_aarch64_pc_windows_msvc").is_none()
    {
        b.compiler("clang-cl");
    }
    b.opt_level(3).warnings(false);
    let c = b.get_compiler();
    if c.is_like_clang_cl() {
        b.flag("/clang:-ffp-contract=off")
            .define("_USE_MATH_DEFINES", None);
    } else if c.is_like_msvc() {
        b.flag("/fp:precise").define("_USE_MATH_DEFINES", None);
    } else {
        b.flag("-ffp-contract=off");
    }
    b
}
