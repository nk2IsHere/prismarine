//! An event instance and its sounds (instance.dart): the types here, the
//! methods in the child modules.

use super::*;

mod build;
mod life;
mod play;
mod render;
mod sound;
mod timeline;
mod voice;

// ---------------------------------------------------------------- instances

enum Body {
    /// A slot's stand-in while its sound renders.
    Empty,
    /// [fade_from]: a stolen voice's declick starts at this pass frame (then
    /// at 0 in later passes); [faded]: frames of it done.
    /// [bend]: semitones on top of [rate] this block (a scatterer's pitch
    /// envelope moving its spawn).
    /// [armed]: not rendered yet (a stream's start hold applies).
    Voice {
        reader: Reader,
        rate: f64,
        gain: f64,
        lp: bool,
        pos: f64,
        pan: Option<(f64, f64)>,
        fade_from: Option<i64>,
        faded: i64,
        bend: f64,
        armed: bool,
    },
    /// A nested event: an instance from its instrument's pool, back there
    /// when the sound goes.
    Nested {
        event: Owned<Inst>,
        inst: &'static crate::mix::model::Inst,
    },
    /// Its live spawns are the sounds it owns ([spawn_owner]) that haven't
    /// ended.
    Scatter {
        inst: &'static crate::mix::model::Inst,
        spawned: i64,
        stopped: bool,
        env: Option<ScatEnv>,
    },
    /// An event instrument on a snapshot (Dart `_SnapshotSound`): [key]
    /// names its snapshot in the mixer once started; [at] the instance's
    /// 3D position change it last sent (Inst::spatial_gen).
    Snapshot {
        inst: &'static crate::mix::model::Inst,
        key: i64,
        at: u64,
    },
}

/// A scatterer's pitch AHDSR (Dart `_Scatter.env` and its state): the
/// pitch it was played at, seconds since it started and into its release
/// (−1: not releasing), the release's starting level, and scatterer-time
/// frames to the next spawn (−1: not started).
#[derive(Clone, Copy)]
struct ScatEnv {
    m: &'static crate::mix::model::Mod,
    prop: &'static Prop,
    s0: f64,
    age: f64,
    released: f64,
    from: f64,
    clock: f64,
}

impl ScatEnv {
    fn level(&self) -> f64 {
        if self.released < 0.0 {
            env_level(self.m, self.age)
        } else {
            self.from * (1.0 - self.released / self.m.release)
        }
    }

    /// Leaving its region: true when it stops now (no release).
    fn untrigger(&mut self) -> bool {
        if self.m.release > 0.0 {
            if self.released < 0.0 {
                self.from = self.level();
                self.released = 0.0;
            }
            return false;
        }
        true
    }
}

/// What an instance's snapshot instruments ask of the mixer's snapshots,
/// applied after the instance renders (in order).
pub enum SnapOp {
    Start(Owned<Snap>),
    Set { key: i64, guid: i32, value: f64 },
    Auto { key: i64, dist: f64, cone: f64 },
    Stop(i64),
}

/// Snapshot instances an instance's snapshot instruments can start: two
/// each, built with it.
struct SnapPool {
    inst: &'static crate::mix::model::Inst,
    free: Vec<Owned<Snap>>,
}

const SNAP_POOL: usize = 2;
const SNAP_OPS: usize = 32;

struct Sound {
    /// The instance's count of sounds when it started (names a scatterer's
    /// spawns).
    serial: usize,
    owner: usize,
    cutoff: bool,
    ended: bool,
    bus: usize,
    delay: i64,
    body: Body,
    via: Via,
    /// Stopped by a polyphony limit (no longer counted), and the raw pass it
    /// last rendered in.
    stolen: bool,
    pass: u64,
}

const EMPTY: Sound = Sound {
    serial: 0,
    owner: 0,
    cutoff: false,
    ended: true,
    bus: 0,
    delay: 0,
    body: Body::Empty,
    via: NO_VIA,
    stolen: false,
    pass: 0,
};

/// The owner of a scatterer's spawns (placements and sheets own theirs by
/// address, which never has the top bit set).
fn spawn_owner(serial: usize) -> usize {
    (1 << (usize::BITS - 1)) | serial
}

struct Locked {
    reader: Reader,
    bus: usize,
    rate: f64,
    gain: f64,
    /// The start offset in source frames (property 9).
    seek: f64,
    /// It has rendered (a stream's start hold is over).
    started: bool,
    /// The waveform repeats to fill its box (EventBank.fills).
    fill: bool,
}

