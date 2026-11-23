//! The chorus, as prismarine_audio's `Chorus` operation for operation. The
//! arithmetic is float32 except for the read position, which is double, and
//! the delay line holds 16-bit samples.

use crate::mix::dmath::cos;
use std::sync::OnceLock;

/// The frames of the delay line, 120 ms rounded up to whole 1,024-frame
/// blocks, plus one block.
pub const LINE_FRAMES: i64 = 6144;

pub const DEFAULTS: &[f64] = &[100.0, 0.8, 3.0];

const OFFSETS: [f64; 3] = [0.0, 0.25, 0.5];

#[inline]
fn f(x: f64) -> f64 {
    x as f32 as f64
}

static TABLE: OnceLock<Vec<f32>> = OnceLock::new();

/// The 8,192-entry quarter-cosine table, cosf(f32(i·f32(π/2))·2^-13).
fn table() -> &'static [f32] {
    TABLE.get_or_init(|| {
        let half_pi = f(std::f64::consts::PI / 2.0);
        (0..8192)
            .map(|i| cos(f(f(i as f64 * half_pi) * (1.0 / 8192.0))) as f32)
            .collect()
    })
}

pub struct Chorus {
    table: &'static [f32],
    line: Vec<i16>,
    fresh: bool,
    pos: i64,
    phase: f64,
    inc: f64,
    dry: f64,
    target: f64,
    cur: f64,
    w: [f64; 3],
    last_mix: f64,
    last_rate: f64,
    last_depth: f64,
    quiet: i64,
}

fn clamp100(v: f64) -> f64 {
    v.clamp(0.0, 100.0)
}

fn depth_frames(depth: f64) -> f64 {
    let (c4, c3) = (f(1e-4), f(1e-3));
    f(f(f(f(f(48000.0 * depth) * depth) * c4) * c3) * 100.0)
}

impl Chorus {
    /// Makes a chorus with all the memory that it will use, off the render
    /// thread.
    pub fn new(p: &[f64]) -> Chorus {
        let mut c = Chorus {
            table: table(),
            line: vec![0; (LINE_FRAMES * 2) as usize],
            fresh: true,
            pos: 0,
            phase: 0.0,
            inc: 0.0,
            dry: 0.0,
            target: 0.0,
            cur: 0.0,
            w: [0.0; 3],
            last_mix: 0.0,
            last_rate: 0.0,
            last_depth: 0.0,
            quiet: 1 << 30,
        };
        c.reset(p);
        c
    }

    /// Resets the chorus to new in the memory that it has.
    pub fn renew(&mut self, p: &[f64]) {
        self.fresh = true;
        self.quiet = 1 << 30;
        self.reset(p);
    }

    fn gains(&mut self, mix: f64) {
        let c01 = f(0.01);
        self.dry = f(200.0 / f(mix + 200.0));
        self.w[0] = f(f(clamp100(f(mix * 2.0)) * c01) * self.dry);
        let m4 = f(mix * 4.0);
        self.w[1] = f(f(clamp100(f(m4 - 200.0)) * c01) * self.dry);
        self.w[2] = f(f(clamp100(f(m4 - 300.0)) * c01) * self.dry);
    }

    fn reset(&mut self, p: &[f64]) {
        self.phase = 0.0;
        self.pos = 0;
        self.line.fill(0);
        self.last_mix = f(p[0]);
        self.gains(self.last_mix);
        self.last_rate = f(p[1]);
        self.last_depth = f(p[2]);
        self.target = depth_frames(self.last_depth);
        self.cur = self.target;
        self.inc = f(self.last_rate / 48000.0);
    }

    fn take(&mut self, p: &[f64]) {
        let (mix, rate, depth) = (f(p[0]), f(p[1]), f(p[2]));
        if depth == self.last_depth && mix == self.last_mix && rate == self.last_rate {
            return;
        }
        let old = self.last_depth;
        self.gains(mix);
        self.last_depth = depth;
        self.last_mix = mix;
        self.last_rate = rate;
        if depth != old {
            self.target = depth_frames(depth);
        }
        self.inc = f(rate / 48000.0);
    }

