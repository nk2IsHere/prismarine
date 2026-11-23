//! Processing a block through a DSP, and the tremolo's LFO.

use super::*;

impl Dsp {
    /// Processes [frames] frames of the stereo [buf] in place. With [mono]
    /// the signal is mono in both channels. [key] is the sidechain key of a
    /// compressor in this block, which the caller drops afterwards. Returns
    /// whether the output is still mono.
    pub fn process(
        &mut self,
        buf: &mut [f32],
        frames: usize,
        mono: bool,
        key: Option<&[f32]>,
    ) -> bool {
        let p = &self.p;
        match &mut self.st {
            State::Lowpass(s) => {
                if p[0] >= 22000.0 && p[1] <= 1.0 && !self.keep22k {
                    return mono;
                }
                for i in 0..frames {
                    for ch in 0..2 {
                        let x = buf[i * 2 + ch] as f64;
                        let y0 = s[0].tick(ch, x);
                        buf[i * 2 + ch] = s[1].tick(ch, y0) as f32;
                    }
                }
                mono
            }
            State::ThreeEq { low, mid, high } => {
                let (gl, gm, gh) = (db_gain(p[0]), db_gain(p[1]), db_gain(p[2]));
                for i in 0..frames {
                    for ch in 0..2 {
                        let x = buf[i * 2 + ch] as f64;
                        let l0 = low[0].tick(ch, x);
                        let lo = low[1].tick(ch, l0);
                        let mut m = x;
                        for b in mid.iter_mut() {
                            m = b.tick(ch, m);
                        }
                        let h0 = high[0].tick(ch, x);
                        let hi = high[1].tick(ch, h0);
                        buf[i * 2 + ch] = (gl * lo + gm * m + gh * hi) as f32;
                    }
                }
                mono
            }
            State::Pan { az, dist } => {
                let th = (dclamp(p[1], -100.0, 100.0) + 100.0) / 200.0 * PI / 2.0;
                let k = if mono { 1.0 } else { SQRT2 };
                let (l, r) = (k * cos(th), k * sin(th));
                let blend = p[17];
                if p[0] != 2.0 || blend <= 0.0 {
                    for i in 0..frames {
                        buf[i * 2] = (buf[i * 2] as f64 * l) as f32;
                        buf[i * 2 + 1] = (buf[i * 2 + 1] as f64 * r) as f32;
                    }
                    return false;
                }
                let g = crate::mix::spatial::gains(p, *az, *dist, mono);
                let b = if blend > 1.0 { 1.0 } else { blend };
                let d2 = 1.0 - b;
                let ll = g[0] * b + d2 * l;
                let rr = g[3] * b + d2 * r;
                let (rl, lr) = (g[1] * b, g[2] * b);
                if mono {
                    let mr = lr + d2 * r;
                    for i in 0..frames {
                        buf[i * 2] = (buf[i * 2] as f64 * ll) as f32;
                        buf[i * 2 + 1] = (buf[i * 2 + 1] as f64 * mr) as f32;
                    }
                    return false;
                }
                for i in 0..frames {
                    let (x, y) = (buf[i * 2] as f64, buf[i * 2 + 1] as f64);
                    buf[i * 2] = (x * ll + y * rl) as f32;
                    buf[i * 2 + 1] = (x * lr + y * rr) as f32;
                }
                false
            }
            State::One(b) => {
                if self.kind == PARAMEQ && p[2] == 0.0 {
                    return mono;
                }
                for i in 0..frames * 2 {
                    buf[i] = b.tick(i & 1, buf[i] as f64) as f32;
                }
                mono
            }
            State::Distortion => {
                let l = dclamp(p[0], 0.0, 0.9999);
                if l == 0.0 {
                    return mono;
                }
                let k = 2.0 * l / (1.0 - l);
                for v in buf[..frames * 2].iter_mut() {
                    let x = *v as f64;
                    *v = ((1.0 + k) * x / (1.0 + k * x.abs())) as f32;
                }
                mono
            }
            State::Compressor {
                use_sidechain,
                env,
                gr,
                envs,
                grs,
            } => {
                if p[6] < 0.5 && !*use_sidechain {
                    comp_unlinked(p, envs, grs, buf, frames, 2);
                    return mono;
                }
                let keyed = *use_sidechain;
                let aa = one_pole(p[2] / 2.0);
                let ar = one_pole(p[3] / 2.0);
                let s = 1.0 - 1.0 / dmax(1.0, p[1]);
                let (thr, makeup) = (p[0], p[4]);
                let smooth = comp_smooth();
                let kbuf: Option<&[f32]> = if keyed { key } else { None };
                let (mut e_v, mut g_v) = (*env, *gr);
                for i in 0..frames {
                    let e = if keyed {
                        match kbuf {
                            None => 0.0,
                            Some(kb) => {
                                let (l, r) = (kb[i * 2] as f64, kb[i * 2 + 1] as f64);
                                l * l + r * r
                            }
                        }
                    } else {
                        let (l, r) = (buf[i * 2] as f64, buf[i * 2 + 1] as f64);
                        if mono {
                            l * l
                        } else {
                            l * l + r * r
                        }
                    };
                    e_v += (e - e_v) * (if e > e_v { aa } else { ar });
                    let lvl = 10.0 * log(e_v + 1e-30) / LN10;
                    let g_r = if lvl > thr { s * (lvl - thr) } else { 0.0 };
                    g_v += (g_r - g_v) * smooth;
                    let g = dpow(10.0, (makeup - g_v) / 20.0);
                    buf[i * 2] = (buf[i * 2] as f64 * g) as f32;
                    buf[i * 2 + 1] = (buf[i * 2 + 1] as f64 * g) as f32;
                }
                *env = e_v;
                *gr = g_v;
                mono
            }
            State::Limiter { g, fresh } => {
                *fresh = false;
                let c = db_gain(p[1]);
                let up = exp(1.0 / (dmax(p[0], 0.01) * 1e-3 * RATE_F));
                let pre = db_gain(p[2]);
                let linked = p[3] >= 0.5;
                for i in 0..frames {
                    let mut a0 = (buf[i * 2] as f64 * pre).abs();
                    let mut a1 = (buf[i * 2 + 1] as f64 * pre).abs();
                    if linked {
                        a0 = dmax(a0, a1);
                        a1 = a0;
                    }
                    for ch in 0..2 {
                        let a = if ch == 0 { a0 } else { a1 };
                        let t = if a > c { c / a } else { 1.0 };
                        let gg = g[ch];
                        g[ch] = if t < gg { t } else { dmin(t, gg * up) };
                        buf[i * 2 + ch] = (buf[i * 2 + ch] as f64 * (pre * g[ch])) as f32;
                    }
                }
                mono
            }
            State::Tremolo { t } => {
                let f = dmax(p[0], 0.1);
                let depth = dclamp(p[1], 0.0, 1.0);
                let (ph, spread) = (p[6], p[7] / 4.0);
                for i in 0..frames {
                    let pp = *t * f + ph;
                    let gl = 1.0 - depth + depth * trem_lfo(p, pp + spread);
                    let gr = if spread == 0.0 {
                        gl
                    } else {
                        1.0 - depth + depth * trem_lfo(p, pp - spread)
                    };
                    buf[i * 2] = (buf[i * 2] as f64 * gl) as f32;
                    buf[i * 2 + 1] = (buf[i * 2 + 1] as f64 * gr) as f32;
                    *t += 1.0 / RATE_F;
                }
                mono && spread == 0.0
            }
            State::Echo { line, d, quiet } => {
                let fb = dclamp(p[1], 0.0, 100.0) / 100.0;
                let (dry, wet) = (db_gain(p[2]), db_gain(p[3]));
                for i in 0..frames {
                    let mut loud = false;
                    for ch in 0..2 {
                        let x = buf[i * 2 + ch] as f64;
                        let out = line.read(ch, *d);
                        let w = x + fb * out;
                        line.write(ch, w);
                        if w.abs() > 1e-9 {
                            loud = true;
                        }
                        buf[i * 2 + ch] = (dry * x + wet * out) as f32;
                    }
                    line.advance();
                    *quiet = if loud { 0 } else { *quiet + 1 };
                }
                mono
            }
            State::Flange { line, phase, quiet } => {
                let mix = dclamp(p[0], 0.0, 100.0) / 100.0;
                let inc = (p[2] / RATE_F) as f32 as f64;
                let mut ph = *phase;
                for i in 0..frames {
                    let dl = (960 / 2) as f64 * (1.0 - cos(2.0 * PI * ph));
                    let k = dfloor(dl);
                    let fr = dl - k as f64;
                    let mut loud = false;
                    for ch in 0..2 {
                        let x = buf[i * 2 + ch] as f64;
                        line.write(ch, x);
                        if x.abs() > 1e-9 {
                            loud = true;
                        }
                        let (a, b) = (line.read(ch, k), line.read(ch, k + 1));
                        buf[i * 2 + ch] = ((1.0 - mix) * x + mix * (a + (b - a) * fr)) as f32;
                    }
                    line.advance();
                    *quiet = if loud { 0 } else { *quiet + 1 };
                    ph = (ph + inc) as f32 as f64;
                    if ph >= 1.0 {
                        ph = (ph - 1.0) as f32 as f64;
                    }
                }
                *phase = ph;
                mono
            }
            State::Chorus(c) => c.process(p, buf, frames, mono),
            State::Eq(bands) => {
                for b in bands.iter_mut() {
                    b.run(buf, frames, 2);
                }
                mono
            }
            State::Mix(m) => {
                m.run(buf, frames, 2, mono);
                mono
            }
            State::Silence => {
                buf[..frames * 2].fill(0.0);
                mono
            }
            State::Reverb(r) => {
                rv_process(r, p, buf, frames);
                false
            }
        }
    }
}

