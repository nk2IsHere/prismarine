//! The mixer graph with its buses and their properties, as graph.dart.

use super::*;

struct PropSlot {
    owner: i32,
    index: i64,
    base: Option<f64>,
    volume_type: bool,
    gain_type: bool,
    block: i64,
    value: Option<f64>,
}

pub(crate) struct Graph {
    pub(crate) buses: Vec<Strip>,
    by_guid: Vec<i32>,
    by_path: Vec<i32>,
    unique: Vec<usize>,
    order: Vec<usize>,
    pub(crate) master: Option<usize>,
    /// The compressors by effect id, as the id, the bus and the key.
    comps: Vec<(i32, usize, usize)>,
    keys: Keys,
    pkeys: Vec<PropSlot>,
    pub(crate) active: Vec<Owned<Snap>>,
    block: i64,
}

struct GraphSink<'a, 'b> {
    cx: &'a mut Cx<'b>,
    buses: &'a mut Vec<Strip>,
    by_guid: &'a [i32],
    by_path: &'a [i32],
    comps: &'a [(i32, usize, usize)],
    pkeys: &'a mut Vec<PropSlot>,
    active: &'a [Owned<Snap>],
    block: i64,
}

fn lookup(v: &[i32], id: i32) -> Option<usize> {
    if id < 0 || id as usize >= v.len() {
        return None;
    }
    let i = v[id as usize];
    if i < 0 {
        None
    } else {
        Some(i as usize)
    }
}

impl Sink for GraphSink<'_, '_> {
    fn prop(&mut self, owner: i32, index: i64) -> Option<f64> {
        let ps = self
            .pkeys
            .iter_mut()
            .find(|p| p.owner == owner && p.index == index)?;
        if ps.block == self.block {
            return ps.value;
        }
        let mut v: Option<f64> = None;
        for s in self.active {
            let k = s.intensity();
            if k <= 0.0 {
                continue;
            }
            for en in &s.def.snap {
                if en.target != owner || en.prop != index {
                    continue;
                }
                let value = s.entry_value(en);
                let from = v.or(ps.base).unwrap_or(value);
                if (index == 0 && ps.volume_type) || ps.gain_type {
                    let g = db_gain(from) + (db_gain(value) - db_gain(from)) * k;
                    v = Some(if g <= 0.0 {
                        -80.0
                    } else {
                        20.0 * log(g) / LN10
                    });
                } else {
                    v = Some(from + (value - from) * k);
                }
            }
        }
        // A property that no mix state touches returns to its stored value.
        let v = v.or(ps.base);
        ps.block = self.block;
        ps.value = v;
        v
    }
    fn send(&mut self, fx: &'static Fx, buf: &[f32], mono: bool, ch: usize) {
        let r = lookup(self.by_guid, fx.return_bus).or_else(|| {
            if fx.return_path >= 0 {
                lookup(self.by_path, fx.return_path)
            } else {
                None
            }
        });
        match r {
            None => {
                let s = self.cx.s(fx.return_bus);
                problem!(self.cx, "send to unknown return {}", s);
            }
            Some(r) => self.buses[r].add(buf, buf.len() / ch, mono, ch),
        }
    }
    fn refused(&mut self, fx: &'static Fx) {
        let l = self.cx.s(fx.label);
        problem!(self.cx, "echo {}: delay over the room it was built with", l);
    }
    fn no51(&mut self, fx: &'static Fx) {
        let l = self.cx.s(fx.label);
        problem!(self.cx, "no 5.1 form of effect {}", l);
    }
    fn sidechain(&mut self, targets: &[i32], buf: &[f32], keys: &mut Keys) {
        // The buffer of this tap goes to every target without a key.
        let mut shared: Option<usize> = None;
        for &t in targets {
            let Some(c) = self.comps.iter().rev().find(|c| c.0 == t) else {
                continue;
            };
            match keys.slot[c.2] {
                None => {
                    let i = match shared {
                        Some(i) => i,
                        None => {
                            let Some(i) = keys.alloc(buf) else {
                                problem!(self.cx, "no room for a sidechain key");
                                continue;
                            };
                            shared = Some(i);
                            i
                        }
                    };
                    keys.slot[c.2] = Some(i);
                }
                Some(cur) => {
                    let kb = &mut keys.pool[cur];
                    let n = kb.len().min(buf.len());
                    for i in 0..n {
                        kb[i] = (kb[i] as f64 + buf[i] as f64) as f32;
                    }
                }
            }
        }
    }
}

