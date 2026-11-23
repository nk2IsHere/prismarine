//! The timeline: placements, loop regions, transitions and sheets.

use super::*;

impl Inst {
    // --- the timeline ----------------------------------------------------

    fn lock(&mut self, cx: &mut Cx, p: &'static Placement) -> Option<Locked> {
        let mut inst = &p.inst;
        let (mut volume, mut pitch) = (0.0, 0.0);
        if inst.kind == INST_MULTI {
            // A timelocked playlist picks an entry each time its box is
            // entered, as Dart's `_lock`.
            volume = inst.volume + self.modulation(cx, inst, 0);
            pitch = inst.pitch + self.modulation(cx, inst, 1);
            inst = self.pick(inst)?;
        }
        if inst.kind != INST_SINGLE {
            problem!(
                cx,
                "unsupported timelocked {} in {}",
                cx.s(inst.kind_str),
                cx.s(self.def.path)
            );
            return None;
        }
        if inst.wave < 0 {
            return None;
        }
        let src = sample(cx, inst.wave)?;
        pitch += inst.pitch + self.modulation(cx, inst, 1);
        volume += self
            .vals()
            .automated(inst.prop(0), None)
            .unwrap_or(inst.volume);
        let bus = self
            .strip_of(inst.output_bus)
            .or_else(|| self.strip_of(p.inst.output_bus))
            .unwrap_or(self.master);
        let rate = src.rate() as f64 / RATE_F * dpow(2.0, pitch / 12.0);
        let reader = Reader::new(src);
        let gain = db_gain(volume + self.modulation(cx, inst, 0));
        let seek = seek_frames(&reader.src, self.start_offset(cx, inst))
            + (inst.left_trim * reader.src.rate()) as f64 / RATE_F;
        Some(Locked {
            reader,
            bus,
            rate,
            gain,
            seek,
            started: false,
            fill: p.fill,
        })
    }

    fn grid(&self, t: &Trans, x: f64) -> i64 {
        let d = self.def;
        let dflt = Tempo {
            position: 0,
            tempo: 120.0,
            beats_per_bar: 4,
            beat_unit: 4,
        };
        let m = d
            .tempo
            .iter()
            .rev()
            .find(|m| m.position as f64 <= x)
            .unwrap_or(if d.tempo.is_empty() {
                &dflt
            } else {
                &d.tempo[0]
            });
        let quarter = 60.0 / m.tempo * RATE_F;
        let unit = match t.unit {
            1 => quarter * 4.0 / m.beat_unit as f64 * m.beats_per_bar as f64,
            2 => quarter / 2.0,
            _ => quarter,
        };
        let step = unit * t.multiplier.max(1) as f64;
        let k = dceil((x - m.position as f64) / step - 1e-9);
        dround(m.position as f64 + k as f64 * step)
    }

    fn evaluate_regions(&mut self) {
        let c = self.cursor;
        if let Some((t, _)) = self.pending {
            if !self.vals().holds(t.cond, t.cond_min, t.cond_max) {
                self.pending = None;
            }
        }
        if self.pending.is_some() {
            return;
        }
        let d = self.def;
        for t in &d.trans {
            if t.is_loop || t.is_marker {
                continue;
            }
            if c < t.start || c >= t.end {
                continue;
            }
            if !self.vals().holds(t.cond, t.cond_min, t.cond_max) {
                continue;
            }
            let at = if t.unit == 0 {
                c
            } else {
                self.grid(t, c as f64 + 0.48 * RATE_F)
            };
            if at < t.end {
                self.pending = Some((t, at));
                return;
            }
        }
    }

