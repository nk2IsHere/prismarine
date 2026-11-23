//! The DSPs' unit tests.

use super::*;

fn run(d: &mut Dsp, seed: u32) -> Vec<f32> {
    let mut x = seed;
    let mut buf: Vec<f32> = (0..256 * 2)
        .map(|_| {
            x = x.wrapping_mul(1664525).wrapping_add(1013904223);
            (x >> 8) as f32 / (1u32 << 24) as f32 - 0.5
        })
        .collect();
    d.process(&mut buf, 256, false, None);
    buf
}

/// A reset DSP, as of a recycled nested event, runs as a new one.
#[test]
fn reset_is_new() {
    static TAPS: [f64; 64] = [0.0; 64];
    let taps: &'static [f64] = &TAPS;
    for kind in [
        LOWPASS, HIGHPASS, ECHO, FLANGE, DISTORTION, PARAMEQ, LIMITER, COMPRESSOR, TREMOLO, PAN,
        THREEEQ, CHORUS, MBEQ, CHANMIX, OBJPAN,
    ] {
        let mut fresh = Dsp::new(kind, taps, 48000).unwrap();
        fresh.set(0, fresh.p[0] * 0.5);
        let a = run(&mut fresh, 1);
        let mut used = Dsp::new(kind, taps, 48000).unwrap();
        used.set(0, used.p[0] * 0.25);
        run(&mut used, 7);
        run(&mut used, 9);
        used.reset();
        used.set(0, used.p[0] * 0.5);
        assert_eq!(a, run(&mut used, 1), "kind {kind}");
    }
}

/// An echo grows within the room it was built with and refuses more.
#[test]
fn echo_grows_within_its_room() {
    let mut d = Dsp::new(ECHO, &[], 48 * 1000).unwrap();
    assert!(!d.take_refused());
    let State::Echo { line, .. } = &d.st else {
        unreachable!()
    };
    let (p, cap) = (line.b.as_ptr(), line.b.capacity());
    d.set(0, 1000.0);
    assert!(!d.take_refused());
    d.set(0, 2000.0);
    assert!(d.take_refused());
    let State::Echo { line, d: delay, .. } = &d.st else {
        unreachable!()
    };
    assert_eq!(
        (line.b.as_ptr(), line.b.capacity(), line.b.len(), *delay),
        (p, cap, (48000 + 2) * 2, 48000)
    );
    // A short room still plays the longest delay that it holds.
    let mut short = Dsp::new(ECHO, &[], 100).unwrap();
    assert!(short.take_refused());
    run(&mut short, 3);
}

#[test]
fn keys_hold_one_buffer_each() {
    let mut k = Keys::with(2, 8);
    let a = k.alloc(&[1.0; 8]).unwrap();
    k.slot[0] = Some(a);
    let b = k.alloc(&[2.0; 8]).unwrap();
    assert_ne!(a, b);
    k.slot[1] = Some(b);
    assert!(k.alloc(&[3.0; 8]).is_none());
    k.slot[0] = None;
    assert_eq!(k.alloc(&[4.0; 4]), Some(a));
    assert!(k.alloc(&[5.0; 9]).is_none());
}

/// The surround panner against reference matrices. The Dart test holds the
/// full table.
#[test]
fn surround_matches_the_oracle() {
    let cases: [(f64, f64, [f64; 6]); 4] = [
        (45.0, 0.0, [0.0, 0.9616, 0.0, 0.0, 0.0, 0.2746]),
        (0.0, 90.0, [0.4709, 0.4709, 0.7458, 0.0, 0.0134, 0.0134]),
        (-135.0, 270.0, [0.6080, 0.0195, 0.3040, 0.0, 0.6080, 0.4097]),
        (90.0, 360.0, [0.4472, 0.4472, 0.4472, 0.0, 0.4472, 0.4472]),
    ];
    for (d, e, want) in cases {
        let mut g = [0.0; 6];
        crate::mix::surround::mono(d, e, 1.0, 0.0, &mut g);
        for c in 0..6 {
            assert!((g[c] - want[c]).abs() < 2e-4, "d {d} e {e} channel {c}");
        }
    }
}

/// The peaking band of the multiband EQ gives +12 dB at its centre and a
/// 0 dB band passes the input untouched.
#[test]
fn mbeq_peak_and_bypass() {
    static TAPS: [f64; 64] = [0.0; 64];
    let mut d = Dsp::new(MBEQ, &TAPS, 0).unwrap();
    for (i, v) in [9.0, 1000.0, 2.0, 0.0].into_iter().enumerate() {
        d.set(i, v);
    }
    d.start();
    let x = run(&mut Dsp::new(DISTORTION, &TAPS, 0).unwrap(), 3);
    let mut y = x.clone();
    let _ = d.process(&mut y, 256, false, None);
    assert_eq!(x, y);
    d.set(3, 12.0);
    d.start();
    let n = 16384;
    let mut h = vec![0.0f32; n * 2];
    h[0] = 1.0;
    h[1] = 1.0;
    for at in (0..n).step_by(1024) {
        d.process(&mut h[at * 2..(at + 1024) * 2], 1024, false, None);
    }
    let (mut re, mut im) = (0.0, 0.0);
    for i in 0..n {
        let w = 2.0 * PI * 1000.0 * i as f64 / 48000.0;
        re += h[i * 2] as f64 * cos(w);
        im -= h[i * 2] as f64 * sin(w);
    }
    let db = 10.0 * log(re * re + im * im) / LN10;
    assert!((db - 12.0).abs() < 0.05, "{db}");
}
