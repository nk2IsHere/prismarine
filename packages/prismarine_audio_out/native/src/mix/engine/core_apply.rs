//! Applying commands to the engine's instances.

use super::*;

impl Core {
    pub(crate) fn apply(&mut self, cx: &mut Cx, mut c: Cmd) {
        match c.op {
            OP_START => self.start(cx, c),
            OP_SET_PARAM => {
                if let Some(e) = self.event(cx, c.id, true) {
                    e.set_param(c.name_id, c.value);
                }
            }
            OP_SET_VOLUME => {
                let lag = cx.sh.rules.report_lag;
                if let Some(e) = self.event(cx, c.id, true) {
                    // With a tail, a zero volume for a one-shot that has
                    // played and has less than the tail left is dropped
                    // (engine.dart SetVolume); before its first render a
                    // volume is the start volume.
                    if c.keep_tail >= 0.0
                        && c.value.abs() <= 1e-6
                        && e.def.oneshot
                        && e.vol_prev.is_some()
                        && e.left(lag) < c.keep_tail
                    {
                        return;
                    }
                    e.volume = c.value;
                }
            }
            OP_STOP => {
                let lag = cx.sh.rules.report_lag;
                if let Some(e) = self.event(cx, c.id, false) {
                    if e.done {
                        return;
                    }
                    if c.keep_tail >= 0.0 && e.def.oneshot && e.left(lag) < c.keep_tail {
                        return;
                    }
                    // The flag: stop at once, never through the parameter.
                    if c.flag {
                        e.stop(false);
                    } else if c.via < 0 || !e.set_param(c.via, 1.0) {
                        e.stop(true);
                    }
                }
            }
            OP_SET_PAUSED => {
                if let Some(e) = self.event(cx, c.id, true) {
                    e.paused = c.flag;
                }
            }
            OP_SET_SPATIAL => {
                if let Some(e) = self.event(cx, c.id, true) {
                    e.set_spatial(c.value, c.seek, c.late);
                }
            }
            OP_START_SNAPSHOT => {
                if c.event < 0 {
                    problem!(cx, "unknown snapshot {}", c.name_str());
                    return;
                }
                let Some(mut s) = c.snap.take() else { return };
                let order = self.snap_started;
                self.snap_started += 1;
                if self.graph.active.len() == self.graph.active.capacity()
                    || (self.snaplive.len() == self.snaplive.capacity()
                        && !self.snaplive.iter().any(|l| l.0 == c.id))
                {
                    problem!(
                        cx,
                        "more than {} snapshots: {} refused",
                        MAX_SNAPSHOTS,
                        cx.s(s.def.path)
                    );
                    return;
                }
                s.order = order;
                self.graph.active.push(s);
                match self.snaplive.iter_mut().find(|l| l.0 == c.id) {
                    Some(l) => l.1 = order,
                    None => self.snaplive.push((c.id, order)),
                }
            }
            OP_SET_SNAP_PARAM => {
                if let Some(s) = self.snap(cx, c.id) {
                    let d = s.def;
                    for (i, sp) in d.snap_params.iter().enumerate() {
                        if c.name_id >= 0 && sp.0 == c.name_id {
                            let p = &d.params[sp.1];
                            s.values[i] = dclamp(c.value, p.min, p.max);
                        }
                    }
                }
            }
            OP_STOP_SNAPSHOT => {
                if let Some(s) = self.snap(cx, c.id) {
                    s.stopped = true;
                    self.snaplive.retain(|l| l.0 != c.id);
                }
            }
            OP_FORGET => self.forget(cx, c.gen),
            OP_BIND => {
                // The binding it replaces goes when no voice reads it.
                if let Some(slot) = cx.slots.get_mut(c.id as usize) {
                    *slot = c.src.take();
                }
            }
            _ => {}
        }
    }

    /// A scene change (OP_FORGET, applied when it arrives): the slots bound
    /// for an older generation let go of their sources, except those a live
    /// instance or a queued start can still play. Their sounds take
    /// waveforms as they go (a multi's next entry, a scatterer's spawn, a
    /// loop's next pass), and a start's sources are bound when it is posted,
    /// up to 4,096 frames before it plays, so a sound started just before a
    /// scene change keeps its samples. Streams stay bound.
    fn forget(&mut self, cx: &mut Cx, gen: i64) {
        let keep = &mut self.keep;
        keep.fill(false);
        let mut mark = |e: &Event| {
            for &w in &e.waves {
                if let Some(k) = keep.get_mut(w as usize) {
                    *k = true;
                }
            }
        };
        for e in &self.insts {
            if !e.done {
                mark(e.def);
            }
        }
        for c in &self.queue {
            if c.op == OP_START && c.event >= 0 {
                mark(&cx.m.events[c.event as usize]);
            }
        }
        for (w, slot) in cx.slots.iter_mut().enumerate() {
            if !keep.get(w).copied().unwrap_or(false)
                && slot
                    .as_ref()
                    .is_some_and(|s| s.kind != Kind::Stream && s.gen < gen)
            {
                *slot = None;
            }
        }
    }

    pub(crate) fn queue_add(&mut self, cx: &mut Cx, c: Cmd) {
        if self.queue.len() >= QUEUE {
            problem!(cx, "audio command queue full");
            return;
        }
        let i = self.queue.partition_point(|q| q.at <= c.at);
        self.queue.insert(i, c);
    }
}
