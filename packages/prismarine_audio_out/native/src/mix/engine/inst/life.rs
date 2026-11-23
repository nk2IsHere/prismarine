//! Parameters, modulation, stopping and stealing and the sound slots.

use super::*;

impl Inst {
    pub(super) fn vals(&self) -> Vals<'_> {
        Vals {
            def: self.def,
            values: &self.values,
            slot: &self.slot,
            cursor: self.cursor,
        }
    }

    pub(crate) fn strip_of(&self, guid: i32) -> Option<usize> {
        if guid < 0 {
            return None;
        }
        self.strip_guid.iter().position(|&g| g == guid)
    }

    pub(crate) fn modulate(&mut self, cx: &mut Cx) {
        let def = self.def;
        for p in &def.master.props {
            for m in &p.mods {
                if p.index == 0 && m.kind == MOD_RANDOM {
                    self.base_db += self.rng.range(m.min, m.max);
                } else if p.index == 1 && m.kind == MOD_RANDOM {
                    let r = self.rng.range(m.min, m.max);
                    self.pitch += ui_offset(p, r);
                } else if p.index == 0 && m.kind == MOD_AHDSR {
                    self.env = Some(m);
                    self.env_map = p.map.as_ref();
                } else {
                    problem!(
                        cx,
                        "unsupported {} modulator on bus property {} in {}",
                        cx.s(m.type_str),
                        p.index,
                        cx.s(def.path)
                    );
                }
            }
        }
        let n = def.nbuses() + if def.input_bus.is_some() { 1 } else { 0 };
        for bi in 0..n {
            let b = if bi < def.nbuses() {
                def.bus(bi)
            } else {
                def.input_bus.as_ref().unwrap()
            };
            for fx in &b.fx {
                for p in &fx.props {
                    let k = p.index - 1000;
                    if p.mods.is_empty() || k < 0 || k >= fx.params.len() as i64 {
                        continue;
                    }
                    let Some(stored) = fx.params[k as usize].stored() else {
                        continue;
                    };
                    let mut ui = match &p.map {
                        Some(m) => map_unmap(m, stored),
                        None => stored,
                    };
                    for m in &p.mods {
                        if m.kind != MOD_RANDOM {
                            problem!(
                                cx,
                                "unsupported {} modulator on an effect in {}",
                                cx.s(m.type_str),
                                cx.s(def.path)
                            );
                            continue;
                        }
                        let span = p.map.as_ref().map_or(1.0, map_span);
                        ui += self.rng.range(m.min, m.max) / 100.0 * span;
                    }
                    let v = mapped(p, ui);
                    let strip = match self.strip_of(b.guid) {
                        Some(i) => Some(&mut self.strips[i]),
                        None => self.input_bus.as_mut(),
                    };
                    if let Some(d) = strip.and_then(|s| s.effect(fx.guid)) {
                        d.set(k as usize, v);
                    }
                }
            }
        }
    }

    fn param_by_name(&self, name: i32) -> Option<usize> {
        self.vals().by_name(name)
    }

    pub fn set_param(&mut self, name: i32, value: f64) -> bool {
        match self.param_by_name(name) {
            None => false,
            Some(p) => {
                let d = &self.def.params[p];
                self.values[self.slot[p]] = dclamp(value, d.min, d.max);
                true
            }
        }
    }

    /// Sets the position relative to the listener, as Dart's
    /// `EventInstance.setSpatial`, on the distance and cone parameters, the
    /// pan DSPs and the nested events.
    pub fn set_spatial(&mut self, azimuth: f64, distance: f64, cone: f64) {
        self.spatial = Some((azimuth, distance, cone));
        self.spatial_gen += 1;
        for (i, p) in self.def.params.iter().enumerate() {
            if p.kind == 1 {
                self.values[self.slot[i]] = dclamp(distance, p.min, p.max);
            } else if p.kind == 2 {
                self.values[self.slot[i]] = dclamp(cone, p.min, p.max);
            }
        }
        for &o in &self.order {
            self.strips[o].set_spatial(azimuth, distance);
        }
        if let Some(ib) = self.input_bus.as_mut() {
            ib.set_spatial(azimuth, distance);
        }
        for v in self.voices.iter_mut() {
            if let Body::Nested { event, .. } = &mut v.body {
                event.set_spatial(azimuth, distance, cone);
            }
        }
    }

    pub(crate) fn set_param_guid(&mut self, guid: i32, value: f64) {
        if let Some(i) = self.def.params.iter().position(|p| p.guid == guid) {
            let d = &self.def.params[i];
            self.values[self.slot[i]] = dclamp(value, d.min, d.max);
        }
    }

    pub fn stop(&mut self, fade: bool) {
        if self.stopping || self.done || self.releasing {
            return;
        }
        if let Some(env) = self.env {
            if fade && env.release > 0.0 {
                self.release_from = env_level(env, self.age);
                self.released = 0.0;
                self.releasing = true;
                return;
            }
        }
        self.stopping = true;
        self.cut = !fade;
        self.stop_at = 0;
    }

    /// Stops the instance for a newer one past the polyphony limit of its
    /// event, as Dart's `steal`. One mix block later it is cut with the
    /// declick.
    pub(crate) fn steal(&mut self) {
        if self.done || self.stolen {
            return;
        }
        self.stolen = true;
        if self.stopping {
            return;
        }
        self.stopping = true;
        self.stop_at = -STEAL_DELAY;
    }

    pub(crate) fn env_gain(&self, dt: f64) -> f64 {
        let Some(m) = self.env else { return 1.0 };
        let ui = if !self.releasing {
            env_level(m, self.age + dt)
        } else {
            let r = self.released;
            if r + dt >= m.release {
                m.initial
            } else {
                self.release_from + (m.initial - self.release_from) * (r + dt) / m.release
            }
        };
        db_gain(match self.env_map {
            Some(mp) => map_map(mp, ui),
            None => ui,
        })
    }

    /// Returns the length of the instance minus its reported position, which
    /// trails the render by [lag] frames, as `_left` of engine.dart.
    pub(crate) fn left(&self, lag: i64) -> f64 {
        self.programmer_left()
            .unwrap_or((self.def.tl_length - self.cursor) as f64 / RATE_F)
            + lag as f64 / RATE_F
    }

    /// The seconds left on the slot sound, as slotLeft.
    fn programmer_left(&self) -> Option<f64> {
        let prog = self.programmer.as_ref()?;
        let (frames, rate) = (prog.frames(), prog.rate());
        for v in &self.voices {
            if let Body::Voice { reader, pos, .. } = &v.body {
                if SrcRef::ptr_eq(&reader.src, prog) {
                    return Some(dmax(0.0, frames as f64 - *pos) / rate as f64);
                }
            }
        }
        Some(if self.programmer_started {
            0.0
        } else {
            frames as f64 / rate as f64
        })
    }

    pub(crate) fn finish(&mut self) {
        self.done = true;
        self.clear_sounds();
    }

    /// Lets a sound go. The instance of a nested event goes back to its pool
    /// with its own sounds let go and anything else to the collector.
    pub(super) fn release(&mut self, s: Sound) {
        if let Body::Snapshot { key, .. } = s.body {
            if key >= 0 {
                self.snap_ask(SnapOp::Stop(key));
            }
        }
        if let Body::Nested { mut event, inst } = s.body {
            event.clear_sounds();
            self.snap_up(&mut event);
            event.programmer = None;
            event.locked.fill_with(|| None);
            if let Some(p) = self.nested.iter_mut().find(|p| std::ptr::eq(p.inst, inst)) {
                if p.free.len() < p.free.capacity() {
                    p.free.push(event);
                }
            }
        }
    }

    pub(crate) fn clear_sounds(&mut self) {
        while let Some(s) = self.voices.pop() {
            self.release(s);
        }
    }

    /// Removes the ended sounds in order.
    pub(crate) fn sweep(&mut self) {
        let mut k = 0;
        while k < self.voices.len() {
            if self.voices[k].ended {
                let s = self.voices.remove(k);
                self.release(s);
            } else {
                k += 1;
            }
        }
    }
}