    /// Cues in real time the timelocked streams that a jump in the next
    /// 0.5 s reaches, from a latched transition, a loop end or a transition
    /// marker, with stream_cue. They decode the destination now. It only
    /// reads and the render is unchanged.
    fn cue_jumps(&self, cx: &mut Cx) {
        let d = self.def;
        let c = self.cursor;
        let ahead = c + (0.5 * RATE_F) as i64;
        let cue = |cx: &mut Cx, dest: i64| {
            for (k, p) in d.place.iter().enumerate() {
                if !p.timelocked || dest < p.start || dest >= p.start + p.length {
                    continue;
                }
                if let Some(s) = &self.locked[k] {
                    let len = s.reader.src.frames();
                    if len <= 0 {
                        continue;
                    }
                    let mut pos = (dest - p.start) as f64 * s.rate + s.seek;
                    if pos >= len as f64 {
                        pos = dmod(pos, len as f64);
                    }
                    stream_cue(cx.sh, &s.reader.src, dfloor(pos));
                    continue;
                }
                // A sound not entered yet, in a new region or section that the
                // jump or the cursor reaches, gets its stream at the start of
                // the instrument. A random start offset cannot be foreseen.
                // A region that begins inside a file does not read silence.
                let inst = &p.inst;
                if inst.kind != INST_SINGLE
                    || inst.wave < 0
                    || inst.prop(9).is_some_and(|q| !q.mods.is_empty())
                {
                    continue;
                }
                let Some(Some(src)) = cx.slots.get(inst.wave as usize).cloned() else {
                    continue;
                };
                let len = src.frames();
                if src.kind != Kind::Stream || len <= 0 {
                    continue;
                }
                let rate = src.rate() as f64 / RATE_F * dpow(2.0, inst.pitch / 12.0);
                let mut pos = (dest - p.start) as f64 * rate + seek_frames(&src, inst.seek);
                if pos >= len as f64 {
                    pos = dmod(pos, len as f64);
                }
                stream_cue(cx.sh, &src, dfloor(pos));
            }
        };
        if let Some((t, _)) = self.pending {
            cue(cx, t.dest);
        }
        // The regions that the cursor reaches by itself within the
        // lookahead.
        for p in d.place.iter() {
            if p.timelocked && c < p.start && p.start <= ahead {
                cue(cx, p.start);
            }
        }
        for t in &d.trans {
            let near = if t.is_loop {
                c < t.end && t.end <= ahead
            } else {
                t.is_marker && t.start >= c && t.start <= ahead
            };
            if near && self.vals().holds(t.cond, t.cond_min, t.cond_max) {
                cue(cx, t.dest);
            }
        }
    }

    fn enter_async(&mut self, cx: &mut Cx, c: i64, run: i64, at: i64) {
        let d = self.def;
        for (k, p) in d.place.iter().enumerate() {
            if p.timelocked {
                continue;
            }
            let inside = c >= p.start && c < p.start + p.length;
            let owner = p as *const Placement as usize;
            if inside && !self.async_inside[k] {
                self.async_inside[k] = true;
                self.trigger(cx, &p.inst, at, owner);
            } else if !inside && p.start > c && p.start < c + run {
                self.async_inside[k] = true;
                self.trigger(cx, &p.inst, at + p.start - c, owner);
            }
        }
    }

    fn leave_async(&mut self, from: i64, to: i64) {
        let d = self.def;
        for (k, p) in d.place.iter().enumerate() {
            if p.timelocked || !self.async_inside[k] {
                continue;
            }
            let end = p.start + p.length;
            if to >= p.start && to < end && from <= end {
                continue;
            }
            self.async_inside[k] = false;
            self.cut(p as *const Placement as usize);
        }
    }

    fn render_locked(&mut self, cx: &mut Cx, c: i64, run: i64, at: i64, gains: &mut [f32]) {
        if run <= 0 {
            return;
        }
        let d = self.def;
        for (k, p) in d.place.iter().enumerate() {
            if !p.timelocked {
                continue;
            }
            let end = p.start + p.length;
            let lo = c.max(p.start);
            let hi = (c + run).min(end);
            if lo >= hi {
                if c >= end || c + run <= p.start {
                    self.locked[k] = None;
                }
                continue;
            }
            if self.locked[k].is_none() {
                self.locked[k] = self.lock(cx, p);
            }
            let Some(mut s) = self.locked[k].take() else {
                continue;
            };
            let n = hi - lo;
            let mut has_gains = false;
            if let Some(fade) = p.inst.prop(4) {
                if !fade.autos.is_empty() {
                    for i in 0..n {
                        let x = (lo + i) as f64;
                        gains[i as usize] =
                            self.vals().automated(Some(fade), Some(x)).unwrap_or(0.0) as f32;
                    }
                    has_gains = true;
                }
            }
            let bus_mono = self.strips[s.bus].mono;
            let (fk, down) = src_format(&s.reader.src, bus_mono);
            let mut pos = (lo - p.start) as f64 * s.rate + s.seek;
            let (rate, g) = (s.rate, s.gain * fk);
            let bus = s.bus;
            // The waveform repeats to fill its box, as Dart's _renderLocked.
            let len = s.reader.src.frames();
            let mut done = 0i64;
            while done < n {
                let mut m = n - done;
                if len > 0 {
                    if pos >= len as f64 && !s.fill {
                        break;
                    }
                    if pos >= len as f64 {
                        pos = dmod(pos, len as f64);
                    }
                    let fit = dceil((len as f64 - pos) / rate);
                    if fit < m {
                        m = fit;
                    }
                }
                let mut at_pos = pos;
                let st = &mut self.strips[bus];
                let rear = st.wide && s.reader.src.channels() >= 4;
                reader_add(
                    cx.sh,
                    &mut *cx.chunk,
                    &mut s.reader,
                    &mut st.input,
                    if rear {
                        Some(&mut st.input51[..])
                    } else {
                        None
                    },
                    at + lo - c + done,
                    m,
                    &mut at_pos,
                    rate,
                    g,
                    g,
                    if has_gains {
                        Some(&gains[done as usize..(done + m) as usize])
                    } else {
                        None
                    },
                    false,
                    down,
                    1.0,
                    1.0,
                );
                pos += m as f64 * rate;
                done += m;
            }
            s.started = true;
            self.locked[k] = Some(s);
        }
    }

