//! Strips in 5.1 as strip51.dart, the 5.1 buses and event strips and the
//! chain after a surround pan, six channels interleaved in the order FL FR
//! C LFE SL SR.

use super::*;

/// Folds the 5.1 `buf` to stereo into `out`, as Dart's `downmix51`.
pub(crate) fn downmix51(buf: &[f32], frames: usize, out: &mut [f32]) {
    let k = crate::mix::surround::DOWNMIX;
    for i in 0..frames {
        let c = buf[i * 6 + 2] as f64 * k;
        out[i * 2] = (buf[i * 6] as f64 + c + buf[i * 6 + 4] as f64 * k) as f32;
        out[i * 2 + 1] = (buf[i * 6 + 1] as f64 + c + buf[i * 6 + 5] as f64 * k) as f32;
    }
}

impl Strip {
    pub(crate) fn add51(&mut self, buf: &[f32], frames: usize) {
        if !self.wide {
            let mut st = [0.0f32; 2 * 64];
            let mut at = 0;
            while at < frames {
                let n = (frames - at).min(64);
                downmix51(&buf[at * 6..(at + n) * 6], n, &mut st[..n * 2]);
                self.add_stereo_at(&st[..n * 2], at, n);
                at += n;
            }
            return;
        }
        let inp = &mut self.input51;
        for i in 0..frames * 6 {
            inp[i] = (inp[i] as f64 + buf[i] as f64) as f32;
        }
    }

    /// Adds a stereo [buf] at frame [at] in pieces, with the stereo rule of
    /// add.
    pub(crate) fn add_stereo_at(&mut self, buf: &[f32], at: usize, n: usize) {
        let inp = &mut self.input[at * 2..(at + n) * 2];
        if !self.mono {
            for i in 0..n * 2 {
                inp[i] = (inp[i] as f64 + buf[i] as f64) as f32;
            }
        } else {
            for i in 0..n {
                let m = (buf[i * 2] as f64 + buf[i * 2 + 1] as f64) * UPMIX;
                inp[i * 2] = (inp[i * 2] as f64 + m) as f32;
                inp[i * 2 + 1] = (inp[i * 2 + 1] as f64 + m) as f32;
            }
        }
    }

    pub(crate) fn process51(
        &mut self,
        frames: usize,
        sink: &mut dyn Sink,
        keys: &mut Keys,
        scratch: &mut [f32],
    ) {
        let n6 = frames * 6;
        if self.wide {
            for i in 0..frames {
                let (l, r) = (self.input[i * 2] as f64, self.input[i * 2 + 1] as f64);
                self.input51[i * 6] = (self.input51[i * 6] as f64 + l) as f32;
                self.input51[i * 6 + 1] = (self.input51[i * 6 + 1] as f64 + r) as f32;
            }
        }
        let mut in_peak = 0.0f64;
        let src: &[f32] = if self.wide {
            &self.input51[..n6]
        } else {
            &self.input[..frames * 2]
        };
        for &v in src {
            let a = (v as f64).abs();
            if a > in_peak {
                in_peak = a;
            }
        }
        if in_peak == 0.0 && self.last_peak < 1e-7 && !self.keyed(keys) {
            let guid = self.def.guid;
            let vol = self.def.volume;
            for k in 0..self.st.len() {
                match &mut self.st[k] {
                    Stage::Fader => {
                        self.gain = Some(db_gain(sink.prop(guid, 0).unwrap_or(vol)));
                    }
                    Stage::Effect { dsp, key, .. } => {
                        let keyed = key.is_some_and(|k| keys.slot[k].is_some());
                        if dsp.idle(frames as i64, keyed) {
                            if let Some(k) = *key {
                                keys.slot[k] = None;
                            }
                        }
                    }
                    _ => {}
                }
            }
            self.output[..n6].fill(0.0);
            self.out_mono = false;
            self.end_peak = 0.0;
            return;
        }
        let mut ch = if self.wide { 6 } else { 2 };
        let mut m = !self.wide && self.mono;
        let mut work = std::mem::take(&mut self.work);
        let mut output = std::mem::take(&mut self.output);
        if self.wide {
            output[..n6].copy_from_slice(&self.input51[..n6]);
        } else {
            work[..frames * 2].copy_from_slice(&self.input[..frames * 2]);
        }
        for k in 0..self.st.len() {
            let buf: &mut [f32] = if ch == 6 {
                &mut output[..]
            } else {
                &mut work[..]
            };
            match &mut self.st[k] {
                Stage::Fader => {
                    let g = db_gain(sink.prop(self.def.guid, 0).unwrap_or(self.def.volume));
                    let g0 = self.gain.unwrap_or(g);
                    self.gain = Some(g);
                    let (e0, e1) = (self.fader_from, self.fader_to);
                    for i in 0..frames {
                        let kk = (g0 + (g - g0) * (i as f64 / frames as f64))
                            * (e0 + (e1 - e0) * (i as f64 / frames as f64));
                        for c in 0..ch {
                            buf[i * ch + c] = (buf[i * ch + c] as f64 * kk) as f32;
                        }
                    }
                }
                Stage::Effect { fx, dsp, key } => {
                    for i in 0..props_of(fx, dsp) {
                        if let Some(v) = sink.prop(fx.guid, 1000 + i as i64) {
                            dsp.set(i, v);
                        }
                    }
                    if ch == 6 {
                        if !dsp.process51(buf, frames) {
                            sink.no51(fx);
                        }
                    } else if dsp.surround() {
                        dsp.to_surround(&work[..frames * 2], m, &mut output[..n6], frames);
                        ch = 6;
                        m = false;
                    } else {
                        let kk = key.and_then(|k| keys.slot[k]).map(|i| &keys.pool[i][..]);
                        m = dsp.process(buf, frames, m, kk);
                    }
                    if dsp.take_refused() {
                        sink.refused(fx);
                    }
                    if dsp.is_compressor() {
                        if let Some(k) = *key {
                            keys.slot[k] = None;
                        }
                    }
                }
                Stage::Send(fx) => {
                    let fx = *fx;
                    let g = db_gain(sink.prop(fx.guid, 0).unwrap_or(fx.level));
                    if g == 0.0 {
                        continue;
                    }
                    let n = frames * ch;
                    for i in 0..n {
                        scratch[i] = (buf[i] as f64 * g) as f32;
                    }
                    sink.send(fx, &scratch[..n], m, ch);
                }
                Stage::Tap(fx) => {
                    let fx = *fx;
                    if ch == 6 {
                        sink.no51(fx);
                        continue;
                    }
                    sink.sidechain(&fx.targets, &buf[..frames * 2], keys);
                }
            }
        }
        if ch == 2 {
            let k = if m { UPMIX } else { 1.0 };
            for i in 0..frames {
                output[i * 6] = (work[i * 2] as f64 * k) as f32;
                output[i * 6 + 1] = (work[i * 2 + 1] as f64 * k) as f32;
                for c in 2..6 {
                    output[i * 6 + c] = 0.0;
                }
            }
        }
        self.work = work;
        self.output = output;
        self.out_mono = false;
        let (mut out_peak, mut end_peak) = (0.0f64, 0.0f64);
        let end = frames.saturating_sub(64) * 6;
        for i in 0..n6 {
            let a = (self.output[i] as f64).abs();
            if a > out_peak {
                out_peak = a;
            }
            if i >= end && a > end_peak {
                end_peak = a;
            }
        }
        self.last_peak = out_peak;
        self.end_peak = end_peak;
    }
}
