//! Decodes every .mp3 and .ogg file under a directory with the vendored
//! decoders. Prints one line per file with the path, frames, channels, rate
//! and the FNV-1a 64 of the float32 bits, then the hash of all lines. Run it
//! on each target and compare the output. Decoded PCM must be identical
//! across architectures and platforms.
//!
//! Run it with `cargo run --release --example decode_hash -- <dir> [threads]`.

use prismarine_audio_out::decode::codec::decode_file;

fn fnv(h: &mut u64, bytes: &[u8]) {
    for b in bytes {
        *h ^= *b as u64;
        *h = h.wrapping_mul(0x100000001b3);
    }
}

fn walk(dir: &std::path::Path, out: &mut Vec<String>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            walk(&p, out);
        } else if matches!(p.extension().and_then(|e| e.to_str()), Some("mp3" | "ogg")) {
            out.push(p.to_string_lossy().into_owned());
        }
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args.next().expect("dir");
    let threads: usize = args.next().map(|t| t.parse().unwrap()).unwrap_or(4);
    let mut files = Vec::new();
    walk(std::path::Path::new(&dir), &mut files);
    let mut lines = vec![String::new(); files.len()];
    std::thread::scope(|s| {
        for (t, chunk) in lines
            .chunks_mut(files.len().div_ceil(threads).max(1))
            .enumerate()
        {
            let (files, dir) = (&files, &dir);
            let base = t * files.len().div_ceil(threads).max(1);
            s.spawn(move || {
                for (i, line) in chunk.iter_mut().enumerate() {
                    let path = &files[base + i];
                    let rel = path.strip_prefix(dir.as_str()).unwrap_or(path);
                    *line = match decode_file(path) {
                        Some(p) => {
                            let mut h = 0xcbf29ce484222325u64;
                            for v in &p.samples {
                                fnv(&mut h, &v.to_bits().to_le_bytes());
                            }
                            format!("{rel}\t{}\t{}\t{}\t{h:016x}", p.frames, p.channels, p.rate)
                        }
                        None => format!("{rel}\tfailed"),
                    };
                }
            });
        }
    });
    let mut all = 0xcbf29ce484222325u64;
    for l in &lines {
        println!("{l}");
        fnv(&mut all, l.as_bytes());
        fnv(&mut all, b"\n");
    }
    eprintln!("{} files, total {all:016x}", lines.len());
}
