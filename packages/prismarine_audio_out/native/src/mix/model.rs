//! The model of the engine, read once from the blob that prismarine_audio's
//! `projectBlob` writes. Strings are interned, and every list is in the
//! order of the Dart model.

use std::collections::HashMap;

#[derive(Clone)]
pub struct Curve {
    pub x: Vec<f64>,
    pub y: Vec<f64>,
    pub s: Vec<f64>,
}

#[derive(Clone)]
pub struct PMap {
    pub x: Vec<f64>,
    pub y: Vec<f64>,
}

#[derive(Clone)]
pub struct Auto {
    pub timeline: bool,
    pub guid: i32,
    /// Lower-cased.
    pub name: i32,
    pub curve: Curve,
}

pub const MOD_RANDOM: i32 = 0;
pub const MOD_AHDSR: i32 = 1;

#[derive(Clone)]
pub struct Mod {
    pub kind: i32,
    pub type_str: i32,
    pub min: f64,
    pub max: f64,
    pub initial: f64,
    pub peak: f64,
    pub sustain: f64,
    pub attack: f64,
    pub hold: f64,
    pub decay: f64,
    pub release: f64,
}

#[derive(Clone)]
pub struct Prop {
    pub index: i64,
    /// A volume in dB. Several curves add up.
    pub volume: bool,
    pub map: Option<PMap>,
    pub autos: Vec<Auto>,
    pub mods: Vec<Mod>,
}

/// The value of a DSP parameter, a number, an on or off switch or nothing.
pub struct FxParam {
    pub has_value: bool,
    pub value: f64,
    pub switch: bool,
}

impl FxParam {
    /// Returns the value that mix states and modulators start from, set for
    /// a number only.
    pub fn stored(&self) -> Option<f64> {
        (self.has_value && !self.switch).then_some(self.value)
    }
}

pub const FX_SEND: i32 = 0;
pub const FX_SIDECHAIN: i32 = 1;
pub const FX_DSP: i32 = 2;

pub struct Fx {
    pub kind: i32,
    pub guid: i32,
    pub bypass: bool,
    pub prefader: bool,
    pub inactive: bool,
    /// The kind of DSP that it makes, −1 for none.
    pub dsp: i32,
    pub label: i32,
    pub return_bus: i32,
    pub return_path: i32,
    pub level: f64,
    pub targets: Vec<i32>,
    pub params: Vec<FxParam>,
    /// A compressor keyed by sidechain taps.
    pub sidechain_input: bool,
    /// A lowpass at 22000 Hz or more with a resonance of 1 or less passes
    /// its input unchanged.
    pub pass_at_top: bool,
    pub props: Vec<Prop>,
}

pub const LAYOUT_MONO: i64 = 0;
pub const LAYOUT_SURROUND51: i64 = 3;

pub struct Bus {
    pub guid: i32,
    /// The master bus of the mixer.
    pub master: bool,
    pub output: i32,
    pub output_path: i32,
    /// The path of a mixer bus, −1 elsewhere.
    pub path: i32,
    pub volume: f64,
    /// A LAYOUT_* value for mono, stereo, quad or 5.1.
    pub layout: i64,
    /// The channel format of an event strip, 1 for mono, 2 for stereo and 6
    /// for 5.1, or 0 for the format of its layout.
    pub format: i64,
    pub fx: Vec<Fx>,
    pub props: Vec<Prop>,
}

pub const INST_SINGLE: i32 = 0;
pub const INST_MULTI: i32 = 1;
pub const INST_SCATTERER: i32 = 2;
pub const INST_PROGRAMMER: i32 = 3;
pub const INST_EVENT: i32 = 4;

pub struct Stub {
    pub index: i64,
    pub guid: i32,
    pub initial: f64,
}