impl Graph {
    pub(crate) fn new(cx: &mut Cx) -> Graph {
        let m = cx.m;
        let ns = m.strings.len();
        let mut g = Graph {
            buses: Vec::new(),
            by_guid: vec![-1; ns],
            by_path: vec![-1; ns],
            unique: Vec::new(),
            order: Vec::new(),
            master: None,
            comps: Vec::new(),
            keys: Keys::default(),
            pkeys: Vec::new(),
            active: Vec::with_capacity(MAX_SNAPSHOTS),
            block: 0,
        };
        let garbage = cx.sh.garbage.clone();
        let build = Build {
            m,
            garbage: &garbage,
        };
        let mut unsupported = Vec::new();
        for (i, b) in m.buses.iter().enumerate() {
            let mut s = Strip::build(&build, b, BLOCK, &[], &mut unsupported);
            for fx in unsupported.drain(..) {
                problem!(cx, "unsupported effect {}", cx.s(fx.label));
            }
            let prev = lookup(&g.by_guid, b.guid);
            match prev {
                None => g.unique.push(i),
                Some(p) => {
                    for u in g.unique.iter_mut() {
                        if *u == p {
                            *u = i;
                        }
                    }
                }
            }
            if b.guid >= 0 {
                g.by_guid[b.guid as usize] = i as i32;
            }
            if b.path >= 0 {
                g.by_path[b.path as usize] = i as i32;
            }
            if b.master && g.master.is_none() {
                g.master = Some(i);
            }
            for st in s.st.iter_mut() {
                if let Stage::Effect { fx, dsp, key } = st {
                    if dsp.is_compressor() {
                        let k = g.keys.slot.len();
                        g.keys.slot.push(None);
                        *key = Some(k);
                        match g.comps.iter().position(|c| c.0 == fx.guid) {
                            Some(c) => g.comps[c] = (fx.guid, i, k),
                            None => g.comps.push((fx.guid, i, k)),
                        }
                    }
                }
            }
            g.buses.push(s);
        }
        g.keys = Keys::with(g.keys.slot.len(), BLOCK * 2);
        // Kahn's order puts children before parents, senders before returns
        // and sidechain sources before the buses of their compressors.
        let nb = g.buses.len();
        let mut after: Vec<Vec<usize>> = vec![Vec::new(); nb];
        let mut need = vec![0usize; nb];
        let mut edge = |a: usize, b: Option<usize>, after: &mut Vec<Vec<usize>>| {
            if let Some(b) = b {
                if a != b && !after[a].contains(&b) {
                    after[a].push(b);
                    need[b] += 1;
                }
            }
        };
        for &i in &g.unique {
            let b = g.buses[i].def;
            edge(i, lookup(&g.by_guid, b.output), &mut after);
            for fx in &b.fx {
                if fx.kind == FX_SEND {
                    edge(i, lookup(&g.by_guid, fx.return_bus), &mut after);
                } else if fx.kind == FX_SIDECHAIN {
                    for &t in &fx.targets {
                        let sb = g.comps.iter().find(|c| c.0 == t).map(|c| c.1);
                        edge(i, sb, &mut after);
                    }
                }
            }
        }
        let mut ready: Vec<usize> = g.unique.iter().copied().filter(|&i| need[i] == 0).collect();
        let mut head = 0;
        let mut placed = vec![false; nb];
        while head < ready.len() {
            let s = ready[head];
            head += 1;
            g.order.push(s);
            placed[s] = true;
            for &b in &after[s] {
                need[b] -= 1;
                if need[b] == 0 {
                    ready.push(b);
                }
            }
        }
        for &u in &g.unique {
            if !placed[u] {
                g.order.push(u);
            }
        }
        // The stored values and kinds of the properties that mix states
        // address.
        const GAIN: [(i32, &[usize]); 6] = [
            (crate::mix::dsp::LIMITER, &[1, 2]),
            (crate::mix::dsp::COMPRESSOR, &[0, 4]),
            (crate::mix::dsp::REVERB, &[8, 11, 12]),
            (crate::mix::dsp::THREEEQ, &[0, 1, 2]),
            (
                crate::mix::dsp::CHANMIX,
                &[
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                    23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
                ],
            ),
            (crate::mix::dsp::MBEQ, &[3, 7, 11, 15, 19]),
        ];
        for d in &m.snaps {
            for en in &d.snap {
                if g.pkeys
                    .iter()
                    .any(|p| p.owner == en.target && p.index == en.prop)
                {
                    continue;
                }
                let (owner, index) = (en.target, en.prop);
                let mut ps = PropSlot {
                    owner,
                    index,
                    base: None,
                    volume_type: false,
                    gain_type: false,
                    block: -1,
                    value: None,
                };
                for b in &m.buses {
                    if b.guid == owner {
                        ps.volume_type = true;
                        if index == 0 {
                            ps.base = Some(b.volume);
                        }
                    }
                    for fx in &b.fx {
                        if fx.guid != owner {
                            continue;
                        }
                        if fx.kind == FX_SEND {
                            ps.volume_type = true;
                            if index == 0 {
                                ps.base = Some(fx.level);
                            }
                        }
                        for (p, prm) in fx.params.iter().enumerate() {
                            if 1000 + p as i64 != index {
                                continue;
                            }
                            if let Some(v) = prm.stored() {
                                ps.base = Some(v);
                            }
                            if GAIN.iter().any(|(t, ix)| *t == fx.dsp && ix.contains(&p)) {
                                ps.gain_type = true;
                            }
                        }
                    }
                }
                g.pkeys.push(ps);
            }
        }
        g
    }