fn trem_lfo(p: &[f64], pp: f64) -> f64 {
    let mut p0 = dmod(pp, 1.0);
    if p0 < 0.0 {
        p0 += 1.0;
    }
    let d = dclamp(p[4], 0.01, 0.99);
    let mut v = if d >= 0.5 {
        let r = 1.0 - d;
        if p0 < r {
            p0 / r
        } else if p0 < d {
            1.0
        } else {
            (1.0 - p0) / r
        }
    } else if p0 < d {
        p0 / d
    } else if p0 < 2.0 * d {
        (2.0 * d - p0) / d
    } else {
        0.0
    };
    let sine = 0.5 - 0.5 * cos(PI * v);
    v += (sine - v) * dclamp(p[2], 0.0, 1.0);
    let sq = dclamp(p[5], 0.0, 1.0);
    if sq > 0.0 {
        v += ((if v < 0.5 { 0.0 } else { 1.0 }) - v) * sq;
    }
    v
}

/// The unlinked compressor, which detects and compresses each of [ch]
/// channels on its own, as Dart's `Compressor._unlinked`.
pub(super) fn comp_unlinked(
    p: &[f64],
    envs: &mut [f64; 6],
    grs: &mut [f64; 6],
    buf: &mut [f32],
    frames: usize,
    ch: usize,
) {
    let aa = one_pole(p[2] / 2.0);
    let ar = one_pole(p[3] / 2.0);
    let s = 1.0 - 1.0 / dmax(1.0, p[1]);
    let (thr, makeup) = (p[0], p[4]);
    let smooth = comp_smooth();
    for i in 0..frames {
        for c in 0..ch {
            let x = buf[i * ch + c] as f64;
            let e = x * x;
            envs[c] += (e - envs[c]) * (if e > envs[c] { aa } else { ar });
            let lvl = 10.0 * log(envs[c] + 1e-30) / LN10;
            let g_r = if lvl > thr { s * (lvl - thr) } else { 0.0 };
            grs[c] += (g_r - grs[c]) * smooth;
            buf[i * ch + c] = (x * dpow(10.0, (makeup - grs[c]) / 20.0)) as f32;
        }
    }
}