pub struct Inst {
    pub guid: i32,
    pub kind: i32,
    pub kind_str: i32,
    pub volume: f64,
    pub pitch: f64,
    pub loop_count: i64,
    /// Stops when its trigger region is left.
    pub cutoff: bool,
    pub output_bus: i32,
    pub props: Vec<Prop>,
    pub wave: i32,
    pub chance: f64,
    pub delay_min: f64,
    pub delay_max: f64,
    pub offset3d: f64,
    /// The start offset in ms, the base of the start offset property.
    pub seek: f64,
    /// The waveform frames that a timelocked placement skips.
    pub left_trim: i64,
    /// The intensity of a mix state instrument in percent.
    pub snap_intensity: f64,
    pub spawn_min: f64,
    pub spawn_max: f64,
    pub spawn_count: i64,
    pub max_poly: i64,
    /// A spawn past [max_poly] stops the oldest live spawn, else it is
    /// skipped.
    pub spawn_steal: bool,
    /// The polyphony limit of the instrument per event instance, 0 for none.
    /// A trigger past it stops the oldest, else it fails.
    pub poly: i64,
    pub poly_steal: bool,
    /// A playlist picks at random by weight, never the last pick twice.
    pub shuffle: bool,
    pub nested: Option<Box<Event>>,
    pub stubs: Vec<Stub>,
    pub entries: Vec<(f64, Inst)>,
}

impl Inst {
    /// Returns the first property with [index].
    pub fn prop(&self, index: i64) -> Option<&Prop> {
        self.props.iter().find(|p| p.index == index)
    }
}

pub struct Placement {
    pub start: i64,
    pub length: i64,
    pub timelocked: bool,
    /// A timelocked waveform repeats to fill its box (Placement.fill).
    pub fill: bool,
    pub inst: Inst,
}

pub struct Sheet {
    pub start: f64,
    pub length: f64,
    pub inst: Inst,
}

pub struct ParamDef {
    pub guid: i32,
    pub name: i32,
    pub min: f64,
    pub max: f64,
    pub def: f64,
    /// The ParameterKind, 0 for a game parameter, 1 for a distance, 2 for a
    /// cone and 3 for another.
    pub kind: i32,
    pub sheets: Vec<Sheet>,
}

pub struct Tempo {
    pub position: i64,
    pub tempo: f64,
    pub beats_per_bar: i64,
    pub beat_unit: i64,
}

pub struct Trans {
    pub is_loop: bool,
    pub is_marker: bool,
    pub start: i64,
    pub end: i64,
    pub dest: i64,
    pub cond: i32,
    pub cond_min: f64,
    pub cond_max: f64,
    pub unit: i64,
    pub multiplier: i64,
}

pub struct SnapEntry {
    pub target: i32,
    pub prop: i64,
    pub value: f64,
    /// The automated property of the entry.
    pub auto: Option<Prop>,
}

pub struct Event {
    pub guid: i32,
    pub path: i32,
    /// A mix state.
    pub snapshot: bool,
    pub oneshot: bool,
    /// The instances that may play at once, 0 for no limit. A start past it
    /// stops the oldest, else it fails.
    pub poly: i64,
    pub poly_steal: bool,
    pub input_bus: Option<Bus>,
    pub master: Bus,
    pub tracks: Vec<Bus>,
    pub returns: Vec<Bus>,
    pub params: Vec<ParamDef>,
    pub place: Vec<Placement>,
    pub tl_length: i64,
    pub tempo: Vec<Tempo>,
    pub trans: Vec<Trans>,
    // The mix state part.
    pub priority: i64,
    /// Its own intensity from 0 to 1.
    pub intensity: f64,
    pub snap: Vec<SnapEntry>,
    pub intensity_prop: Option<Prop>,
    /// The unique lower-cased parameter names in the order of their first
    /// insertion, with the last parameter of each.
    pub snap_params: Vec<(i32, usize)>,
    /// The automated properties by owner and index, as EventInstance._props.
    pub keys: Vec<(i32, i64, Prop)>,
    pub nsheets: usize,
    /// The waveforms that an instance of a top-level event may play.
    pub waves: Vec<i32>,
}

impl Event {
    /// Tracks, returns and the master track, in that order.
    pub fn bus(&self, i: usize) -> &Bus {
        let (t, r) = (self.tracks.len(), self.returns.len());
        if i < t {
            &self.tracks[i]
        } else if i < t + r {
            &self.returns[i - t]
        } else {
            &self.master
        }
    }
    pub fn nbuses(&self) -> usize {
        self.tracks.len() + self.returns.len() + 1
    }
}

pub struct Wave {
    pub path: i32,
    pub label: i32,
    pub has_file: bool,
    pub streamed: bool,
    pub ogg: bool,
    pub frames: i64,
    pub rate: i64,
    pub channels: i64,
}