/// A pitched instance's resampler, built with the instance (when its pitch
/// can move) and started at its first pitched pass.
struct Pitched {
    ratio: f64,
    pos: f64,
    count: i64,
    held: Vec<(i32, Vec<f32>)>,
    /// Buffers for [held] (each room for a raw pass and what is left over).
    spare: Vec<Vec<f32>>,
    main: Vec<f32>,
    sends: OutMap,
}

/// Instances of a nested event, built for one event instrument.
struct Pool {
    inst: &'static crate::mix::model::Inst,
    free: Vec<Owned<Inst>>,
}

/// The most an instrument (and the multis it is picked from) raises a
/// nested event's pitch, in semitones: its pitch and pitch modulators.
fn inst_pitch(i: &crate::mix::model::Inst) -> f64 {
    let mut b = i.pitch.abs();
    if let Some(p) = i.prop(1) {
        for m in &p.mods {
            b += m.min.abs().max(m.max.abs()) / 100.0 * 48.0;
        }
    }
    b
}

/// The most an event's own pitch modulators move it (semitones).
fn own_pitch(def: &Event) -> f64 {
    let mut b = 0.0;
    for p in &def.master.props {
        if p.index != 1 {
            continue;
        }
        for m in &p.mods {
            if m.kind == MOD_RANDOM {
                b += match &p.map {
                    Some(mp) => {
                        let (lo, hi) =
                            mp.y.iter()
                                .fold((f64::MAX, f64::MIN), |(a, b), &y| (a.min(y), b.max(y)));
                        (hi - lo).max(0.0)
                    }
                    None => m.min.abs().max(m.max.abs()),
                };
            }
        }
    }
    b
}

/// Counts the multis and scatterers (their playlists) in [i].
fn count_multis(i: &crate::mix::model::Inst, n: &mut usize) {
    if i.kind == INST_MULTI || i.kind == INST_SCATTERER {
        *n += 1;
    }
    for (_, e) in &i.entries {
        count_multis(e, n);
    }
}

