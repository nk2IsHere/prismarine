//! The engine (engine.dart, player.dart): instances, the command queue
//! and the render call.

use super::*;

// ---------------------------------------------------------------- the engine

const ENDED: usize = 1 << 16;
pub const QUEUE: usize = 8192;

pub struct Core {
    pub(crate) m: &'static Model,
    seed: i64,
    started: i64,
    pub(crate) snap_started: i64,
    snap_key: i64,
    pub(crate) insts: Vec<Owned<Inst>>,
    /// Command ids → the instance's serial.
    live: Vec<(i32, i64)>,
    ended: Vec<i64>,
    nended: usize,
    /// Snapshot ids → the snapshot's order.
    pub(crate) snaplive: Vec<(i32, i64)>,
    /// The waveforms' bound sources.
    slots: Vec<Option<SrcRef>>,
    pub(crate) graph: Graph,
    inputs: OutMap,
    /// The instances' 5.1 outputs (S2), by bus path.
    inputs51: OutMap,
    pub(crate) queue: Vec<Cmd>,
    scratch: Vec<f32>,
    chunk: Vec<f32>,
    pub position: i64,
    seen: Vec<u32>,
    /// A scene change's marks: the waveforms still wanted (forget).
    pub(crate) keep: Vec<bool>,
}

/// The keys instances' outputs reach the mixer by: the root bus, input
/// buses' outputs and every event's (and nested event's) sends.
fn input_keys(m: &Model) -> usize {
    pub(crate) fn add(k: &mut Vec<i32>, v: i32) {
        if !k.contains(&v) {
            k.push(v);
        }
    }
    pub(crate) fn event(k: &mut Vec<i32>, e: &Event) {
        if let Some(b) = &e.input_bus {
            if b.output_path >= 0 {
                add(k, b.output_path);
            }
        }
        for bus in (0..e.nbuses())
            .map(|bi| e.bus(bi))
            .chain(e.input_bus.iter())
        {
            for fx in bus.fx.iter().filter(|fx| fx.kind == FX_SEND) {
                add(
                    k,
                    if fx.return_path >= 0 {
                        fx.return_path
                    } else {
                        fx.return_bus
                    },
                );
            }
        }
        let mut sub = |i: &crate::mix::model::Inst| nested_insts_of(i, &mut |e| event(k, e));
        for p in &e.place {
            sub(&p.inst);
        }
        for pd in &e.params {
            for s in &pd.sheets {
                sub(&s.inst);
            }
        }
    }
    fn nested_insts_of(i: &crate::mix::model::Inst, f: &mut dyn FnMut(&Event)) {
        if let Some(n) = i.nested.as_deref() {
            f(n);
        }
        for (_, e) in &i.entries {
            nested_insts_of(e, f);
        }
    }
    let mut k = vec![m.s_bus_root];
    for e in &m.events {
        event(&mut k, e);
    }
    k.len()
}

/// An instance's snapshot ask, onto the mixer's snapshots (Dart: the
/// SnapshotInstance an event instrument holds).
fn snap_op(graph: &mut Graph, started: &mut i64, cx: &mut Cx, op: SnapOp) {
    fn find(g: &mut Graph, key: i64) -> Option<&mut Snap> {
        g.active
            .iter_mut()
            .find(|s| s.key == key && !s.stopped)
            .map(|s| &mut **s)
    }
    match op {
        SnapOp::Start(mut s) => {
            if graph.active.len() == graph.active.capacity() {
                problem!(
                    cx,
                    "more than {} snapshots: {} refused",
                    MAX_SNAPSHOTS,
                    cx.s(s.def.path)
                );
                return;
            }
            s.order = *started;
            *started += 1;
            graph.active.push(s);
        }
        SnapOp::Set { key, guid, value } => {
            if let Some(s) = find(graph, key) {
                s.set_guid(guid, value);
            }
        }
        SnapOp::Auto { key, dist, cone } => {
            if let Some(s) = find(graph, key) {
                s.set_auto(dist, cone);
            }
        }
        SnapOp::Stop(key) => {
            if let Some(s) = find(graph, key) {
                s.stopped = true;
            }
        }
    }
}

