//! Building an instance and starting it.

use super::*;

impl Inst {
    /// Builds an instance of [def] for render calls of up to [outer] frames,
    /// with everything that it can use while it plays. [pitch] is the most
    /// semitones by which the instrument of a parent raises its pitch. It
    /// does not run on the render thread. The poster builds the instance of a
    /// start, and an instance builds those of its nested events.
    pub fn build(b: &Build, def: &'static Event, outer: usize, pitch: f64) -> Inst {
        let np = def.params.len();
        let mut slot = vec![0usize; np];
        for (i, s) in slot.iter_mut().enumerate() {
            *s = def.params[..i]
                .iter()
                .position(|q| q.guid == def.params[i].guid)
                .unwrap_or(i);
        }
        let rise = pitch + own_pitch(def);
        let cap = if rise > 0.0 {
            (outer as f64 * dpow(2.0, rise / 12.0)).ceil() as usize + 4
        } else {
            outer
        };
        let mut unsupported = Vec::new();
        let mut strips: Vec<Strip> = Vec::new();
        let mut strip_guid: Vec<i32> = Vec::new();
        for bi in 0..def.nbuses() {
            let bus = def.bus(bi);
            let s = Strip::build(b, bus, cap, &def.keys, &mut unsupported);
            match strip_guid.iter().position(|&g| g == bus.guid) {
                Some(k) => strips[k] = s,
                None => {
                    strips.push(s);
                    strip_guid.push(bus.guid);
                }
            }
        }
        let master = strip_guid
            .iter()
            .position(|&g| g == def.master.guid)
            .unwrap_or(0);
        let order = (0..def.nbuses())
            .map(|bi| {
                strip_guid
                    .iter()
                    .position(|&g| g == def.bus(bi).guid)
                    .unwrap_or(master)
            })
            .collect();
        let input_bus = def
            .input_bus
            .as_ref()
            .map(|bus| Strip::build(b, bus, cap, &def.keys, &mut unsupported));
        // The nested events that it can start, with the pool of each
        // instrument.
        let mut nested: Vec<Pool> = Vec::new();
        let mut snaps: Vec<SnapPool> = Vec::new();
        let mut multis = 0;
        {
            let mut add = |i: &'static crate::mix::model::Inst, p: f64, n: usize| {
                let Some(d) = i.nested.as_deref() else { return };
                if d.snapshot {
                    if !snaps.iter().any(|q| std::ptr::eq(q.inst, i)) {
                        let free = (0..SNAP_POOL)
                            .map(|_| Owned::new(b.garbage, Snap::build(d)))
                            .collect();
                        snaps.push(SnapPool { inst: i, free });
                    }
                    return;
                }
                if nested.iter().any(|q| std::ptr::eq(q.inst, i)) {
                    return;
                }
                let free = (0..n)
                    .map(|_| Owned::new(b.garbage, Inst::build(b, d, cap, p)))
                    .collect();
                nested.push(Pool { inst: i, free });
            };
            let mut walk = |i: &'static crate::mix::model::Inst| {
                nested_insts(i, 0.0, NESTED_POOL, &mut add);
                count_multis(i, &mut multis);
            };
            for p in &def.place {
                walk(&p.inst);
            }
            for pd in &def.params {
                for sh in &pd.sheets {
                    walk(&sh.inst);
                }
            }
        }
        // The keys of its sends and of the sends of its nested events, which
        // come up into it.
        let sends = (0..def.nbuses())
            .map(|bi| def.bus(bi))
            .chain(def.input_bus.iter())
            .flat_map(|bus| bus.fx.iter())
            .filter(|fx| fx.kind == FX_SEND)
            .count();
        let keys = sends
            + nested
                .iter()
                .map(|q| q.free.first().map_or(0, |c| c.send_out.e.len()))
                .sum::<usize>();
        // The sends of a 5.1 strip need a 5.1 scratch.
        let any51 = strips
            .iter()
            .chain(input_bus.iter())
            .any(|s| s.out_ch() == 6);
        let wide = match &input_bus {
            Some(ib) => ib.out_ch(),
            None => strips[master].out_ch(),
        };
        let pitched = (rise > 0.0).then(|| {
            let room = (cap + 8) * wide;
            Box::new(Pitched {
                ratio: 1.0,
                pos: 0.0,
                count: 0,
                held: Vec::with_capacity(keys + 1),
                spare: (0..keys + 1).map(|_| Vec::with_capacity(room)).collect(),
                main: vec![0.0; cap * wide],
                sends: OutMap::with(keys, outer * 2),
            })
        });
        // Room for its mix state requests and those of its nested events.
        let nested_asks = nested
            .iter()
            .any(|p| p.free.first().is_some_and(|c| c.snap_out.capacity() > 0));
        let snap_room = if snaps.is_empty() && !nested_asks {
            0
        } else {
            SNAP_OPS
        };
        Inst {
            def,
            rng: Rng(0),
            programmer: None,
            serial: 0,
            paused: false,
            stopping: false,
            cut: false,
            done: false,
            stolen: false,
            releasing: false,
            cursor: 0,
            stop_at: 0,
            pass: 0,
            pending: None,
            values: vec![0.0; np],
            slot,
            strips,
            strip_guid,
            order,
            master,
            input_bus,
            send_out: OutMap::with(keys, cap * 2),
            voices: Vec::with_capacity(MAX_SOUNDS),
            sounds: 0,
            base_db: 0.0,
            pitch: 0.0,
            env: None,
            env_map: None,
            age: 0.0,
            released: 0.0,
            release_from: 0.0,
            pitched,
            pitched_on: false,
            async_inside: vec![false; def.place.len()],
            sheet_inside: vec![false; def.nsheets],
            locked: (0..def.place.len()).map(|_| None).collect(),
            playlists: Vec::with_capacity(multis),
            volume: 1.0,
            vol_prev: None,
            programmer_started: false,
            spatial: None,
            spatial_gen: 0,
            outer,
            cap,
            nested,
            snap_out: Vec::with_capacity(snap_room),
            snaps,
            unsupported,
            scratch: vec![0.0; cap * if any51 { 6 } else { 2 }],
            gains: vec![0.0; cap],
            nest_buf: vec![0.0; outer * 6],
        }
    }

    /// Starts it as new, as Dart's EventInstance constructor, in the memory
    /// that it was built with, for the instance of a start or a nested event
    /// from its pool.
    pub(crate) fn init(&mut self, cx: &mut Cx, rng: Rng, programmer: Option<SrcRef>, seek: f64) {
        let def = self.def;
        self.clear_sounds();
        self.rng = rng;
        self.programmer = programmer;
        self.serial = 0;
        self.paused = false;
        self.stopping = false;
        self.cut = false;
        self.done = false;
        self.stolen = false;
        self.releasing = false;
        self.cursor = dround(dmax(0.0, seek) * RATE_F);
        self.stop_at = 0;
        self.pass = 0;
        self.pending = None;
        self.values.fill(0.0);
        for i in 0..def.params.len() {
            let p = &def.params[i];
            self.values[self.slot[i]] = dclamp(p.def, p.min, p.max);
        }
        for fx in &self.unsupported {
            problem!(cx, "unsupported effect {}", cx.s(fx.label));
        }
        for s in self.strips.iter_mut().chain(self.input_bus.iter_mut()) {
            s.reset();
        }
        self.send_out.clear();
        self.sounds = 0;
        self.base_db = 0.0;
        self.pitch = 0.0;
        self.env = None;
        self.env_map = None;
        self.age = 0.0;
        self.released = 0.0;
        self.release_from = 0.0;
        self.pitched_on = false;
        self.async_inside.fill(false);
        self.sheet_inside.fill(false);
        self.locked.fill_with(|| None);
        self.playlists.clear();
        self.volume = 1.0;
        self.vol_prev = None;
        self.programmer_started = false;
        self.spatial = None;
        self.modulate(cx);
    }
}