pub struct Model {
    pub strings: Vec<String>,
    pub ids: HashMap<String, i32>,
    pub waves: Vec<Wave>,
    /// The early taps of the reverb as ms, left gain and right gain.
    pub taps: Vec<f64>,
    pub events: Vec<Box<Event>>,
    pub event_by_string: Vec<i32>,
    pub snaps: Vec<Box<Event>>,
    pub snap_by_string: Vec<i32>,
    pub buses: Vec<Bus>,
    /// The mixer bus an event without an input bus plays into.
    pub s_bus_root: i32,
}

impl Model {
    pub fn id(&self, s: &str) -> i32 {
        *self.ids.get(s).unwrap_or(&-1)
    }
    pub fn str(&self, id: i32) -> &str {
        if id >= 0 && (id as usize) < self.strings.len() {
            &self.strings[id as usize]
        } else {
            "null"
        }
    }
}

struct Rd<'a> {
    b: &'a [u8],
    p: usize,
    bad: bool,
}

impl<'a> Rd<'a> {
    fn take(&mut self, n: usize) -> &'a [u8] {
        if self.p + n > self.b.len() {
            self.bad = true;
            self.p = self.b.len();
            return &[0u8; 8][..n.min(8)];
        }
        let s = &self.b[self.p..self.p + n];
        self.p += n;
        s
    }
    fn i32(&mut self) -> i32 {
        let s = self.take(4);
        if s.len() < 4 {
            return 0;
        }
        i32::from_le_bytes(s.try_into().unwrap())
    }
    fn i64(&mut self) -> i64 {
        let s = self.take(8);
        if s.len() < 8 {
            return 0;
        }
        i64::from_le_bytes(s.try_into().unwrap())
    }
    fn f64(&mut self) -> f64 {
        f64::from_bits(self.i64() as u64)
    }
    fn b(&mut self) -> bool {
        let s = self.take(1);
        !s.is_empty() && s[0] != 0
    }
    fn n(&mut self) -> usize {
        let n = self.i32();
        if !(0..=(1 << 26)).contains(&n) {
            if crate::mix::env("MIX_DEBUG").is_some() {
                eprintln!("model blob: bad count {n} at byte {}", self.p - 4);
            }
            self.bad = true;
            return 0;
        }
        n as usize
    }
    fn list<T>(&mut self, mut f: impl FnMut(&mut Self) -> T) -> Vec<T> {
        let n = self.n();
        let mut v = Vec::with_capacity(n.min(1 << 16));
        for _ in 0..n {
            if self.bad {
                break;
            }
            v.push(f(self));
        }
        v
    }

    fn curve(&mut self) -> Curve {
        let pts = self.list(|r| (r.f64(), r.f64(), r.f64()));
        Curve {
            x: pts.iter().map(|p| p.0).collect(),
            y: pts.iter().map(|p| p.1).collect(),
            s: pts.iter().map(|p| p.2).collect(),
        }
    }

    fn prop(&mut self) -> Prop {
        let index = self.i64();
        let volume = self.b();
        let map = if self.b() {
            let pts = self.list(|r| (r.f64(), r.f64()));
            Some(PMap {
                x: pts.iter().map(|p| p.0).collect(),
                y: pts.iter().map(|p| p.1).collect(),
            })
        } else {
            None
        };
        let autos = self.list(|r| Auto {
            timeline: r.b(),
            guid: r.i32(),
            name: r.i32(),
            curve: r.curve(),
        });
        let mods = self.list(|r| Mod {
            kind: r.i32(),
            type_str: r.i32(),
            min: r.f64(),
            max: r.f64(),
            initial: r.f64(),
            peak: r.f64(),
            sustain: r.f64(),
            attack: r.f64(),
            hold: r.f64(),
            decay: r.f64(),
            release: r.f64(),
        });
        Prop {
            index,
            volume,
            map,
            autos,
            mods,
        }
    }

    fn fx(&mut self) -> Fx {
        let kind = self.i32();
        let guid = self.i32();
        let bypass = self.b();
        let prefader = self.b();
        let mut fx = Fx {
            kind,
            guid,
            bypass,
            prefader,
            inactive: false,
            dsp: -1,
            label: -1,
            return_bus: -1,
            return_path: -1,
            level: -80.0,
            targets: Vec::new(),
            params: Vec::new(),
            sidechain_input: false,
            pass_at_top: false,
            props: Vec::new(),
        };
        match kind {
            FX_SEND => {
                fx.return_bus = self.i32();
                fx.return_path = self.i32();
                fx.level = self.f64();
            }
            FX_SIDECHAIN => {
                fx.inactive = self.b();
                fx.label = self.i32();
                fx.targets = self.list(|r| r.i32());
            }
            _ => {
                fx.dsp = self.i32();
                fx.label = self.i32();
                fx.params = self.list(|r| FxParam {
                    has_value: r.b(),
                    value: r.f64(),
                    switch: r.b(),
                });
                fx.sidechain_input = self.b();
                fx.pass_at_top = self.b();
            }
        }
        fx.props = self.list(|r| r.prop());
        fx
    }

    fn bus(&mut self) -> Bus {
        let guid = self.i32();
        let master = self.b();
        let output = self.i32();
        let output_path = self.i32();
        let path = self.i32();
        let volume = self.f64();
        let layout = self.i64();
        let format = self.i64();
        let fx = self.list(|r| r.fx());
        let props = self.list(|r| r.prop());
        Bus {
            guid,
            master,
            output,
            output_path,
            path,
            volume,
            layout,
            format,
            fx,
            props,
        }
    }

    fn inst(&mut self) -> Inst {
        Inst {
            guid: self.i32(),
            kind: self.i32(),
            kind_str: self.i32(),
            volume: self.f64(),
            pitch: self.f64(),
            loop_count: self.i64(),
            cutoff: self.b(),
            output_bus: self.i32(),
            props: self.list(|r| r.prop()),
            wave: self.i32(),
            chance: self.f64(),
            delay_min: self.f64(),
            delay_max: self.f64(),
            offset3d: self.f64(),
            seek: self.f64(),
            left_trim: self.i64(),
            snap_intensity: self.f64(),
            spawn_min: self.f64(),
            spawn_max: self.f64(),
            spawn_count: self.i64(),
            max_poly: self.i64(),
            spawn_steal: self.b(),
            poly: self.i64(),
            poly_steal: self.b(),
            shuffle: self.b(),
            nested: if self.b() { Some(self.event()) } else { None },
            stubs: self.list(|r| Stub {
                index: r.i64(),
                guid: r.i32(),
                initial: r.f64(),
            }),
            entries: self.list(|r| (r.f64(), r.inst())),
        }
    }

    fn event(&mut self) -> Box<Event> {
        let guid = self.i32();
        let path = self.i32();
        let snapshot = self.b();
        let oneshot = self.b();
        let poly = self.i64();
        let poly_steal = self.b();
        let input_bus = if self.b() { Some(self.bus()) } else { None };
        let master = self.bus();
        let tracks = self.list(|r| r.bus());
        let returns = self.list(|r| r.bus());
        let params = self.list(|r| ParamDef {
            guid: r.i32(),
            name: r.i32(),
            min: r.f64(),
            max: r.f64(),
            def: r.f64(),
            kind: r.i32(),
            sheets: r.list(|r| Sheet {
                start: r.f64(),
                length: r.f64(),
                inst: r.inst(),
            }),
        });
        let place = self.list(|r| Placement {
            start: r.i64(),
            length: r.i64(),
            timelocked: r.b(),
            fill: r.b(),
            inst: r.inst(),
        });
        let tl_length = self.i64();
        let tempo = self.list(|r| Tempo {
            position: r.i64(),
            tempo: r.f64(),
            beats_per_bar: r.i64(),
            beat_unit: r.i64(),
        });
        let trans = self.list(|r| Trans {
            is_loop: r.b(),
            is_marker: r.b(),
            start: r.i64(),
            end: r.i64(),
            dest: r.i64(),
            cond: r.i32(),
            cond_min: r.f64(),
            cond_max: r.f64(),
            unit: r.i64(),
            multiplier: r.i64(),
        });
        let priority = self.i64();
        let intensity = self.f64();
        let snap = self.list(|r| {
            let (target, prop, value) = (r.i32(), r.i64(), r.f64());
            let auto = if r.b() { Some(r.prop()) } else { None };
            SnapEntry {
                target,
                prop,
                value,
                auto,
            }
        });
        let intensity_prop = if self.b() { Some(self.prop()) } else { None };
        let snap_params = self.list(|r| (r.i32(), r.i32().max(0) as usize));
        let nsheets = params.iter().map(|p| p.sheets.len()).sum();
        let mut e = Box::new(Event {
            guid,
            path,
            snapshot,
            oneshot,
            poly,
            poly_steal,
            input_bus,
            master,
            tracks,
            returns,
            params,
            place,
            tl_length,
            tempo,
            trans,
            priority,
            intensity,
            snap,
            intensity_prop,
            snap_params,
            keys: Vec::new(),
            nsheets,
            waves: Vec::new(),
        });
        let mut keys: Vec<(i32, i64, Prop)> = Vec::new();
        let mut add = |owner: i32, p: &Prop| {
            if p.autos.is_empty() {
                return;
            }
            if let Some(k) = keys.iter_mut().find(|k| k.0 == owner && k.1 == p.index) {
                k.2 = p.clone();
            } else {
                keys.push((owner, p.index, p.clone()));
            }
        };
        let buses: Vec<&Bus> = e
            .tracks
            .iter()
            .chain(e.returns.iter())
            .chain(std::iter::once(&e.master))
            .chain(e.input_bus.iter())
            .collect();
        for b in buses {
            for p in &b.props {
                add(b.guid, p);
            }
            for fx in &b.fx {
                for p in &fx.props {
                    add(fx.guid, p);
                }
            }
        }
        e.keys = keys;
        e
    }
}

