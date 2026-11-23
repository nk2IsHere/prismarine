//! An instance's render: its strips, raw and pitched.

use super::*;

impl Inst {
    // --- rendering -----------------------------------------------------

    fn process_strip(
        &mut self,
        cx: &mut Cx,
        idx: Option<usize>,
        frames: usize,
        scratch: &mut [f32],
    ) {
        let mut s = match idx {
            Some(i) => std::mem::replace(&mut self.strips[i], Strip::empty()),
            None => match self.input_bus.take() {
                Some(s) => s,
                None => return,
            },
        };
        {
            let mut sink = InstSink {
                vals: Vals {
                    def: self.def,
                    values: &self.values,
                    slot: &self.slot,
                    cursor: self.cursor,
                },
                keys: &self.def.keys,
                strips: &mut self.strips,
                guids: &self.strip_guid,
                send_out: &mut self.send_out,
                cx,
                path: self.def.path,
            };
            s.process(frames, &mut sink, &mut Keys::default(), scratch);
        }
        match idx {
            Some(i) => self.strips[i] = s,
            None => self.input_bus = Some(s),
        }
    }

    fn render_raw(&mut self, cx: &mut Cx, out: &mut [f32], frames: i64) {
        self.send_out.clear();
        if self.done {
            return;
        }
        self.pass += 1;
        let fu = frames as usize;
        if fu > self.cap {
            problem!(
                cx,
                "audio pass of {} frames in {}: built for {}",
                fu,
                cx.s(self.def.path),
                self.cap
            );
            return;
        }
        for s in self.strips.iter_mut() {
            s.begin(fu);
        }
        if let Some(ib) = self.input_bus.as_mut() {
            ib.begin(fu);
        }
        let mut gains = std::mem::take(&mut self.gains);
        self.trigger_sheets(cx);
        self.timeline(cx, frames, &mut gains);
        self.gains = gains;
        let mut k = 0;
        while k < self.voices.len() {
            let mut s = std::mem::replace(&mut self.voices[k], EMPTY);
            s.pass = self.pass;
            if !self.render_sound(cx, &mut s, frames) {
                s.ended = true;
            }
            self.voices[k] = s;
            k += 1;
        }
        self.sweep();
        // The instance volume (with the master's random volume and AHDSR) is
        // the master track's fader gain (Strip.fader_from/to).
        let base = db_gain(self.base_db);
        let v0 = self.vol_prev.unwrap_or(self.volume) * base * self.env_gain(0.0);
        let v1 = self.volume * base * self.env_gain(frames as f64 / RATE_F);
        self.vol_prev = Some(self.volume);
        let master = self.master;
        self.strips[master].fader_from = v0;
        self.strips[master].fader_to = v1;
        let mut scratch = std::mem::take(&mut self.scratch);
        for oi in 0..self.order.len() {
            let i = self.order[oi];
            self.process_strip(cx, Some(i), fu, &mut scratch);
            if i == self.master {
                break;
            }
            let to = self
                .strip_of(self.strips[i].def.output)
                .unwrap_or(self.master);
            let (src, mono, ch) = (
                std::mem::take(&mut self.strips[i].output),
                self.strips[i].out_mono,
                self.strips[i].out_ch(),
            );
            self.strips[to].add(&src, fu, mono, ch);
            self.strips[i].output = src;
        }
        if self.input_bus.is_some() {
            let (src, mono, ch) = (
                std::mem::take(&mut self.strips[master].output),
                self.strips[master].out_mono,
                self.strips[master].out_ch(),
            );
            self.input_bus.as_mut().unwrap().add(&src, fu, mono, ch);
            self.strips[master].output = src;
            self.process_strip(cx, None, fu, &mut scratch);
        }
        self.scratch = scratch;
        let last: &Strip = match &self.input_bus {
            Some(ib) => ib,
            None => &self.strips[master],
        };
        let up = if last.out_mono { UPMIX } else { 1.0 };
        let ch = last.out_ch();
        let m = &last.output;
        for i in 0..fu {
            let mut kk = up;
            if self.stopping {
                let left = 64 - self.stop_at - i as i64;
                kk *= if left <= 0 {
                    0.0
                } else if left >= 64 {
                    1.0
                } else {
                    left as f64 / 64.0
                };
            }
            if ch == 2 {
                out[i * 2] = (out[i * 2] as f64 + m[i * 2] as f64 * kk) as f32;
                out[i * 2 + 1] = (out[i * 2 + 1] as f64 + m[i * 2 + 1] as f64 * kk) as f32;
            } else {
                for c in 0..6 {
                    let j = i * 6 + c;
                    out[j] = (out[j] as f64 + m[j] as f64 * kk) as f32;
                }
            }
        }
        self.age += frames as f64 / RATE_F;
        if self.stopping {
            self.stop_at += frames;
            if self.stop_at >= 64 {
                self.finish();
            }
            return;
        }
        if self.releasing {
            self.released += frames as f64 / RATE_F;
            if self.released >= self.env.unwrap().release {
                self.finish();
            }
            return;
        }
        if self.cursor >= self.def.tl_length && self.voices.is_empty() && self.pending.is_none() {
            let none = Keys::default();
            let quiet = self.order.iter().all(|&i| self.strips[i].quiet(&none))
                && self.input_bus.as_ref().is_none_or(|ib| ib.quiet(&none));
            if quiet {
                self.finish();
            }
        }
    }

