//! The multiband EQ and the channel mix, as dsp_eq.dart and dsp_mix.dart
//! operation for operation.

use super::*;

/// One band of the multiband EQ as Dart's `EqBand`, up to four identical
/// TDF2 sections whose shared coefficients glide to a new design over a
/// block.
#[derive(Clone, Copy)]
pub(crate) struct EqBand {
    sections: usize,
    c: [f64; 5],
    to: [f64; 5],
    gliding: bool,
    s1: [f64; 24],
    s2: [f64; 24],
}

pub(crate) const D_MBEQ: &[f64] = &[
    1.0, 8000.0, 0.707, 0.0, 0.0, 8000.0, 0.707, 0.0, 0.0, 8000.0, 0.707, 0.0, 0.0, 8000.0, 0.707,
    0.0, 0.0, 8000.0, 0.707, 0.0,
];

impl EqBand {
    pub(crate) fn new() -> EqBand {
        EqBand {
            sections: 0,
            c: [1.0, 0.0, 0.0, 0.0, 0.0],
            to: [1.0, 0.0, 0.0, 0.0, 0.0],
            gliding: false,
            s1: [0.0; 24],
            s2: [0.0; 24],
        }
    }

    /// Designs band `b` from `p` as the target.
    pub(crate) fn design(&mut self, p: &[f64], b: usize) {
        let ty = p[b * 4].round() as i64;
        let (q, gain) = (p[b * 4 + 2], p[b * 4 + 3]);
        let f = dclamp(p[b * 4 + 1], 20.0, 22000.0);
        let n: usize = match ty {
            1 | 4 | 10 | 11 | 12 => 1,
            2 | 5 => 2,
            3 | 6 => 4,
            7..=9 => {
                if gain == 0.0 {
                    0
                } else {
                    1
                }
            }
            _ => 0,
        };
        if n == 0 {
            self.sections = 0;
            self.gliding = false;
            return;
        }
        let w = 2.0 * PI * f / RATE_F;
        let (cw, sw) = (cos(w), sin(w));
        let a = dpow(10.0, gain / 40.0);
        let qq = if n == 1 { q } else { dpow(q, 1.0 / n as f64) };
        let mut al = sw / (2.0 * qq);
        let (b0, b1, b2, a0, a1, a2);
        match ty {
            1..=3 => {
                b0 = (1.0 - cw) / 2.0;
                b1 = 1.0 - cw;
                b2 = b0;
                a0 = 1.0 + al;
                a1 = -2.0 * cw;
                a2 = 1.0 - al;
            }
            4..=6 => {
                b0 = (1.0 + cw) / 2.0;
                b1 = -(1.0 + cw);
                b2 = b0;
                a0 = 1.0 + al;
                a1 = -2.0 * cw;
                a2 = 1.0 - al;
            }
            7 | 8 => {
                al = sw * std::f64::consts::FRAC_1_SQRT_2;
                let sq = 2.0 * a.sqrt() * al;
                let s = if ty == 7 { 1.0 } else { -1.0 };
                b0 = a * ((a + 1.0) - s * (a - 1.0) * cw + sq);
                b1 = s * 2.0 * a * ((a - 1.0) - s * (a + 1.0) * cw);
                b2 = a * ((a + 1.0) - s * (a - 1.0) * cw - sq);
                a0 = (a + 1.0) + s * (a - 1.0) * cw + sq;
                a1 = -s * 2.0 * ((a - 1.0) + s * (a + 1.0) * cw);
                a2 = (a + 1.0) + s * (a - 1.0) * cw - sq;
            }
            9 => {
                b0 = 1.0 + al * a;
                b1 = -2.0 * cw;
                b2 = 1.0 - al * a;
                a0 = 1.0 + al / a;
                a1 = -2.0 * cw;
                a2 = 1.0 - al / a;
            }
            10 => {
                b0 = al;
                b1 = 0.0;
                b2 = -al;
                a0 = 1.0 + al;
                a1 = -2.0 * cw;
                a2 = 1.0 - al;
            }
            11 => {
                b0 = 1.0;
                b1 = -2.0 * cw;
                b2 = 1.0;
                a0 = 1.0 + al;
                a1 = -2.0 * cw;
                a2 = 1.0 - al;
            }
            _ => {
                b0 = 1.0 - al;
                b1 = -2.0 * cw;
                b2 = 1.0 + al;
                a0 = 1.0 + al;
                a1 = -2.0 * cw;
                a2 = 1.0 - al;
            }
        }
        if self.sections != n {
            if self.sections == 0 {
                self.c = [1.0, 0.0, 0.0, 0.0, 0.0];
            }
            self.s1 = [0.0; 24];
            self.s2 = [0.0; 24];
        }
        self.sections = n;
        self.to = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
        self.gliding = true;
    }

