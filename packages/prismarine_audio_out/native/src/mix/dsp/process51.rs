//! 5.1 processing (Dart `Dsp.process51` and the PAN DSP's `toSurround`), in
//! the same float order.

use super::*;

impl Dsp {
    /// Builds the twins a per-channel DSP runs a 5.1 buffer's other channel
    /// pairs with (Dart builds them at their first use, in the same state),
    /// for blocks of up to `frames`.
    pub fn make_twins(&mut self, taps: &'static [f64], echo_frames: i64, frames: usize) {
        if !matches!(
            self.kind,
            LOWPASS | HIGHPASS | PARAMEQ | DISTORTION | ECHO | THREEEQ
        ) || self.twins.is_some()
        {
            return;
        }
        let kind = self.kind;
        let keep22k = self.keep22k;
        let make = || {
            let mut d = Dsp::new(kind, taps, echo_frames).expect("a known DSP kind");
            d.keep22k = keep22k;
            d
        };
        self.twins = Some(Box::new([make(), make()]));
        self.pair = vec![0.0; frames * 2];
    }

    /// Processes `frames` of a 5.1 buffer (FL FR C LFE SL SR) in place;
    /// false when the DSP has no 5.1 form.
    pub fn process51(&mut self, buf: &mut [f32], frames: usize) -> bool {
        let p = &self.p;
        match &mut self.st {
            State::Eq(bands) => {
                for b in bands.iter_mut() {
                    b.run(buf, frames, 6);
                }
                true
            }
            State::Mix(m) => {
                m.run(buf, frames, 6, false);
                true
            }
            State::Pan { .. } => true,
            State::Silence => {
                buf[..frames * 6].fill(0.0);
                true
            }
            State::Reverb(r) => {
                reverb::rv_process51(r, p, buf, frames);
                true
            }
            State::Compressor {
                envs, grs, env, gr, ..
            } => {
                if p[6] < 0.5 {
                    process::comp_unlinked(p, envs, grs, buf, frames, 6);
                    return true;
                }
                let aa = one_pole(p[2] / 2.0);
                let ar = one_pole(p[3] / 2.0);
                let s = 1.0 - 1.0 / dmax(1.0, p[1]);
                let (thr, makeup) = (p[0], p[4]);
                let smooth = comp_smooth();
                for i in 0..frames {
                    let mut e = 0.0;
                    for c in 0..6 {
                        let x = buf[i * 6 + c] as f64;
                        e += x * x;
                    }
                    *env += (e - *env) * (if e > *env { aa } else { ar });
                    let lvl = 10.0 * log(*env + 1e-30) / LN10;
                    let g_r = if lvl > thr { s * (lvl - thr) } else { 0.0 };
                    *gr += (g_r - *gr) * smooth;
                    let g = dpow(10.0, (makeup - *gr) / 20.0);
                    for c in 0..6 {
                        buf[i * 6 + c] = (buf[i * 6 + c] as f64 * g) as f32;
                    }
                }
                true
            }
            State::Limiter { g, fresh } => {
                *fresh = false;
                let c = db_gain(p[1]);
                let up = exp(1.0 / (dmax(p[0], 0.01) * 1e-3 * RATE_F));
                let pre = db_gain(p[2]);
                let linked = p[3] >= 0.5;
                for i in 0..frames {
                    let mut peak = 0.0;
                    for ch in 0..6 {
                        let a = (buf[i * 6 + ch] as f64 * pre).abs();
                        if a > peak {
                            peak = a;
                        }
                    }
                    for ch in 0..6 {
                        let a = if linked {
                            peak
                        } else {
                            (buf[i * 6 + ch] as f64 * pre).abs()
                        };
                        let t = if a > c { c / a } else { 1.0 };
                        let gg = g[ch];
                        g[ch] = if t < gg { t } else { dmin(t, gg * up) };
                        buf[i * 6 + ch] = (buf[i * 6 + ch] as f64 * (pre * g[ch])) as f32;
                    }
                }
                true
            }
            _ => self.pairs51(buf, frames),
        }
    }

    /// 5.1 as three stereo pairs through this DSP and its twins.
    fn pairs51(&mut self, buf: &mut [f32], frames: usize) -> bool {
        let Some(mut twins) = self.twins.take() else {
            return false;
        };
        let mut pair = std::mem::take(&mut self.pair);
        for k in 0..3 {
            if k > 0 {
                for i in 0..self.p.len() {
                    let v = self.p[i];
                    twins[k - 1].set(i, v);
                }
            }
            for i in 0..frames {
                pair[i * 2] = buf[i * 6 + k * 2];
                pair[i * 2 + 1] = buf[i * 6 + k * 2 + 1];
            }
            if k == 0 {
                self.process(&mut pair, frames, false, None);
            } else {
                twins[k - 1].process(&mut pair, frames, false, None);
            }
            for i in 0..frames {
                buf[i * 6 + k * 2] = pair[i * 2];
                buf[i * 6 + k * 2 + 1] = pair[i * 2 + 1];
            }
        }
        self.pair = pair;
        self.twins = Some(twins);
        true
    }

    /// A surround PAN with a 5.1 target ("Output Speaker" 6, mode 2).
    pub fn surround(&self) -> bool {
        self.kind == PAN && self.p[0].round() as i64 == 2 && self.p[20].round() as i64 == 6
    }

    /// `frames` of `src` (stereo, or mono held dual-mono) panned onto 5.1
    /// into `dst` (Dart `Pan.toSurround`).
    pub fn to_surround(&self, src: &[f32], mono: bool, dst: &mut [f32], frames: usize) {
        let p = &self.p;
        let (mut l, mut r) = ([0.0f64; 6], [0.0f64; 6]);
        let lfe = if p[18] >= 0.5 { db_gain(p[5]) } else { 0.0 };
        let blend = dclamp(p[17], 0.0, 1.0);
        let pan = |dir: f64, extent: f64, gain: f64, l: &mut [f64; 6], r: &mut [f64; 6]| {
            if gain <= 0.0 {
                return;
            }
            if mono {
                crate::mix::surround::mono(dir, extent, gain, lfe, l);
            } else if p[6].round() as i64 == 1 && blend < 1.0 {
                crate::mix::surround::stereo_discrete(p[8], p[7], gain, lfe, l, r);
            } else {
                crate::mix::surround::stereo_distributed(dir, extent, p[4], gain, lfe, l, r);
            }
        };
        pan(p[2], p[3], 1.0 - blend, &mut l, &mut r);
        if blend > 0.0 {
            let (az, dist) = match self.st {
                State::Pan { az, dist } => (az, dist),
                _ => (0.0, 0.0),
            };
            let att = crate::mix::spatial::attenuation(p[11].round() as i64, dist, p[12], p[13]);
            let e = crate::mix::spatial::extent(p[14].round() as i64, dist, p[12], p[15], p[16]);
            pan(az, e, att * blend, &mut l, &mut r);
        }
        for i in 0..frames {
            let x = src[i * 2] as f64;
            let y = if mono { 0.0 } else { src[i * 2 + 1] as f64 };
            for c in 0..6 {
                dst[i * 6 + c] = (l[c] * x + r[c] * y) as f32;
            }
        }
    }
}
