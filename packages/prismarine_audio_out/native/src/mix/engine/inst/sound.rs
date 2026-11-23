//! Rendering one sound; snapshot instruments and scatterers.

use super::*;

impl Inst {
    // --- sounds ------------------------------------------------------------

    /// Renders sound [s] (taken out of its slot): false once it has ended.
    pub(super) fn render_sound(&mut self, cx: &mut Cx, s: &mut Sound, frames: i64) -> bool {
        if s.ended {
            return false;
        }
        match s.body {
            Body::Empty => false,
            Body::Voice { .. } => self.render_voice(cx, s, frames),
            Body::Nested { .. } => self.render_nested(cx, s, frames),
            Body::Snapshot { .. } => self.render_snapshot(cx, s, frames),
            Body::Scatter { env: Some(_), .. } => self.render_scatter_env(cx, s, frames),
            Body::Scatter {
                inst,
                spawned,
                stopped,
                env: None,
            } => {
                // The scatterer spawns into this instance while it renders.
                let owner = spawn_owner(s.serial);
                let (mut spawned, mut delay) = (spawned, s.delay);
                let mut stop = stopped;
                let mut alive = !stop;
                if alive {
                    while delay < frames {
                        if inst.spawn_count > 0 && spawned >= inst.spawn_count {
                            stop = true;
                            alive = false;
                            break;
                        }
                        let mut live = self
                            .voices
                            .iter()
                            .filter(|v| v.owner == owner && !v.ended && !v.stolen)
                            .count() as i64;
                        let max = inst.max_poly;
                        if max > 0 && live >= max && inst.spawn_steal {
                            // The oldest live spawn is stopped (Dart: O).
                            if let Some(k) = self
                                .voices
                                .iter()
                                .position(|v| v.owner == owner && !v.ended && !v.stolen)
                            {
                                self.steal_sound(k, delay);
                                live -= 1;
                            }
                        }
                        if max <= 0 || live < max {
                            spawned += 1;
                            self.spawn(cx, inst, owner, s.bus, delay);
                        }
                        let sec = self.rng.range(inst.spawn_min, inst.spawn_max);
                        delay += dround(sec * RATE_F).max(1);
                    }
                    if alive {
                        delay -= frames;
                    }
                }
                s.delay = delay;
                s.body = Body::Scatter {
                    inst,
                    spawned,
                    stopped: stop,
                    env: None,
                };
                alive
            }
        }
    }

    /// A snapshot ask (dropped, with a problem later, when full: the pool
    /// is sized for S1's few snapshot instruments).
    pub(crate) fn snap_ask(&mut self, op: SnapOp) {
        if self.snap_out.len() < self.snap_out.capacity() {
            self.snap_out.push(op);
        }
    }

    /// A nested event's snapshot asks, up into this instance's.
    pub(crate) fn snap_up(&mut self, event: &mut Inst) {
        let mut out = std::mem::take(&mut event.snap_out);
        for op in out.drain(..) {
            self.snap_ask(op);
        }
        event.snap_out = out;
    }

    /// An event instrument on a snapshot (Dart `_SnapshotSound.render`).
    fn render_snapshot(&mut self, cx: &mut Cx, s: &mut Sound, frames: i64) -> bool {
        if s.delay >= frames {
            s.delay -= frames;
            return true;
        }
        s.delay = 0;
        let Body::Snapshot { inst, key, at } = &mut s.body else {
            unreachable!()
        };
        let inst: &'static crate::mix::model::Inst = inst;
        if *key < 0 {
            let snap = self
                .snaps
                .iter_mut()
                .find(|p| std::ptr::eq(p.inst, inst))
                .and_then(|p| p.free.pop());
            let Some(mut snap) = snap else {
                problem!(
                    cx,
                    "snapshot instrument pool of {} empty: one refused",
                    cx.s(self.def.path)
                );
                return false;
            };
            *cx.snap_key += 1;
            *key = *cx.snap_key;
            snap.key = *key;
            snap.scale = inst.snap_intensity / 100.0;
            for st in &inst.stubs {
                snap.set_guid(st.guid, st.initial);
            }
            if let Some((_, d, c)) = self.spatial {
                snap.set_auto(d, c);
            }
            *at = self.spatial_gen;
            let k = *key;
            self.snap_ask(SnapOp::Start(snap));
            self.snap_stubs(inst, k);
            return true;
        }
        let k = *key;
        if let Some((_, d, c)) = self.spatial {
            if *at != self.spatial_gen {
                *at = self.spatial_gen;
                self.snap_ask(SnapOp::Auto {
                    key: k,
                    dist: d,
                    cone: c,
                });
            }
        }
        self.snap_stubs(inst, k);
        true
    }

