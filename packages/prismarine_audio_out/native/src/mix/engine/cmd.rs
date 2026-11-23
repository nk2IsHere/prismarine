//! The commands that posters send, the limits of the render and the state
//! that every thread shares.

use super::*;

// ---------------------------------------------------------------- commands

pub const OP_START: i32 = 1;
pub const OP_SET_PARAM: i32 = 2;
pub const OP_SET_VOLUME: i32 = 3;
pub const OP_STOP: i32 = 4;
pub const OP_SET_PAUSED: i32 = 5;
pub const OP_START_SNAPSHOT: i32 = 7;
pub const OP_SET_SNAP_PARAM: i32 = 8;
pub const OP_STOP_SNAPSHOT: i32 = 9;
pub const OP_FORGET: i32 = 10;
/// Binds the source of the waveform [Cmd::id] to its slot, from the poster.
pub const OP_BIND: i32 = 11;
/// Sets the position of the event relative to the listener, the azimuth in
/// degrees in [Cmd::value] and the distance in [Cmd::seek], as `SetSpatial`.
pub const OP_SET_SPATIAL: i32 = 12;

pub const NAME: usize = 160;

// ---------------------------------------------------------------- limits

// The render does not allocate or free. Its storage is built before it
// runs, the buses and pools of the mixer with the engine, and an event
// instance with its buses, effects, sound slots and the nested events that
// it can start by the thread that posts its start. A full pool refuses and
// reports a problem, and nothing is allocated to make room. What the render
// lets go goes to the collector of basedrop.

/// The frames of a pass, the mix block. A longer render call is split.
pub const BLOCK: usize = 1024;
/// The event instances that play at once, with their command ids.
pub const MAX_INSTANCES: usize = 256;
/// The mix state instances at once.
pub const MAX_SNAPSHOTS: usize = 64;
/// The sounds, voices, nested events and scatterers, that one event
/// instance plays at once.
pub const MAX_SOUNDS: usize = 64;
/// The instances of a nested event built per event instrument, one playing
/// and one triggered again while it plays out. A scatterer has its spawn
/// polyphony.
pub const NESTED_POOL: usize = 2;
/// The pool of nested events of a scatterer without a spawn polyphony limit.
pub const SPAWN_POOL: usize = 8;
/// The samples that a voice reads from its source at once. A longer read
/// goes in pieces with the same samples.
pub(crate) const CHUNK: usize = 1 << 16;

pub struct Cmd {
    pub op: i32,
    pub id: i32,
    /// The frame that it applies at, below 0 for when it arrives.
    pub at: i64,
    pub value: f64,
    pub seek: f64,
    /// The tolerance of a late START, or the cone angle of SET_SPATIAL.
    pub late: f64,
    pub has_late: bool,
    pub flag: bool,
    /// The tail that a one-shot keeps for SET_VOLUME and STOP, below 0 for
    /// none.
    pub keep_tail: f64,
    /// The string id of the parameter that a fading STOP sets to 1, −1 for
    /// none.
    pub via: i32,
    /// The index of the event or mix state, −1 for unknown, and the string id
    /// of a parameter name.
    pub event: i32,
    pub name_id: i32,
    /// The slot sound of START, or the source of BIND.
    pub src: Option<SrcRef>,
    /// The instance of START, built by the poster.
    pub inst: Option<Owned<Inst>>,
    /// The mix state instance of START_SNAPSHOT, built by the poster.
    pub snap: Option<Owned<Snap>>,
    pub gen: i64,
    /// The path of an unknown event or mix state, for problem texts.
    pub name: [u8; NAME],
}

impl Cmd {
    pub fn new(op: i32, id: i32, at: i64) -> Cmd {
        Cmd {
            op,
            id,
            at,
            value: 0.0,
            seek: 0.0,
            late: 0.0,
            has_late: false,
            flag: false,
            keep_tail: -1.0,
            via: -1,
            event: -1,
            name_id: -1,
            src: None,
            inst: None,
            snap: None,
            gen: 0,
            name: [0; NAME],
        }
    }
    pub fn set_name(&mut self, s: &str) {
        let b = s.as_bytes();
        let n = b.len().min(NAME - 1);
        self.name[..n].copy_from_slice(&b[..n]);
        self.name[n] = 0;
    }
    pub(crate) fn name_str(&self) -> &str {
        let n = self.name.iter().position(|&c| c == 0).unwrap_or(NAME);
        std::str::from_utf8(&self.name[..n]).unwrap_or("?")
    }
}

// ---------------------------------------------------------------- shared

pub const PROBLEM_LEN: usize = 256;

#[derive(Clone, Copy)]
pub struct Stat {
    pub wall_us: i64,
    pub frames: i64,
    pub render_us: i64,
    pub gap_us: i64,
}

/// The settings of an engine that hold for every command, as
/// prismarine_audio's `AudioRules`.
#[derive(Clone, Copy, Default)]
pub struct Rules {
    /// The frames by which the reported position of an instance trails its
    /// render.
    pub report_lag: i64,
    /// A late start at a position of this many seconds or less starts at 0.
    pub late_min: f64,
    /// The length of a sound for a late start is in whole ms.
    pub whole_ms: bool,
}

/// The state that every thread may touch, atomics, lock-free rings and the
/// lock of the posters.
pub struct Shared {
    pub m: &'static Model,
    pub rules: Rules,
    /// The engine plays in real time. Streamed waveforms stream, and failed
    /// decodes play silence.
    pub streaming: bool,
    /// A streamed sound in real time starts once its stream holds its start
    /// position. `PRISMARINE_STREAM_HOLD=off` reads silence until the feeder
    /// gets there instead, for comparisons.
    pub hold_streams: bool,
    /// Commands from any thread to the render thread.
    pub ring: ArrayQueue<Cmd>,
    /// The generation, written by the posters, one per instance start.
    pub gen: CachePadded<std::sync::atomic::AtomicI64>,
    /// The handle that sources are made with. Their last drop queues them for
    /// the collector of the engine.
    pub garbage: basedrop::Handle,
    /// Drops the queued sources on the service thread, on the lockstep caller
    /// after a render or at the teardown, and not on the render thread.
    pub collector: std::sync::Mutex<basedrop::Collector>,
    /// The stream taps for the service thread to open, as a source and a
    /// tap.
    pub requests: ArrayQueue<(SrcRef, usize)>,
    pub problems: ArrayQueue<[u8; PROBLEM_LEN]>,
    pub stats: ArrayQueue<Stat>,
    /// Written by the render thread each callback and read by the Dart side,
    /// each on a cache line of its own.
    pub position: CachePadded<std::sync::atomic::AtomicI64>,
    pub consumed: CachePadded<std::sync::atomic::AtomicI64>,
    /// Written by the Dart side and read by the render thread.
    pub paused: CachePadded<std::sync::atomic::AtomicBool>,
    pub muted: CachePadded<std::sync::atomic::AtomicBool>,
}
