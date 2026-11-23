//! Biquads, Butterworth Q values, delay lines and shelves.

use super::*;

#[derive(Clone, Copy, Default)]
pub(crate) struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: [f64; 2],
    x2: [f64; 2],
    y1: [f64; 2],
    y2: [f64; 2],
}

impl Biquad {
    pub(crate) fn new() -> Self {
        Biquad {
            b0: 1.0,
            ..Default::default()
        }
    }

    pub(crate) fn set(&mut self, fc: f64, q: f64, high: bool) {
        let f = dclamp(fc, 1.0, (RATE / 2) as f64 - 1.0);
        let w = 2.0 * PI * f / RATE_F;
        let c = cos(w);
        let al = sin(w) / (2.0 * q);
        let a0 = 1.0 + al;
        let b = if high {
            (1.0 + c) / 2.0
        } else {
            (1.0 - c) / 2.0
        };
        self.b0 = b / a0;
        self.b1 = (if high { -(1.0 + c) } else { 1.0 - c }) / a0;
        self.b2 = b / a0;
        self.a1 = -2.0 * c / a0;
        self.a2 = (1.0 - al) / a0;
    }

    pub(crate) fn peaking(&mut self, fc: f64, bandwidth: f64, gain_db: f64) {
        let f = dclamp(fc, 1.0, (RATE / 2) as f64 - 1.0);
        let w = 2.0 * PI * f / RATE_F;
        let c = cos(w);
        let al = sin(w) * dmax(bandwidth, 1e-3) / 2.0;
        let a = dpow(10.0, gain_db / 20.0);
        let a0 = 1.0 + al / a;
        self.b0 = (1.0 + al * a) / a0;
        self.b1 = -2.0 * c / a0;
        self.b2 = (1.0 - al * a) / a0;
        self.a1 = -2.0 * c / a0;
        self.a2 = (1.0 - al / a) / a0;
    }

    #[inline]
    pub(crate) fn tick(&mut self, ch: usize, x: f64) -> f64 {
        let y = self.b0 * x + self.b1 * self.x1[ch] + self.b2 * self.x2[ch]
            - self.a1 * self.y1[ch]
            - self.a2 * self.y2[ch];
        self.x2[ch] = self.x1[ch];
        self.x1[ch] = x;
        self.y2[ch] = self.y1[ch];
        self.y1[ch] = y;
        y
    }
}

pub(crate) fn butterworth4(k: usize) -> f64 {
    let a = if k == 0 { PI / 8.0 } else { 3.0 * PI / 8.0 };
    1.0 / (2.0 * cos(opaque(a)))
}

pub(crate) fn comp_smooth() -> f64 {
    one_pole(opaque(2.0))
}

/// A stereo delay line (_Line). Its buffer is allocated once, at its
/// largest size, when the DSP is built; growing it (Dart's `size`, a new
/// zeroed buffer) clears it within that room.
pub(crate) struct Line {
    pub(crate) b: Vec<f32>,
    w: i64,
    /// A delay the room couldn't hold was asked for (reported, kept short).
    pub(crate) refused: bool,
}

impl Line {
    /// Room for delays of up to [frames] frames.
    pub(crate) fn with_room(frames: i64) -> Self {
        let mut b = Vec::with_capacity(((frames.max(0) + 2) * 2) as usize);
        b.resize(2, 0.0);
        Line {
            b,
            w: 0,
            refused: false,
        }
    }
    /// Back to Dart's new `_Line` (two zeroed samples), keeping the room.
    pub(crate) fn reset(&mut self) {
        self.b.clear();
        self.b.resize(2, 0.0);
        self.w = 0;
    }
    /// Room for a delay of [frames]; the delay it holds (less when the room
    /// is too small: refused).
    pub(crate) fn size(&mut self, frames: i64) -> i64 {
        let mut need = ((frames + 2) * 2) as usize;
        if need > self.b.capacity() {
            self.refused = true;
            need = self.b.capacity() & !1;
        }
        if self.b.len() >= need {
            return frames.min(self.frames() - 2).max(1);
        }
        self.b.clear();
        self.b.resize(need, 0.0);
        self.w = 0;
        frames.min(self.frames() - 2).max(1)
    }
    #[inline]
    fn frames(&self) -> i64 {
        self.b.len() as i64 / 2
    }
    #[inline]
    pub(crate) fn write(&mut self, ch: usize, v: f64) {
        self.b[(self.w * 2) as usize + ch] = v as f32;
    }
    #[inline]
    pub(crate) fn read(&self, ch: usize, d: i64) -> f64 {
        let mut i = self.w - d;
        if i < 0 {
            i += self.frames();
        }
        self.b[(i * 2) as usize + ch] as f64
    }
    #[inline]
    pub(crate) fn advance(&mut self) {
        self.w += 1;
        if self.w == self.frames() {
            self.w = 0;
        }
    }
}

#[derive(Default, Clone, Copy)]
pub(crate) struct Shelf {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
    flat: bool,
}

impl Shelf {
    pub(crate) fn set(&mut self, f: f64, db: f64) {
        self.flat = db.abs() < 1e-6;
        if self.flat {
            return;
        }
        let a = dpow(10.0, db / 40.0);
        let w = 2.0 * PI * dclamp(f, 20.0, 1000.0) / RATE_F;
        let c = cos(w);
        let al = sin(w) / 2.0 * SQRT2;
        let sq = 2.0 * a.sqrt() * al;
        let a0 = (a + 1.0) + (a - 1.0) * c + sq;
        self.b0 = a * ((a + 1.0) - (a - 1.0) * c + sq) / a0;
        self.b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * c) / a0;
        self.b2 = a * ((a + 1.0) - (a - 1.0) * c - sq) / a0;
        self.a1 = -2.0 * ((a - 1.0) + (a + 1.0) * c) / a0;
        self.a2 = ((a + 1.0) + (a - 1.0) * c - sq) / a0;
    }
    #[inline]
    pub(crate) fn tick(&mut self, x: f64) -> f64 {
        if self.flat {
            return x;
        }
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}