fn inst_waves(i: &Inst, out: &mut Vec<i32>) {
    if i.wave >= 0 && !out.contains(&i.wave) {
        out.push(i.wave);
    }
    for (_, en) in &i.entries {
        inst_waves(en, out);
    }
    if let Some(n) = &i.nested {
        event_waves(n, out);
    }
}

fn event_waves(e: &Event, out: &mut Vec<i32>) {
    for p in &e.place {
        inst_waves(&p.inst, out);
    }
    for p in &e.params {
        for s in &p.sheets {
            inst_waves(&s.inst, out);
        }
    }
}

pub fn read(blob: &[u8]) -> Option<Box<Model>> {
    let mut r = Rd {
        b: blob,
        p: 0,
        bad: false,
    };
    if r.i32() != 0x584D434D || r.i32() != 2 {
        return None;
    }
    let strings = r.list(|r| {
        let n = r.n();
        String::from_utf8_lossy(r.take(n)).into_owned()
    });
    let mut ids = HashMap::new();
    for (i, s) in strings.iter().enumerate() {
        ids.entry(s.clone()).or_insert(i as i32);
    }
    let waves = r.list(|r| Wave {
        path: r.i32(),
        label: r.i32(),
        has_file: r.b(),
        streamed: r.b(),
        ogg: r.b(),
        frames: r.i64(),
        rate: r.i64(),
        channels: r.i64(),
    });
    let bus_root = r.i32();
    let taps = r.list(|r| [r.f64(), r.f64(), r.f64()]).concat();
    let ns = strings.len();
    let mut event_by_string = vec![-1; ns];
    let mut events = Vec::new();
    let n = r.n();
    for i in 0..n {
        if r.bad {
            break;
        }
        let path = r.i32();
        let mut e = r.event();
        let mut w = Vec::new();
        event_waves(&e, &mut w);
        e.waves = w;
        events.push(e);
        if path >= 0 && (path as usize) < ns {
            event_by_string[path as usize] = i as i32;
        }
    }
    let mut snap_by_string = vec![-1; ns];
    let mut snaps = Vec::new();
    let n = r.n();
    for i in 0..n {
        if r.bad {
            break;
        }
        let path = r.i32();
        snaps.push(r.event());
        if path >= 0 && (path as usize) < ns {
            snap_by_string[path as usize] = i as i32;
        }
    }
    let buses = r.list(|r| r.bus());
    if crate::mix::env("MIX_DEBUG").is_some() {
        eprintln!(
            "model blob: {} strings, {} waves, {} events, {} snapshots, {} buses, end {} of {}",
            strings.len(),
            waves.len(),
            events.len(),
            snaps.len(),
            buses.len(),
            r.p,
            blob.len()
        );
    }
    if r.bad {
        return None;
    }
    let m = Box::new(Model {
        strings,
        ids,
        waves,
        taps,
        events,
        event_by_string,
        snaps,
        snap_by_string,
        buses,
        s_bus_root: bus_root,
    });
    Some(m)
}
