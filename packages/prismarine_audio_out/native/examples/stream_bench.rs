//! Checks the load of the stream feeder. Opens the given Ogg files as streams at once, as music
//! stems that start together. Reads each in real time with 1024-frame callbacks every 21.3 ms for a
//! while. Reports the frames read as silence per stream. `--cue=<s>` also cues each stream at that
//! point 0.4 s ahead and jumps there, as a section change does. `--load=<n>` keeps n busy threads
//! running beside it, as on a loaded machine.
//!
//!   cargo run --release --example stream_bench -- [--seconds=8] [--cue=20] [--load=8] <file.ogg>...
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use prismarine_audio_out::decode::stream::Stream;

fn opt(args: &[String], name: &str) -> Option<f64> {
    args.iter().find_map(|a| {
        a.strip_prefix(&format!("--{name}="))
            .and_then(|v| v.parse().ok())
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let seconds = opt(&args, "seconds").unwrap_or(8.0);
    let cue = opt(&args, "cue");
    let load = opt(&args, "load").unwrap_or(0.0) as usize;
    // With --offset=<s> each stream starts reading there, as a loop with a
    // random start offset does. With --hold it waits until the stream holds
    // that position and the wait is reported.
    let offset = opt(&args, "offset");
    let hold = args.iter().any(|a| a == "--hold");
    let files: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let stop = Arc::new(AtomicBool::new(false));
    let busy: Vec<_> = (0..load)
        .map(|_| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut x = 1u64;
                while !stop.load(Ordering::Relaxed) {
                    x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
                }
                x
            })
        })
        .collect();
    let streams: Vec<Stream> = files.iter().map(|f| Stream::open(f, 0.5)).collect();
    // A cue opens a tap of its own with its ring at the jump, 0.4 s before
    // the jump.
    let mut taps: Vec<Option<Stream>> = files.iter().map(|_| None).collect();
    let mut pos = vec![0i64; streams.len()];
    let mut jumped = vec![false; streams.len()];
    let mut started = vec![false; streams.len()];
    let mut held = vec![0usize; streams.len()];
    let mut missing = vec![0i64; streams.len()];
    let mut out = vec![0f32; 1024 * 8];
    let t0 = Instant::now();
    let period = Duration::from_secs_f64(1024.0 / 48000.0);
    let mut next = t0;
    let blocks = (seconds * 48000.0 / 1024.0) as usize;
    for _ in 0..blocks {
        for (i, s0) in streams.iter().enumerate() {
            // A stream is read once it is open.
            if s0.ready() != 1 {
                continue;
            }
            let (_, rate, total) = s0.info();
            let n = (1024.0 * rate as f64 / 48000.0) as i64;
            if !started[i] {
                let at = offset.map_or(0, |o| (o * rate as f64) as i64);
                if hold && !s0.has(at) {
                    if held[i] == 0 {
                        s0.prefetch(at);
                    }
                    held[i] += 1;
                    continue;
                }
                started[i] = true;
                pos[i] = at;
            }
            if let Some(c) = cue {
                let at = (c * rate as f64) as i64;
                if taps[i].is_none() && pos[i] >= (0.1 * rate as f64) as i64 {
                    let t = Stream::open(files[i], 0.5);
                    t.prefetch(at);
                    taps[i] = Some(t);
                }
                if !jumped[i] && pos[i] >= (0.5 * rate as f64) as i64 {
                    jumped[i] = true;
                    pos[i] = at;
                }
            }
            let s = if jumped[i] {
                taps[i].as_ref().unwrap()
            } else {
                s0
            };
            if pos[i] + n <= total {
                s.read(&mut out, pos[i], n);
                pos[i] += n;
            }
            missing[i] += s.take_missing();
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        }
    }
    stop.store(true, Ordering::Relaxed);
    for b in busy {
        let _ = b.join();
    }
    let total: i64 = missing.iter().sum();
    for ((f, m), h) in files.iter().zip(&missing).zip(&held) {
        println!(
            "{m:>8} frames silent, held {:.0} ms  {}",
            *h as f64 * 1024.0 / 48.0,
            f.rsplit('/').next().unwrap_or(f)
        );
    }
    println!(
        "total {total} frames silent over {} streams in {:.1} s",
        files.len(),
        t0.elapsed().as_secs_f64()
    );
}