/// Calls [f] for every nested-event instrument [i] can play, with the
/// pitch it can add on the way and how many can play at once.
fn nested_insts(
    i: &'static crate::mix::model::Inst,
    pitch: f64,
    poly: usize,
    f: &mut impl FnMut(&'static crate::mix::model::Inst, f64, usize),
) {
    let pitch = pitch + inst_pitch(i);
    match i.kind {
        INST_EVENT => f(i, pitch, poly),
        INST_MULTI => {
            for (_, e) in &i.entries {
                nested_insts(e, pitch, poly, f);
            }
        }
        INST_SCATTERER => {
            let poly = if i.max_poly > 0 {
                i.max_poly as usize
            } else {
                SPAWN_POOL
            };
            for (_, e) in &i.entries {
                nested_insts(e, pitch, poly.min(MAX_SOUNDS), f);
            }
        }
        _ => {}
    }
}

const KEY_MAIN: i32 = -2;

/// A stolen instance plays on for one FMOD mix block, then is cut
/// (Dart `_stealDelay`).
const STEAL_DELAY: i64 = 1024;

/// The instruments a sound was played through (a multi, then its entry…),
/// by address, for their polyphony (Dart `_Sound.via`).
#[derive(Clone, Copy)]
struct Via {
    a: [usize; 4],
    n: usize,
}

const NO_VIA: Via = Via { a: [0; 4], n: 0 };

impl Via {
    fn with(mut self, inst: &crate::mix::model::Inst) -> Via {
        if self.n < self.a.len() {
            self.a[self.n] = std::ptr::from_ref(inst) as usize;
            self.n += 1;
        }
        self
    }
    fn has(&self, inst: &crate::mix::model::Inst) -> bool {
        let k = std::ptr::from_ref(inst) as usize;
        self.a[..self.n].contains(&k)
    }
}

pub struct Inst {
    pub(crate) def: &'static Event,
    rng: Rng,
    /// A voice line (a programmer instrument's sound).
    programmer: Option<SrcRef>,
    /// The start that made it (the player's handle).
    pub(crate) serial: i64,
    pub(crate) paused: bool,
    stopping: bool,
    /// Stopped with FMOD's immediate mode (Dart `_immediate`).
    cut: bool,
    pub(crate) done: bool,
    /// Cut by its event's polyphony.
    pub(crate) stolen: bool,
    releasing: bool,
    cursor: i64,
    /// Frames into the declick (negative: frames before it starts).
    stop_at: i64,
    /// Raw passes rendered.
    pass: u64,
    pending: Option<(&'static Trans, i64)>,
    values: Vec<f64>,
    slot: Vec<usize>,
    strips: Vec<Strip>,
    strip_guid: Vec<i32>,
    order: Vec<usize>,
    master: usize,
    input_bus: Option<Strip>,
    pub(crate) send_out: OutMap,
    voices: Vec<Sound>,
    /// Sounds started so far.
    sounds: usize,
    base_db: f64,
    pitch: f64,
    env: Option<&'static Mod>,
    env_map: Option<&'static PMap>,
    age: f64,
    released: f64,
    release_from: f64,
    pitched: Option<Box<Pitched>>,
    /// The resampler is running (Dart: `_pitched != null`).
    pitched_on: bool,
    async_inside: Vec<bool>,
    sheet_inside: Vec<bool>,
    locked: Vec<Option<Locked>>,
    playlists: Vec<(i32, i64)>,
    pub(crate) volume: f64,
    pub(crate) vol_prev: Option<f64>,
    programmer_started: bool,
    /// The relative position (azimuth, distance, cone angle), once set, and
    /// how many times it was set.
    spatial: Option<(f64, f64, f64)>,
    spatial_gen: u64,
    /// The most frames one render() is asked for, and one raw pass (more
    /// when its pitch can rise).
    outer: usize,
    cap: usize,
    /// The nested events it can start.
    nested: Vec<Pool>,
    /// The snapshots its snapshot instruments can start, and their asks
    /// this pass (its nested events' come up into it).
    snaps: Vec<SnapPool>,
    pub(crate) snap_out: Vec<SnapOp>,
    /// Effects the mixer doesn't have (reported when it starts).
    unsupported: Vec<&'static Fx>,
    /// A pass's send scratch, fade gains, and (as a nested event) the
    /// buffer its parent renders it into.
    scratch: Vec<f32>,
    gains: Vec<f32>,
    nest_buf: Vec<f32>,
}

/// The parameter values an instance's automation reads.
struct Vals<'a> {
    def: &'static Event,
    values: &'a [f64],
    slot: &'a [usize],
    cursor: i64,
}

impl Vals<'_> {
    fn slot_by_guid(&self, guid: i32) -> Option<usize> {
        if guid < 0 {
            return None;
        }
        self.def
            .params
            .iter()
            .position(|p| p.guid == guid)
            .map(|i| self.slot[i])
    }
    fn by_name(&self, name: i32) -> Option<usize> {
        if name < 0 {
            return None;
        }
        self.def.params.iter().rposition(|p| p.name == name)
    }
    fn input(&self, a: &Auto) -> f64 {
        if a.timeline {
            return self.cursor as f64;
        }
        if let Some(s) = self.slot_by_guid(a.guid) {
            return self.values[s];
        }
        if let Some(p) = self.by_name(a.name) {
            return self.values[self.slot[p]];
        }
        0.0
    }
    /// _automated; [xt] replaces the cursor for timeline automation.
    fn automated(&self, p: Option<&Prop>, xt: Option<f64>) -> Option<f64> {
        let p = p?;
        if p.autos.is_empty() {
            return None;
        }
        let mut r: Option<f64> = None;
        for a in &p.autos {
            let x = match (a.timeline, xt) {
                (true, Some(x)) => x,
                _ => self.input(a),
            };
            let v = mapped(p, curve_at(&a.curve, x));
            r = Some(match r {
                None => v,
                Some(r) => {
                    if p.volume {
                        r + v
                    } else if p.index == 4 {
                        r * v
                    } else {
                        v
                    }
                }
            });
        }
        r
    }
    fn holds(&self, guid: i32, lo: f64, hi: f64) -> bool {
        if guid < 0 {
            return true;
        }
        match self.slot_by_guid(guid) {
            None => false,
            Some(s) => {
                let v = self.values[s];
                v >= lo && v <= hi
            }
        }
    }
}

/// A start offset of [ms] into [src], in its frames: past the end wraps
/// (EventInstance `_seekFrames`).
fn seek_frames(src: &SrcRef, ms: f64) -> f64 {
    let frames = src.frames();
    if ms <= 0.0 || frames <= 0 {
        return 0.0;
    }
    dmod(ms * src.rate() as f64 / 1000.0, frames as f64)
}