    fn render_pitched(&mut self, cx: &mut Cx, out: &mut [f32], frames: i64) {
        let mut pt = self.pitched.take().unwrap();
        let need = dfloor(pt.pos + (frames - 1) as f64 * pt.ratio) + 2;
        let ch = self.out_ch();
        if need > pt.count {
            let n = need - pt.count;
            let n2 = (n * 2) as usize;
            let nm = n as usize * ch;
            if n as usize > self.cap {
                problem!(
                    cx,
                    "pitched pass of {} frames in {}: built for {}",
                    n,
                    cx.s(self.def.path),
                    self.cap
                );
                self.pitched = Some(pt);
                return;
            }
            let mut main = std::mem::take(&mut pt.main);
            main[..nm].fill(0.0);
            self.render_raw(cx, &mut main[..nm], n);
            let count = pt.count;
            // The held buffer of [key] (Dart: putIfAbsent, zeros up to the
            // frames held so far); None when it has no room.
            let held_of = |pt: &mut Pitched, key: i32| -> Option<usize> {
                if let Some(i) = pt.held.iter().position(|h| h.0 == key) {
                    return Some(i);
                }
                let mut v = pt.spare.pop()?;
                v.clear();
                let c = if key == KEY_MAIN { ch } else { 2 };
                v.resize(count as usize * c, 0.0);
                pt.held.push((key, v));
                Some(pt.held.len() - 1)
            };
            let room = |v: &Vec<f32>, add: usize| v.len() + add <= v.capacity();
            let mut full = false;
            match held_of(pt.as_mut(), KEY_MAIN) {
                Some(i) if room(&pt.held[i].1, nm) => pt.held[i].1.extend_from_slice(&main[..nm]),
                _ => full = true,
            }
            for (key, val) in self.send_out.iter() {
                match held_of(pt.as_mut(), key) {
                    Some(i) if room(&pt.held[i].1, n2) => {
                        pt.held[i].1.extend_from_slice(&val[..n2])
                    }
                    _ => full = true,
                }
            }
            for h in pt.held.iter_mut() {
                let c = if h.0 == KEY_MAIN { ch as i64 } else { 2 };
                if (h.1.len() as i64) < (count + n) * c {
                    if room(&h.1, (n * c) as usize) {
                        h.1.resize(h.1.len() + (n * c) as usize, 0.0);
                    } else {
                        full = true;
                    }
                }
            }
            if full {
                problem!(cx, "pitched buffers of {} full", cx.s(self.def.path));
            }
            pt.count += n;
            pt.main = main;
        }
        pt.sends.clear();
        let fu = frames as usize;
        for hi in 0..pt.held.len() {
            let (key, ratio, pos0) = (pt.held[hi].0, pt.ratio, pt.pos);
            let mut tmp = std::mem::take(&mut pt.held[hi].1);
            {
                let o: &mut [f32] = if key == KEY_MAIN {
                    &mut out[..]
                } else {
                    match pt.sends.put(key, fu * 2) {
                        Some(o) => o,
                        None => {
                            std::mem::swap(&mut pt.held[hi].1, &mut tmp);
                            problem!(
                                cx,
                                "no room for pitched send {} in {}",
                                cx.s(key),
                                cx.s(self.def.path)
                            );
                            continue;
                        }
                    }
                };
                if key == KEY_MAIN && ch == 6 {
                    read_back::<6>(&tmp, o, pos0, ratio, fu);
                } else {
                    read_back::<2>(&tmp, o, pos0, ratio, fu);
                }
            }
            std::mem::swap(&mut pt.held[hi].1, &mut tmp);
        }
        self.send_out.clear();
        for (key, val) in pt.sends.iter() {
            match self.send_out.put(key, val.len()) {
                Some(o) => o.copy_from_slice(val),
                None => problem!(
                    cx,
                    "no room for send {} in {}",
                    cx.s(key),
                    cx.s(self.def.path)
                ),
            }
        }
        let end = pt.pos + frames as f64 * pt.ratio;
        let drop = dfloor(end).min(pt.count);
        for h in pt.held.iter_mut() {
            let c = if h.0 == KEY_MAIN { ch } else { 2 };
            h.1.drain(..drop as usize * c);
        }
        pt.count -= drop;
        pt.pos = end - drop as f64;
        self.pitched = Some(pt);
    }