impl Core {
    pub fn new(sh: &Shared, seed: i64) -> Core {
        let mut seen = vec![0u32; 4096];
        let mut slots: Vec<Option<SrcRef>> = (0..sh.m.waves.len()).map(|_| None).collect();
        let mut chunk = vec![0.0; CHUNK];
        let mut snap_key = 0;
        let mut cx = Cx {
            m: sh.m,
            sh,
            seen: &mut seen,
            slots: &mut slots,
            chunk: &mut chunk,
            snap_key: &mut snap_key,
        };
        let graph = Graph::new(&mut cx);
        Core {
            m: sh.m,
            seed,
            started: 0,
            snap_started: 0,
            snap_key: 0,
            insts: Vec::with_capacity(MAX_INSTANCES),
            live: Vec::with_capacity(MAX_INSTANCES),
            ended: vec![i64::MIN; ENDED],
            nended: 0,
            snaplive: Vec::with_capacity(MAX_SNAPSHOTS),
            slots,
            graph,
            inputs: OutMap::with(input_keys(sh.m), BLOCK * 2),
            inputs51: OutMap::with(input_keys(sh.m), BLOCK * 6),
            queue: Vec::with_capacity(QUEUE),
            scratch: vec![0.0; BLOCK * 6],
            chunk,
            position: 0,
            seen,
            keep: vec![false; sh.m.waves.len()],
        }
    }

    fn ended_has(&self, id: i32) -> bool {
        let mut k = (id as u32).wrapping_mul(2654435761) as usize & (ENDED - 1);
        for _ in 0..ENDED {
            let v = self.ended[k];
            if v == id as i64 {
                return true;
            }
            if v == i64::MIN {
                return false;
            }
            k = (k + 1) & (ENDED - 1);
        }
        false
    }

    fn ended_add(&mut self, id: i32) {
        if self.nended * 2 >= ENDED || self.ended_has(id) {
            return;
        }
        let mut k = (id as u32).wrapping_mul(2654435761) as usize & (ENDED - 1);
        while self.ended[k] != i64::MIN {
            k = (k + 1) & (ENDED - 1);
        }
        self.ended[k] = id as i64;
        self.nended += 1;
    }

    pub(crate) fn event(&mut self, cx: &mut Cx, id: i32, report: bool) -> Option<&mut Inst> {
        if let Some(&(_, serial)) = self.live.iter().find(|l| l.0 == id) {
            return self
                .insts
                .iter_mut()
                .find(|e| e.serial == serial)
                .map(|e| &mut **e);
        }
        if report && !self.ended_has(id) {
            problem!(cx, "no event instance {}", id);
        }
        None
    }

    pub(crate) fn snap(&mut self, cx: &mut Cx, id: i32) -> Option<&mut Snap> {
        if let Some(&(_, order)) = self.snaplive.iter().find(|l| l.0 == id) {
            return self
                .graph
                .active
                .iter_mut()
                .find(|s| s.order == order)
                .map(|s| &mut **s);
        }
        problem!(cx, "no snapshot instance {}", id);
        None
    }

    pub(crate) fn start(&mut self, cx: &mut Cx, mut c: Cmd) {
        let prog = c.src.take();
        let Some(mut e) = c.inst.take().filter(|_| c.event >= 0) else {
            problem!(cx, "unknown event {}", c.name_str());
            return;
        };
        let def: &'static Event = e.def;
        let mut seek = c.seek;
        if c.has_late {
            let rules = cx.sh.rules;
            let len = match &prog {
                Some(p) if rules.whole_ms => ((p.frames() * 1000) / p.rate()) as f64 / 1000.0,
                Some(p) => p.frames() as f64 / p.rate() as f64,
                None => def.tl_length as f64 / RATE_F,
            };
            let past = if seek > 0.0 && seek > c.late {
                seek
            } else {
                -1.0
            };
            if len > 0.0 && past > len {
                return;
            }
            seek = if c.late >= len || rules.late_min >= seek {
                0.0
            } else {
                dmax(past, 0.0)
            };
        }
        if def.poly > 0 && !self.admit(def) {
            // Refused by its polyphony: it plays nothing, quietly.
            self.ended_add(c.id);
            return;
        }
        self.started += 1;
        let rng = Rng::new(
            self.seed
                .wrapping_mul(0x9e3779b1)
                .wrapping_add(self.started),
        );
        if self.insts.len() == self.insts.capacity() {
            problem!(
                cx,
                "more than {} event instances: {} refused",
                MAX_INSTANCES,
                cx.s(def.path)
            );
            return;
        }
        e.init(cx, rng, prog, seek);
        let serial = self.started;
        e.serial = serial;
        self.insts.push(e);
        if let Some(l) = self.live.iter_mut().find(|l| l.0 == c.id) {
            l.1 = serial;
        } else if self.live.len() < self.live.capacity() {
            self.live.push((c.id, serial));
        } else {
            problem!(cx, "more than {} event ids", MAX_INSTANCES);
        }
    }

    /// FMOD's event polyphony (Dart `EventPlayer._admit`): with [Event::poly]
    /// instances live, a start fails or stops the oldest.
    fn admit(&mut self, def: &'static Event) -> bool {
        let mut oldest = None;
        let mut live = 0;
        for (k, e) in self.insts.iter().enumerate() {
            if !std::ptr::eq(e.def, def) || e.done || e.stolen {
                continue;
            }
            if oldest.is_none() {
                oldest = Some(k);
            }
            live += 1;
        }
        if live < def.poly {
            return true;
        }
        if !def.poly_steal {
            return false;
        }
        if let Some(k) = oldest {
            self.insts[k].steal();
        }
        true
    }

