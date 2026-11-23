//! Admitting and playing an instrument's sounds.

use super::*;

impl Inst {
    /// Starts sound [body]; refused (a problem) when the instance plays its
    /// most sounds already.
    #[allow(clippy::too_many_arguments)]
    fn add_sound(
        &mut self,
        cx: &mut Cx,
        owner: usize,
        cutoff: bool,
        bus: usize,
        delay: i64,
        body: Body,
        via: Via,
    ) {
        if self.voices.len() == self.voices.capacity() {
            problem!(
                cx,
                "more than {} sounds at once in {}: one refused",
                MAX_SOUNDS,
                cx.s(self.def.path)
            );
            self.release(Sound { body, ..EMPTY });
            return;
        }
        self.sounds += 1;
        self.voices.push(Sound {
            serial: self.sounds,
            owner,
            cutoff,
            ended: false,
            bus,
            delay,
            body,
            via,
            stolen: false,
            pass: 0,
        });
    }

    /// Stops sound [k] for a polyphony limit at block frame [at] (Dart
    /// `_Sound.steal`): a voice fades out (one not started yet never
    /// sounds), a nested event stops at once, a scatterer stops spawning.
    pub(crate) fn steal_sound(&mut self, k: usize, at: i64) {
        let pass = self.pass;
        let s = &mut self.voices[k];
        s.stolen = true;
        let rendered = s.pass == pass;
        match &mut s.body {
            Body::Voice {
                reader, fade_from, ..
            } => {
                if s.delay > at || !reader.src.ready() {
                    s.ended = true;
                } else {
                    *fade_from = Some(if rendered { 0 } else { at });
                }
            }
            Body::Nested { event, .. } => event.stop(false),
            Body::Scatter { stopped, .. } => *stopped = true,
            Body::Empty | Body::Snapshot { .. } => s.ended = true,
        }
    }

    /// FMOD's instrument polyphony per event instance (Dart `_admit`):
    /// false when [inst] may not play now.
    fn admit(&mut self, inst: &'static crate::mix::model::Inst, at: i64) -> bool {
        let mut oldest = None;
        let mut live = 0;
        for (k, v) in self.voices.iter().enumerate() {
            if v.ended || v.stolen || !v.via.has(inst) {
                continue;
            }
            if oldest.is_none() {
                oldest = Some(k);
            }
            live += 1;
        }
        if live < inst.poly {
            return true;
        }
        if !inst.poly_steal {
            return false;
        }
        if let Some(k) = oldest {
            self.steal_sound(k, at);
        }
        true
    }

    pub(crate) fn cut(&mut self, owner: usize) {
        for s in self.voices.iter_mut() {
            if s.owner != owner {
                continue;
            }
            let cutoff = s.cutoff;
            match &mut s.body {
                Body::Nested { event, .. } => {
                    if cutoff {
                        event.stop(true);
                    }
                }
                Body::Scatter { stopped, env, .. } => {
                    if env.as_mut().is_none_or(|e| e.untrigger()) {
                        *stopped = true;
                    }
                }
                Body::Voice { .. } | Body::Snapshot { .. } => {
                    if cutoff {
                        s.ended = true;
                    }
                }
                Body::Empty => {}
            }
        }
        self.sweep();
    }

    pub(crate) fn modulation(
        &mut self,
        cx: &mut Cx,
        inst: &'static crate::mix::model::Inst,
        index: i64,
    ) -> f64 {
        let Some(p) = inst.prop(index) else {
            return 0.0;
        };
        let mut sum = 0.0;
        for m in &p.mods {
            if m.kind == MOD_AHDSR && index == 1 && inst.kind == INST_SCATTERER {
                continue; // render_scatter_env plays it
            }
            if m.kind != MOD_RANDOM {
                problem!(
                    cx,
                    "unsupported modulator {} in {}",
                    cx.s(m.type_str),
                    cx.s(self.def.path)
                );
                continue;
            }
            let u = self.rng.range(m.min, m.max);
            sum += if index == 0 { u } else { u / 100.0 * 48.0 };
        }
        sum
    }