    /// The output's channels: 6 for an event whose output is 5.1 (S2).
    pub(crate) fn out_ch(&self) -> usize {
        match &self.input_bus {
            Some(ib) => ib.out_ch(),
            None => self.strips[self.master].out_ch(),
        }
    }

    pub(crate) fn render(&mut self, cx: &mut Cx, out: &mut [f32], frames: i64) {
        self.send_out.clear();
        if self.done {
            return;
        }
        if self.paused {
            // FMOD's immediate stop ends a paused instance at once, its
            // nested snapshots with it (Dart `render`).
            if self.cut {
                self.finish();
            }
            return;
        }
        if frames as usize > self.outer {
            problem!(
                cx,
                "audio pass of {} frames in {}: built for {}",
                frames,
                cx.s(self.def.path),
                self.outer
            );
            return;
        }
        if self.pitch == 0.0 && !self.pitched_on {
            self.render_raw(cx, out, frames);
            return;
        }
        if !self.pitched_on {
            let Some(pt) = self.pitched.as_mut() else {
                problem!(
                    cx,
                    "pitch {} of {} out of its built range",
                    self.pitch,
                    cx.s(self.def.path)
                );
                return;
            };
            pt.ratio = dpow(2.0, self.pitch / 12.0);
            pt.pos = 0.0;
            pt.count = 0;
            while let Some((_, v)) = pt.held.pop() {
                pt.spare.push(v);
            }
            pt.sends.clear();
            self.pitched_on = true;
        }
        self.render_pitched(cx, out, frames);
    }
}

/// A pitched output's held frames (`C` channels) read back at `ratio` from
/// `pos`, with linear interpolation, into `o` (Dart `_Pitched.render`).
fn read_back<const C: usize>(tmp: &[f32], o: &mut [f32], pos: f64, ratio: f64, frames: usize) {
    let mut p = pos;
    for f in 0..frames {
        let k = dfloor(p) as usize;
        let fr = p - k as f64;
        for c in 0..C {
            let a = tmp[k * C + c] as f64;
            let b = tmp[(k + 1) * C + c] as f64;
            o[f * C + c] = (o[f * C + c] as f64 + (a + (b - a) * fr)) as f32;
        }
        p += ratio;
    }
}