fn ui_offset(p: &Prop, pct: f64) -> f64 {
    match &p.map {
        None => pct,
        Some(m) => {
            map_map(m, map_unmap(m, 0.0) + pct / 100.0 * map_span(m))
                - map_map(m, map_unmap(m, 0.0))
        }
    }
}

fn env_level(m: &Mod, mut t: f64) -> f64 {
    if t < m.attack {
        return m.initial + (m.peak - m.initial) * t / m.attack;
    }
    t -= m.attack;
    if t < m.hold {
        return m.peak;
    }
    t -= m.hold;
    if t < m.decay {
        return m.peak + (m.sustain - m.peak) * t / m.decay;
    }
    m.sustain
}

struct InstSink<'a, 'b> {
    vals: Vals<'a>,
    keys: &'static [(i32, i64, Prop)],
    strips: &'a mut Vec<Strip>,
    guids: &'a [i32],
    send_out: &'a mut OutMap,
    cx: &'a mut Cx<'b>,
    path: i32,
}

impl Sink for InstSink<'_, '_> {
    fn prop(&mut self, owner: i32, index: i64) -> Option<f64> {
        for k in self.keys {
            if k.0 == owner && k.1 == index {
                return self.vals.automated(Some(&k.2), None);
            }
        }
        None
    }
    fn send(&mut self, fx: &'static Fx, buf: &[f32], mono: bool, ch: usize) {
        if let Some(i) = self
            .guids
            .iter()
            .position(|&g| g == fx.return_bus && g >= 0)
        {
            self.strips[i].add(buf, buf.len() / ch, mono, ch);
            return;
        }
        if ch == 6 {
            // Sends out of an event leave it in stereo (Dart: folded).
            let mut st = [0.0f32; 2 * 64];
            let frames = buf.len() / 6;
            let mut at = 0;
            while at < frames {
                let n = (frames - at).min(64);
                downmix51(&buf[at * 6..(at + n) * 6], n, &mut st[..n * 2]);
                self.send_at(fx, &st[..n * 2], at, frames);
                at += n;
            }
            return;
        }
        let key = if fx.return_path >= 0 {
            fx.return_path
        } else {
            fx.return_bus
        };
        let Some(o) = self.send_out.put(key, buf.len()) else {
            let (k, p) = (self.cx.s(key), self.cx.s(self.path));
            problem!(self.cx, "no room for send {} in {}", k, p);
            return;
        };
        let k = if mono { UPMIX } else { 1.0 };
        for i in 0..buf.len() {
            o[i] = (o[i] as f64 + buf[i] as f64 * k) as f32;
        }
    }
    fn no51(&mut self, fx: &'static Fx) {
        let l = self.cx.s(fx.label);
        problem!(self.cx, "no 5.1 form of effect {}", l);
    }
    fn sidechain(&mut self, _targets: &[i32], _buf: &[f32], _keys: &mut Keys) {
        let p = self.cx.s(self.path);
        problem!(self.cx, "sidechain inside an event: {}", p);
    }
    fn refused(&mut self, fx: &'static Fx) {
        let (l, p) = (self.cx.s(fx.label), self.cx.s(self.path));
        problem!(
            self.cx,
            "echo {} in {}: delay over the room it was built with",
            l,
            p
        );
    }
}
impl InstSink<'_, '_> {
    /// A folded 5.1 send's frames [at]..: into the instance's send output
    /// of [frames] frames.
    fn send_at(&mut self, fx: &'static Fx, buf: &[f32], at: usize, frames: usize) {
        let key = if fx.return_path >= 0 {
            fx.return_path
        } else {
            fx.return_bus
        };
        let Some(o) = self.send_out.put(key, frames * 2) else {
            let (k, p) = (self.cx.s(key), self.cx.s(self.path));
            problem!(self.cx, "no room for send {} in {}", k, p);
            return;
        };
        for (v, &b) in o[at * 2..at * 2 + buf.len()].iter_mut().zip(buf) {
            *v = (*v as f64 + b as f64) as f32;
        }
    }
}

/// player.sample: the bound source of waveform [w], or a problem.
fn sample(cx: &mut Cx, w: i32) -> Option<SrcRef> {
    match cx.slots.get(w as usize)? {
        Some(s) if s.kind != Kind::Failed => Some(s.clone()),
        _ => {
            let wv = &cx.m.waves[w as usize];
            problem!(cx, "no sample {}", cx.s(wv.label));
            None
        }
    }
}