    /// The stubs' automation onto snapshot [key].
    fn snap_stubs(&mut self, inst: &'static crate::mix::model::Inst, key: i64) {
        for st in &inst.stubs {
            if let Some(v) = self.vals().automated(inst.prop(st.index), None) {
                self.snap_ask(SnapOp::Set {
                    key,
                    guid: st.guid,
                    value: v,
                });
            }
        }
    }

    /// A scatterer with a pitch AHDSR (Dart `_Scatter._renderEnv`).
    fn render_scatter_env(&mut self, cx: &mut Cx, s: &mut Sound, frames: i64) -> bool {
        let Body::Scatter {
            inst,
            mut spawned,
            stopped,
            env: Some(mut e),
        } = s.body
        else {
            unreachable!()
        };
        if stopped {
            return false;
        }
        let owner = spawn_owner(s.serial);
        let stop = |s: &mut Sound, spawned: i64, e: ScatEnv| {
            s.body = Body::Scatter {
                inst,
                spawned,
                stopped: true,
                env: Some(e),
            };
            false
        };
        if e.released >= 0.0 && e.released >= e.m.release {
            return stop(s, spawned, e);
        }
        let p = e.prop;
        let mut st = e.s0 + ui_offset(p, e.level());
        if let Some(m) = &p.map {
            if !m.y.is_empty() {
                st = dclamp(st, m.y[0], m.y[m.y.len() - 1]);
            }
        }
        let bend = st - e.s0;
        let rate = dpow(2.0, st / 12.0);
        if s.delay >= frames && e.clock < 0.0 {
            s.delay -= frames;
            return true;
        }
        let mut c = if e.clock < 0.0 {
            s.delay as f64 * rate
        } else {
            e.clock
        };
        let avail = frames as f64 * rate;
        while c < avail {
            if inst.spawn_count > 0 && spawned >= inst.spawn_count {
                return stop(s, spawned, e);
            }
            let at = dfloor(c / rate);
            let mut live = self
                .voices
                .iter()
                .filter(|v| v.owner == owner && !v.ended && !v.stolen)
                .count() as i64;
            let max = inst.max_poly;
            if max > 0 && live >= max && inst.spawn_steal {
                if let Some(k) = self
                    .voices
                    .iter()
                    .position(|v| v.owner == owner && !v.ended && !v.stolen)
                {
                    self.steal_sound(k, at);
                    live -= 1;
                }
            }
            if max <= 0 || live < max {
                spawned += 1;
                self.spawn(cx, inst, owner, s.bus, at);
            }
            let sec = self.rng.range(inst.spawn_min, inst.spawn_max);
            c += dround(sec * RATE_F).max(1) as f64;
        }
        e.clock = c - avail;
        for v in self.voices.iter_mut() {
            if v.owner == owner && !v.ended {
                if let Body::Voice { bend: b, .. } = &mut v.body {
                    *b = bend;
                }
            }
        }
        if e.released < 0.0 {
            e.age += frames as f64 / RATE_F;
        } else {
            e.released += frames as f64 / RATE_F;
        }
        s.body = Body::Scatter {
            inst,
            spawned,
            stopped: false,
            env: Some(e),
        };
        true
    }
}