    fn start(&mut self, p: &[f64]) {
        if self.fresh {
            self.fresh = false;
            self.reset(p);
        }
    }

    fn glide(&mut self) {
        let (t, c) = (self.target, self.cur);
        self.cur = if f(t - 0.03125) > c {
            f(c + 0.03125)
        } else if c > f(t + 0.03125) {
            f(c - 0.03125)
        } else {
            t
        };
    }

    fn step(&mut self) {
        let ph = f(self.phase + self.inc);
        self.phase = if ph > 1.0 { f(ph - 1.0) } else { ph };
        self.pos += 1;
        if self.pos == LINE_FRAMES {
            self.pos = 0;
        }
    }

    pub fn ringing(&self) -> bool {
        self.quiet < LINE_FRAMES
    }

    pub fn idle(&mut self, p: &[f64], frames: i64) {
        self.start(p);
        for _ in 0..frames {
            if self.pos & 1023 == 0 {
                self.take(p);
            }
            self.glide();
            let at = (self.pos * 2) as usize;
            self.line[at] = 0;
            self.line[at + 1] = 0;
            self.step();
        }
        self.quiet += frames;
    }

    fn lfo(&self, x: f64) -> f64 {
        let mut i = f(x * 32768.0) as i64;
        if i < 0 {
            i = -i;
        }
        i &= 0x7fff;
        let t = self.table;
        (match i >> 13 {
            0 => t[i as usize],
            1 => -t[(0x3fff - i) as usize],
            2 => -t[(i - 0x4000) as usize],
            _ => t[(0x7fff - i) as usize],
        }) as f64
    }

    pub fn process(&mut self, p: &[f64], buf: &mut [f32], frames: usize, mono: bool) -> bool {
        self.start(p);
        let nch = if mono { 1 } else { 2 };
        let n = LINE_FRAMES;
        let nf = n as f64;
        for i in 0..frames {
            let j = self.pos & 1023;
            if j == 0 {
                self.take(p);
            }
            self.glide();
            let mut loud = false;
            for c in 0..nch {
                let x = buf[i * 2 + c] as f64;
                self.line[(self.pos * 2) as usize + c] = (f(x * 16384.0) as i64) as i16;
                if x != 0.0 {
                    loud = true;
                }
            }
            for c in 0..nch {
                let v = self.lfo(f(OFFSETS[c] + self.phase));
                let d = self.cur;
                let r = (((v + 1.0) * 0.5 * d - d) + (self.pos - j) as f64) + j as f64;
                let mut rf = f(r);
                if r < 0.0 {
                    rf = f(rf + nf);
                } else if rf >= nf {
                    rf = f(rf - nf);
                }
                let mut r1 = f(rf + 1.0);
                if r1 < 0.0 {
                    r1 = f(r1 + nf);
                } else if r1 >= nf {
                    r1 = f(r1 - nf);
                }
                let (i0, i1) = (rf as i64, r1 as i64);
                let fr = f(rf - i0 as f64);
                let s0 = self.line[(i0.rem_euclid(n) * 2) as usize + c] as f64;
                let sn = self.line[(i1.rem_euclid(n) * 2) as usize + c] as f64;
                let a = f(f(s0 * (1.0 / 16384.0)) * f(1.0 - fr));
                let b = f(f(sn * (1.0 / 16384.0)) * fr);
                let dry = f(buf[i * 2 + c] as f64 * self.dry);
                buf[i * 2 + c] = (f(f(a + b) * self.w[c]) + dry) as f32;
            }
            if mono {
                buf[i * 2 + 1] = buf[i * 2];
            }
            self.quiet = if loud { 0 } else { self.quiet + 1 };
            self.step();
        }
        mono
    }
}