    pub(crate) fn timeline(&mut self, cx: &mut Cx, frames: i64, gains: &mut [f32]) {
        let d = self.def;
        for (k, p) in d.place.iter().enumerate() {
            if !p.timelocked || self.cursor < p.start || self.cursor >= p.start + p.length {
                continue;
            }
            if self.locked[k].is_none() {
                self.locked[k] = self.lock(cx, p);
            }
            let first = !self.locked.iter().flatten().any(|l| l.started);
            if let Some(s) = &mut self.locked[k] {
                if !s.reader.src.ready() {
                    return;
                }
                // Before the first timelocked sound of the event plays, a
                // stream that cannot serve its start position holds the
                // timeline, as its opening does. Later ones read what is
                // there.
                if !s.started && first {
                    let len = s.reader.src.frames();
                    let mut pos = (self.cursor - p.start) as f64 * s.rate + s.seek;
                    if len > 0 && pos >= len as f64 {
                        pos = dmod(pos, len as f64);
                    }
                    if !stream_ready_at(cx.sh, &mut s.reader, dfloor(pos)) {
                        return;
                    }
                }
            }
        }
        self.evaluate_regions();
        if cx.sh.streaming {
            self.cue_jumps(cx);
        }
        let mut f = 0i64;
        let mut jumps = 0;
        let mut arrived = true;
        let length = d.tl_length;
        while f < frames {
            let c = self.cursor;
            if c >= length && self.pending.is_none() {
                self.enter_async(cx, c, 0, f);
                break;
            }
            let mut m = frames - f;
            let mut jump: Option<(i64, i64)> = None;
            if jumps < 8 {
                let consider = |off: i64, to: i64, m: i64, jump: &mut Option<(i64, i64)>| {
                    if off >= 0 && off <= m && jump.is_none_or(|j| off < j.0) {
                        *jump = Some((off, to));
                    }
                };
                for t in &d.trans {
                    if t.is_loop {
                        if c < t.end
                            && t.end <= c + m
                            && self.vals().holds(t.cond, t.cond_min, t.cond_max)
                        {
                            consider(t.end - c, t.dest, m, &mut jump);
                        }
                    } else if t.is_marker
                        && t.start >= c
                        && t.start < c + m
                        && !(arrived && jumps > 0 && t.start == c)
                        && self.vals().holds(t.cond, t.cond_min, t.cond_max)
                    {
                        consider(t.start - c, t.dest, m, &mut jump);
                    }
                }
                if let Some((t, at)) = self.pending {
                    if at >= c && at < c + m {
                        consider(at - c, t.dest, m, &mut jump);
                    }
                }
            }
            if c + m > length && jump.is_none() {
                m = length - c;
            }
            let run = jump.map_or(m, |j| j.0);
            self.enter_async(cx, c, run, f);
            self.render_locked(cx, c, run, f, gains);
            f += run;
            if let Some((_, dest)) = jump {
                self.leave_async(c + run, dest);
                self.cursor = dest;
                if self.pending.is_some_and(|(t, _)| t.dest == dest) {
                    self.pending = None;
                }
                jumps += 1;
                arrived = true;
            } else {
                self.cursor = c + run;
                arrived = false;
                if run == 0 {
                    break;
                }
            }
        }
        for (k, p) in d.place.iter().enumerate() {
            if !p.timelocked
                && self.async_inside[k]
                && !(self.cursor >= p.start && self.cursor < p.start + p.length)
            {
                self.async_inside[k] = false;
                self.cut(p as *const Placement as usize);
            }
        }
    }

    pub(crate) fn trigger_sheets(&mut self, cx: &mut Cx) {
        let d = self.def;
        let mut flat = 0;
        for (i, p) in d.params.iter().enumerate() {
            let v = self.values[self.slot[i]];
            for s in &p.sheets {
                let inside = v >= s.start && v < s.start + s.length;
                let was = self.sheet_inside[flat];
                let owner = s as *const Sheet as usize;
                if inside && !was {
                    self.sheet_inside[flat] = true;
                    self.trigger(cx, &s.inst, 0, owner);
                } else if !inside && was {
                    self.sheet_inside[flat] = false;
                    self.cut(owner);
                }
                flat += 1;
            }
        }
    }
}