    /// The start offset (property 9) of [inst] in ms (EventInstance
    /// `_startOffset`).
    pub(crate) fn start_offset(
        &mut self,
        cx: &mut Cx,
        inst: &'static crate::mix::model::Inst,
    ) -> f64 {
        let base = inst.seek;
        let Some(p) = inst.prop(9) else { return base };
        if p.mods.is_empty() {
            return base;
        }
        let mut ui = match &p.map {
            Some(m) => map_unmap(m, base),
            None => base,
        };
        for m in &p.mods {
            if m.kind != MOD_RANDOM {
                problem!(
                    cx,
                    "unsupported modulator {} in {}",
                    cx.s(m.type_str),
                    cx.s(self.def.path)
                );
                continue;
            }
            ui += self.rng.range(m.min, m.max) / 100.0 * p.map.as_ref().map_or(1.0, map_span);
        }
        match &p.map {
            Some(m) => map_map(m, ui),
            None => dmax(0.0, ui),
        }
    }

    pub(super) fn pick(
        &mut self,
        multi: &'static crate::mix::model::Inst,
    ) -> Option<&'static crate::mix::model::Inst> {
        let n = multi.entries.len();
        if n == 0 {
            return None;
        }
        let pl = self.playlists.iter().position(|p| p.0 == multi.guid);
        let last = pl.map(|i| self.playlists[i].1);
        let in_pool = |i: usize| n == 1 || Some(i as i64) != last;
        let pick = if multi.shuffle {
            let mut total = 0.0;
            let mut pool_last = 0;
            for i in 0..n {
                if in_pool(i) {
                    total += multi.entries[i].0;
                    pool_last = i;
                }
            }
            let mut r = self.rng.next() * total;
            let mut pk = pool_last;
            for i in 0..n {
                if !in_pool(i) {
                    continue;
                }
                r -= multi.entries[i].0;
                if r < 0.0 {
                    pk = i;
                    break;
                }
            }
            pk
        } else {
            match last {
                None => 0,
                Some(l) => ((l + 1) % n as i64) as usize,
            }
        };
        match pl {
            Some(i) => self.playlists[i].1 = pick as i64,
            None => self.playlists.push((multi.guid, pick as i64)),
        }
        Some(&multi.entries[pick].1)
    }

    pub(crate) fn trigger(
        &mut self,
        cx: &mut Cx,
        inst: &'static crate::mix::model::Inst,
        mut at: i64,
        owner: usize,
    ) {
        if inst.chance < 100.0 && self.rng.next() * 100.0 >= inst.chance {
            return;
        }
        if inst.delay_max > 0.0 || inst.delay_min > 0.0 {
            let ms = self.rng.range(inst.delay_min, inst.delay_max);
            at += dround(ms * RATE_F / 1000.0);
        }
        let bus = self.strip_of(inst.output_bus).unwrap_or(self.master);
        self.play(
            cx,
            inst,
            at,
            owner,
            bus,
            inst.cutoff,
            0.0,
            0.0,
            None,
            false,
            0.0,
            NO_VIA,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn play(
        &mut self,
        cx: &mut Cx,
        inst: &'static crate::mix::model::Inst,
        at: i64,
        owner: usize,
        bus: usize,
        cutoff: bool,
        mut volume: f64,
        mut pitch: f64,
        pan: Option<(f64, f64)>,
        lp: bool,
        mut seek_ms: f64,
        via: Via,
    ) {
        if inst.poly > 0 && !self.admit(inst, at) {
            return;
        }
        let via = via.with(inst);
        volume += inst.volume + self.modulation(cx, inst, 0);
        pitch += inst.pitch + self.modulation(cx, inst, 1);
        seek_ms += self.start_offset(cx, inst);
        let lp = lp || inst.loop_count == -1;
        match inst.kind {
            INST_MULTI => {
                if let Some(e) = self.pick(inst) {
                    self.play(
                        cx, e, at, owner, bus, cutoff, volume, pitch, pan, lp, seek_ms, via,
                    );
                }
                return;
            }
            INST_SCATTERER => {
                let mut env = None;
                if let Some(pp) = inst.prop(1) {
                    for m in &pp.mods {
                        if m.kind == MOD_AHDSR {
                            env = Some(ScatEnv {
                                m,
                                prop: pp,
                                s0: pitch,
                                age: 0.0,
                                released: -1.0,
                                from: 0.0,
                                clock: -1.0,
                            });
                        }
                    }
                }
                self.add_sound(
                    cx,
                    owner,
                    false,
                    bus,
                    at,
                    Body::Scatter {
                        inst,
                        spawned: 0,
                        stopped: false,
                        env,
                    },
                    via,
                );
                return;
            }
            INST_EVENT => {
                let Some(nd) = inst.nested.as_deref() else {
                    return;
                };
                if nd.snapshot {
                    self.add_sound(
                        cx,
                        owner,
                        cutoff,
                        bus,
                        at,
                        Body::Snapshot {
                            inst,
                            key: -1,
                            at: 0,
                        },
                        via,
                    );
                    return;
                }
                let rng = Rng::new(dfloor(self.rng.next() * 4294967296.0));
                let child = self
                    .nested
                    .iter_mut()
                    .find(|p| std::ptr::eq(p.inst, inst))
                    .and_then(|p| p.free.pop());
                let Some(mut child) = child else {
                    problem!(
                        cx,
                        "nested event pool of {} empty: one refused",
                        cx.s(self.def.path)
                    );
                    return;
                };
                child.init(cx, rng, None, 0.0);
                child.volume = db_gain(volume);
                child.pitch += pitch;
                for st in &inst.stubs {
                    child.set_param_guid(st.guid, st.initial);
                }
                if let Some((a, d, c)) = self.spatial {
                    child.set_spatial(a, d, c);
                }
                self.add_sound(
                    cx,
                    owner,
                    cutoff,
                    bus,
                    at,
                    Body::Nested { event: child, inst },
                    via,
                );
                return;
            }
            INST_SINGLE | INST_PROGRAMMER => {}
            _ => {
                problem!(
                    cx,
                    "unsupported instrument {} in {}",
                    cx.s(inst.kind_str),
                    cx.s(self.def.path)
                );
                return;
            }
        }
        let src = if inst.kind == INST_PROGRAMMER {
            let Some(prog) = &self.programmer else { return };
            self.programmer_started = true;
            prog.clone()
        } else {
            if inst.wave < 0 {
                return;
            }
            match sample(cx, inst.wave) {
                Some(s) => s,
                None => return,
            }
        };
        let rate = src.rate() as f64 / RATE_F * dpow(2.0, pitch / 12.0);
        let pos = seek_frames(&src, seek_ms);
        let body = Body::Voice {
            reader: Reader::new(src),
            rate,
            gain: db_gain(volume),
            lp,
            pos,
            pan,
            fade_from: None,
            faded: 0,
            bend: 0.0,
            armed: true,
        };
        self.add_sound(cx, owner, cutoff, bus, at, body, via);
    }

    fn position(&mut self, inst: &crate::mix::model::Inst) -> Option<(f64, f64)> {
        let ps = [inst.prop(5), inst.prop(6), inst.prop(7)];
        if ps.iter().all(|p| p.is_none()) && inst.offset3d == 0.0 {
            return None;
        }
        let mut draws = [0.0; 3];
        for k in 0..3 {
            let mut pct = 0.0;
            if let Some(p) = ps[k] {
                for m in &p.mods {
                    if m.kind == MOD_RANDOM {
                        pct += self.rng.range(m.min, m.max);
                    }
                }
            }
            draws[k] = pct / 100.0;
        }
        let dir = draws[0] * 360.0;
        let dist = inst.offset3d * (1.0 + draws[2]);
        let mut a = dmod(dir, 360.0);
        if a > 180.0 {
            a -= 360.0;
        }
        let p = (if a.abs() <= 90.0 {
            a
        } else if a > 0.0 {
            180.0 - a
        } else {
            -180.0 - a
        }) / 90.0;
        let g = 0.5
            * (if dist <= 1.0 {
                1.0
            } else {
                1.0 / dmin(dist, 20.0)
            });
        let th = (p + 1.0) * PI / 4.0;
        Some((cos(th) * g, sin(th) * g))
    }

    /// A scatterer's spawn, owned by [owner] (its live spawns are the
    /// owner's sounds that haven't ended).
    pub(crate) fn spawn(
        &mut self,
        cx: &mut Cx,
        sc_inst: &'static crate::mix::model::Inst,
        owner: usize,
        sc_bus: usize,
        at: i64,
    ) {
        let Some(e) = self.pick(sc_inst) else { return };
        let vol = sc_inst.volume + self.modulation(cx, sc_inst, 0);
        let pit = sc_inst.pitch + self.modulation(cx, sc_inst, 1);
        let pan = self.position(e);
        self.play(
            cx, e, at, owner, sc_bus, false, vol, pit, pan, false, 0.0, NO_VIA,
        );
    }
}
