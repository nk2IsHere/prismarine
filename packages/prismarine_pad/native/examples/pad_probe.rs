//! Prints what the player would read from the host's pads, through the same
//! functions it calls: the connected pads, then every change of the pad in
//! use (Auto) as the game's buttons, sticks and triggers. For checking a
//! real pad: `cargo run --release --example pad_probe [seconds]`.

use std::time::{Duration, Instant};

use prismarine_pad::{prismarine_pad_device, prismarine_pad_read, PadReading};

const NAMES: [&str; 14] = [
    "A", "B", "X", "Y", "LB", "RB", "Back", "Start", "L3", "R3", "Up", "Down", "Left", "Right",
];

fn text(n: &[u8; 64]) -> String {
    let end = n.iter().position(|b| *b == 0).unwrap_or(64);
    String::from_utf8_lossy(&n[..end]).into_owned()
}

fn hex(b: &[u8; 16]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A reading as a line; sticks and triggers rounded to tenths so rest jitter
/// doesn't print.
fn line(r: &PadReading) -> String {
    if r.unavailable != 0 {
        return "SDL could not start".into();
    }
    if r.connected == 0 {
        return "no pad".into();
    }
    let held: Vec<&str> = (0..14)
        .filter(|i| r.buttons >> i & 1 != 0)
        .map(|i| NAMES[i])
        .collect();
    let t = |v: f32| (v * 10.0).round() / 10.0;
    format!(
        "{}: [{}] left ({:+.1}, {:+.1}) right ({:+.1}, {:+.1}) LT {:.1} RT {:.1}",
        text(&r.name),
        held.join(" "),
        t(r.left_x),
        t(r.left_y),
        t(r.right_x),
        t(r.right_y),
        t(r.left_trigger),
        t(r.right_trigger),
    )
}

fn main() {
    let secs: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(120);
    let t0 = Instant::now();
    let first = prismarine_pad_read();
    println!("started in {:?}", t0.elapsed());
    for i in 0.. {
        let d = prismarine_pad_device(i);
        if d.present == 0 {
            break;
        }
        println!(
            "pad {i}: {} (GUID {} #{})",
            text(&d.name),
            hex(&d.uuid),
            d.nth
        );
    }
    let mut last = line(&first);
    println!("{:8.3}s {last}", t0.elapsed().as_secs_f64());
    while t0.elapsed() < Duration::from_secs(secs) {
        std::thread::sleep(Duration::from_millis(16));
        let now = line(&prismarine_pad_read());
        if now != last {
            println!("{:8.3}s {now}", t0.elapsed().as_secs_f64());
            last = now;
        }
    }
}
