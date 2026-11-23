//! Replays a session mcsm_audio's tool/native_parity.dart wrote through the
//! native mixer and compares the bits with the Dart engine's render (dev
//! only; the decoded PCM comes from the files the tool listed).
//!
//! usage: `cargo run --release --example parity -- <dir>`

use std::collections::HashMap;
use std::ffi::CString;
use std::sync::Mutex;

use prismarine_audio_out::decode::{cache, codec::Pcm};
use prismarine_audio_out::mix::*;

/// path → (decoded f32 file, channels, rate), from the session's pcm.tsv.
static PCM: Mutex<Option<HashMap<String, (String, i32, i32)>>> = Mutex::new(None);

/// The cache's loader: the session's PCM (ffmpeg's decode the Dart engine
/// played) instead of the vendored decoders.
fn load(path: &str) -> Option<Pcm> {
    let (file, channels, rate) = PCM.lock().unwrap().as_ref().unwrap().get(path)?.clone();
    let b = std::fs::read(file).ok()?;
    let samples: Vec<f32> = b
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect();
    let frames = samples.len() as i64 / channels as i64;
    Some(Pcm {
        samples,
        frames,
        channels,
        rate,
    })
}

fn main() {
    let dir = std::env::args().nth(1).expect("dir");
    let mut map = HashMap::new();
    for l in std::fs::read_to_string(format!("{dir}/pcm.tsv"))
        .unwrap()
        .lines()
    {
        let f: Vec<&str> = l.split('\t').collect();
        if f.len() == 4 {
            map.insert(
                f[0].to_string(),
                (
                    f[1].to_string(),
                    f[2].parse().unwrap(),
                    f[3].parse().unwrap(),
                ),
            );
        }
    }
    *PCM.lock().unwrap() = Some(map);
    let meta = std::fs::read_to_string(format!("{dir}/meta.txt")).unwrap();
    let mut it = meta.split_whitespace();
    let seed: i64 = it.next().unwrap().parse().unwrap();
    let total: i64 = it.next().unwrap().parse().unwrap();
    // The engine's rules: report lag, late start minimum, whole-ms lengths.
    let report_lag: i64 = it.next().map_or(0, |v| v.parse().unwrap());
    let late_min: f64 = it.next().map_or(0.0, |v| v.parse().unwrap());
    let whole_ms: i32 = it.next().map_or(0, |v| v.parse().unwrap());
    let blob = std::fs::read(format!("{dir}/model.bin")).unwrap();
    cache::set_loader(load);
    let t0 = std::time::Instant::now();
    // SAFETY: the blob is a live slice of its length.
    let e = unsafe {
        prismarine_mix_create(
            blob.as_ptr(),
            blob.len() as i64,
            seed,
            0,
            report_lag,
            late_min,
            whole_ms,
        )
    };
    assert!(!e.is_null(), "bad blob");
    println!("model loaded in {} ms", t0.elapsed().as_millis());
    let script: Vec<Vec<String>> = std::fs::read_to_string(format!("{dir}/script.tsv"))
        .unwrap()
        .lines()
        .map(|l| l.split('\t').map(|s| s.to_string()).collect())
        .collect();
    let expected: Vec<f32> = std::fs::read(format!("{dir}/dart.f32"))
        .unwrap()
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect();
    let mut out = vec![0f32; expected.len()];
    let mut next = 0;
    let mut pos = 0i64;
    let t1 = std::time::Instant::now();
    while pos < total {
        let n = (total - pos).min(1024);
        while next < script.len() {
            let f = &script[next];
            let at: i64 = f[0].parse().unwrap();
            if at >= pos + n + 100000 {
                break;
            }
            // at op id value seek has_late late flag keep_tail name sound via
            let text = |k: usize| CString::new(f[k].clone()).unwrap();
            let (name, sound, via) = (text(9), text(10), text(11));
            let ptr = |k: usize, c: &CString| {
                if f[k] == "-" {
                    std::ptr::null()
                } else {
                    c.as_ptr()
                }
            };
            // SAFETY: `e` is live; the strings are NUL-terminated and outlive the call.
            let r = unsafe {
                prismarine_mix_post(
                    e,
                    f[1].parse().unwrap(),
                    f[2].parse().unwrap(),
                    at,
                    f[3].parse().unwrap(),
                    f[4].parse().unwrap(),
                    f[5].parse().unwrap(),
                    f[6].parse().unwrap(),
                    f[7].parse().unwrap(),
                    f[8].parse().unwrap(),
                    ptr(9, &name),
                    ptr(10, &sound),
                    ptr(11, &via),
                )
            };
            assert_eq!(r, 0, "ring full");
            next += 1;
        }
        // SAFETY: `e` is live; `out` has room for n frames from pos.
        unsafe { prismarine_mix_render(e, out[(pos * 2) as usize..].as_mut_ptr(), n) };
        pos += n;
    }
    println!(
        "native render: {:.1} s in {} ms",
        total as f64 / 48000.0,
        t1.elapsed().as_millis()
    );
    let mut first = None;
    let mut diffs = 0usize;
    let mut maxd = 0f32;
    for i in 0..expected.len() {
        if expected[i].to_bits() != out[i].to_bits() {
            diffs += 1;
            maxd = maxd.max((expected[i] - out[i]).abs());
            if first.is_none() {
                first = Some(i);
            }
        }
    }
    let mut buf = [0u8; 256];
    let mut problems = Vec::new();
    loop {
        // SAFETY: `e` is live; `buf` holds 256 bytes.
        let n = unsafe { prismarine_mix_problem(e, buf.as_mut_ptr(), 256) };
        if n == 0 {
            break;
        }
        problems.push(String::from_utf8_lossy(&buf[..n as usize]).into_owned());
    }
    problems.sort();
    std::fs::write(format!("{dir}/native_problems.txt"), problems.join("\n")).unwrap();
    std::fs::write(
        format!("{dir}/native.f32"),
        out.iter()
            .flat_map(|v| v.to_le_bytes())
            .collect::<Vec<u8>>(),
    )
    .unwrap();
    // SAFETY: `e` is live and not used after.
    unsafe { prismarine_mix_destroy(e) };
    match first {
        None => println!("IDENTICAL: {} samples", expected.len()),
        Some(i) => {
            println!(
                "DIFFER: {diffs} samples, first at frame {} ({:.3} s), max |d| {maxd:e}",
                i / 2,
                (i / 2) as f64 / 48000.0
            );
            std::process::exit(1);
        }
    }
}