    fn player_render(&mut self, cx: &mut Cx, frames: i64) {
        let mut inputs = std::mem::take(&mut self.inputs);
        let mut inputs51 = std::mem::take(&mut self.inputs51);
        inputs.clear();
        inputs51.clear();
        let fu = frames as usize;
        for i in 0..self.insts.len() {
            let e = &mut self.insts[i];
            let d = e.def;
            let path = match &d.input_bus {
                Some(b) if b.output_path >= 0 => b.output_path,
                _ => self.m.s_bus_root,
            };
            let ch = e.out_ch();
            let to = if ch == 6 { &mut inputs51 } else { &mut inputs };
            let Some(buf) = to.put(path, fu * ch) else {
                problem!(cx, "no room for mixer input {}", cx.s(path));
                continue;
            };
            e.render(cx, buf, frames);
            if !e.snap_out.is_empty() {
                let mut out = std::mem::take(&mut e.snap_out);
                for op in out.drain(..) {
                    snap_op(&mut self.graph, &mut self.snap_started, cx, op);
                }
                self.insts[i].snap_out = out;
            }
            let e = &mut self.insts[i];
            for k in 0..e.send_out.n {
                let (key, len) = (e.send_out.e[k].0, e.send_out.e[k].2);
                let Some(o) = inputs.put(key, fu * 2) else {
                    problem!(cx, "no room for mixer input {}", cx.s(key));
                    continue;
                };
                let v = &e.send_out.e[k].1;
                for f in 0..len {
                    o[f] = (o[f] as f64 + v[f] as f64) as f32;
                }
            }
        }
        self.inputs = inputs;
        self.inputs51 = inputs51;
    }

    pub fn render(&mut self, sh: &Shared, out: &mut [f32]) {
        let frames = (out.len() / 2) as i64;
        let mut seen = std::mem::take(&mut self.seen);
        let mut slots = std::mem::take(&mut self.slots);
        let mut chunk = std::mem::take(&mut self.chunk);
        let mut snap_key = self.snap_key;
        let mut cx = Cx {
            m: self.m,
            sh,
            seen: &mut seen,
            slots: &mut slots,
            chunk: &mut chunk,
            snap_key: &mut snap_key,
        };
        while let Some(c) = sh.ring.pop() {
            if c.at < 0 || c.op == OP_FORGET || c.op == OP_BIND {
                self.apply(&mut cx, c);
            } else {
                self.queue_add(&mut cx, c);
            }
        }
        let mut done = 0i64;
        let mut scratch = std::mem::take(&mut self.scratch);
        while done < frames {
            while !self.queue.is_empty() && self.queue[0].at <= self.position {
                let c = self.queue.remove(0);
                self.apply(&mut cx, c);
            }
            let mut n = (frames - done).min(BLOCK as i64);
            if let Some(q) = self.queue.first() {
                n = n.min(q.at - self.position);
            }
            self.player_render(&mut cx, n);
            let inputs = std::mem::take(&mut self.inputs);
            let inputs51 = std::mem::take(&mut self.inputs51);
            self.graph
                .render(&mut cx, &inputs, &inputs51, n as usize, &mut scratch);
            self.inputs = inputs;
            self.inputs51 = inputs51;
            let dst = &mut out[(done * 2) as usize..((done + n) * 2) as usize];
            match self.graph.master {
                None => dst.fill(0.0),
                Some(mi) if self.graph.buses[mi].out_ch() == 6 => {
                    downmix51(&self.graph.buses[mi].output, n as usize, dst);
                }
                Some(mi) => {
                    let m = &mut self.graph.buses[mi];
                    if m.out_mono {
                        for v in m.output[..(n * 2) as usize].iter_mut() {
                            *v = (*v as f64 * UPMIX) as f32;
                        }
                    }
                    dst.copy_from_slice(&m.output[..(n * 2) as usize]);
                }
            }
            done += n;
            self.position += n;
            // Ended ids; finished instances leave the player.
            let mut k = 0;
            while k < self.live.len() {
                let (id, serial) = self.live[k];
                if self
                    .insts
                    .iter()
                    .find(|e| e.serial == serial)
                    .is_none_or(|e| e.done)
                {
                    self.ended_add(id);
                    self.live.remove(k);
                } else {
                    k += 1;
                }
            }
            self.insts.retain(|e| !e.done);
        }
        self.scratch = scratch;
        self.chunk = chunk;
        self.seen = seen;
        self.slots = slots;
        self.snap_key = snap_key;
        sh.position.store(self.position, Ordering::Release);
    }
}
