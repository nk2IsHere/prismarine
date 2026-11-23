//! The vendored decoders give the same PCM on every target: no fused
//! multiply-adds, stb_vorbis's tables from the libm crate (build.rs).
//! tests/data holds two short
//! files made for this test (ffmpeg's vorbis and libmp3lame encoders from
//! generated tones and noise; no game data); CI runs this on every OS and
//! architecture against the same checksums.

use prismarine_audio_out::decode::codec::decode_file;

/// FNV-1a 64 of the decoded float32 bits.
fn checksum(path: &str) -> (i64, i32, i32, u64) {
    let p = decode_file(path).unwrap_or_else(|| panic!("{path} doesn't decode"));
    let mut h = 0xcbf29ce484222325u64;
    for v in &p.samples {
        for b in v.to_bits().to_le_bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
    }
    (p.frames, p.channels, p.rate, h)
}

fn data(name: &str) -> String {
    format!("{}/tests/data/{name}", env!("CARGO_MANIFEST_DIR"))
}

#[test]
#[cfg_attr(miri, ignore)]
fn ogg_decodes_to_the_same_bits_everywhere() {
    let c = checksum(&data("synthetic.ogg"));
    assert_eq!(
        c,
        (72000, 2, 48000, 0xe1cd_e78f_26c8_9abf),
        "{:?} {:016x}",
        c,
        c.3
    );
}

#[test]
#[cfg_attr(miri, ignore)]
fn mp3_decodes_to_the_same_bits_everywhere() {
    let c = checksum(&data("synthetic.mp3"));
    assert_eq!(
        c,
        (67968, 2, 44100, 0x78a1_660a_9e5a_4ee2),
        "{:?} {:016x}",
        c,
        c.3
    );
}