    pub(crate) fn settle(&mut self) {
        self.c = self.to;
        self.gliding = false;
    }

    /// Runs `frames` frames of `buf`, `ch` channels interleaved, through the
    /// sections.
    pub(crate) fn run(&mut self, buf: &mut [f32], frames: usize, ch: usize) {
        if self.sections == 0 {
            return;
        }
        if self.gliding {
            self.glide(buf, frames, ch);
            return;
        }
        let [b0, b1, b2, a1, a2] = self.c;
        for s in 0..self.sections {
            for k in 0..ch {
                let j = s * 6 + k;
                let (mut s1, mut s2) = (self.s1[j], self.s2[j]);
                for i in 0..frames {
                    let x = buf[i * ch + k] as f64;
                    let y = b0 * x + s1;
                    s1 = b1 * x - a1 * y + s2;
                    s2 = b2 * x - a2 * y;
                    buf[i * ch + k] = y as f32;
                }
                self.s1[j] = s1;
                self.s2[j] = s2;
            }
        }
    }

    fn glide(&mut self, buf: &mut [f32], frames: usize, ch: usize) {
        let from = self.c;
        let mut k0 = [0.0; 5];
        for i in 0..frames {
            let t = i as f64 / frames as f64;
            for m in 0..5 {
                k0[m] = from[m] + (self.to[m] - from[m]) * t;
            }
            for s in 0..self.sections {
                for k in 0..ch {
                    let j = s * 6 + k;
                    let x = buf[i * ch + k] as f64;
                    let y = k0[0] * x + self.s1[j];
                    self.s1[j] = k0[1] * x - k0[3] * y + self.s2[j];
                    self.s2[j] = k0[2] * x - k0[4] * y;
                    buf[i * ch + k] = y as f32;
                }
            }
        }
        self.settle();
    }
}

/// The gains of the channel mix as Dart's `ChannelMix`, the gains now, their
/// targets, the start of the ramp and its progress into its 64 samples.
pub(crate) struct Mix {
    g: [f64; 32],
    to: [f64; 32],
    from: [f64; 32],
    ramp: bool,
    done: usize,
}

pub(crate) const D_MIX: &[f64] = &[0.0; 33];

impl Mix {
    pub(crate) fn new() -> Mix {
        Mix {
            g: [1.0; 32],
            to: [1.0; 32],
            from: [1.0; 32],
            ramp: false,
            done: 0,
        }
    }

    fn gain(p: &[f64], c: usize) -> f64 {
        if p[0].round() as i64 == 6 {
            0.0
        } else {
            db_gain(p[c + 1])
        }
    }

    pub(crate) fn changed(&mut self, p: &[f64], index: usize) {
        if index == 0 {
            return;
        }
        self.to[index - 1] = Mix::gain(p, index - 1);
        self.from = self.g;
        self.ramp = true;
        self.done = 0;
    }

    pub(crate) fn start(&mut self, p: &[f64]) {
        for c in 0..32 {
            self.to[c] = Mix::gain(p, c);
        }
        self.g = self.to;
        self.ramp = false;
    }

    /// Mixes `frames` frames of `buf` with `ch` channels. With `dual` a mono
    /// signal in both channels takes the gain of channel 0 on both.
    pub(crate) fn run(&mut self, buf: &mut [f32], frames: usize, ch: usize, dual: bool) {
        let mut i = 0;
        if self.ramp {
            while i < frames && self.done < 64 {
                let t = self.done as f64 / 64.0;
                for c in 0..ch {
                    let k = if dual { 0 } else { c };
                    let v = buf[i * ch + c] as f64;
                    buf[i * ch + c] = (v * (self.from[k] + (self.to[k] - self.from[k]) * t)) as f32;
                }
                i += 1;
                self.done += 1;
            }
            if self.done >= 64 {
                self.g = self.to;
                self.ramp = false;
            }
        }
        for c in 0..ch {
            let g = self.g[if dual { 0 } else { c }];
            if g == 1.0 {
                continue;
            }
            for j in i..frames {
                buf[j * ch + c] = (buf[j * ch + c] as f64 * g) as f32;
            }
        }
    }
}
