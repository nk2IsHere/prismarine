//! Compiles the vendored decoders of third_party/minimp3 and third_party/stb,
//! unmodified and in the public domain, into the library. Rust calls them
//! through src/decode/codec.rs.
//!
//! Decoded PCM is the same on every target with these settings.
//! - No fused multiply-adds, with `-ffp-contract=off` or `/fp:precise` on
//!   MSVC. Apple's clang fuses them on arm64 by default and x86-64 has none.
//! - The tables of stb_vorbis, such as the window, twiddle factors and
//!   codebook sizes, come from `sin`, `cos`, `exp`, `log` and `pow`. The
//!   build renames these to the functions of the libm crate in
//!   decode/codec.rs.
//! - `M_PI` is the double of math.h everywhere. MSVC hides it without
//!   `_USE_MATH_DEFINES`. The fallback of stb_vorbis is a float.
//! - Windows on arm64 compiles with clang-cl. MSVC cannot build the NEON code
//!   of minimp3. Its plain C path computes different bits.
//!
//! minimp3 calls no maths functions.

fn main() {
    let third = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../third_party");
    println!("cargo:rerun-if-changed={}", third.display());
    // Miri runs no foreign code. The tests that would call the decoders do
    // not run under it.
    if std::env::var_os("CARGO_CFG_MIRI").is_some() {
        return;
    }
    let mut mp3 = build();
    // A header, compiled as C with its implementation enabled.
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
    // The cl of MSVC takes no function-like macros on its command line. Its headers declare these
    // functions plainly. The names alone work there. The math.h of glibc builds other names from
    // them. Elsewhere only calls are renamed.
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

/// Returns the common setup with -O3, no warnings and no fused multiply-adds,
/// the `M_PI` of math.h and clang-cl on Windows arm64. Each multiply and add
/// rounds on its own, as on x86-64 without FMA.
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