    pub(crate) fn render(
        &mut self,
        cx: &mut Cx,
        inputs: &OutMap,
        inputs51: &OutMap,
        frames: usize,
        scratch: &mut [f32],
    ) {
        self.active.retain(|s| !s.stopped);
        self.active
            .sort_unstable_by(|a, b| a.priority.cmp(&b.priority).then(a.order.cmp(&b.order)));
        self.block += 1;
        for &u in &self.unique {
            self.buses[u].begin(frames);
        }
        for (path, buf) in inputs.iter() {
            let b = lookup(&self.by_path, path);
            if b.is_none() {
                problem!(cx, "no mixer bus {} (into the master)", cx.s(path));
            }
            if let Some(s) = b.or(self.master) {
                self.buses[s].add(buf, frames, false, 2);
            }
        }
        for (path, buf) in inputs51.iter() {
            let b = lookup(&self.by_path, path);
            if b.is_none() {
                problem!(cx, "no mixer bus {} (into the master)", cx.s(path));
            }
            if let Some(s) = b.or(self.master) {
                self.buses[s].add(buf, frames, false, 6);
            }
        }
        for oi in 0..self.order.len() {
            let i = self.order[oi];
            let mut s = std::mem::replace(&mut self.buses[i], Strip::empty());
            {
                let mut sink = GraphSink {
                    cx,
                    buses: &mut self.buses,
                    by_guid: &self.by_guid,
                    by_path: &self.by_path,
                    comps: &self.comps,
                    pkeys: &mut self.pkeys,
                    active: &self.active,
                    block: self.block,
                };
                s.process(frames, &mut sink, &mut self.keys, scratch);
            }
            if let Some(p) = lookup(&self.by_guid, s.def.output) {
                if p != i {
                    self.buses[p].add(&s.output, frames, s.out_mono, s.out_ch());
                }
            }
            self.buses[i] = s;
        }
    }
}
