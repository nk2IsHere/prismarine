//! The commands posters send, the render's limits, and what every thread
//! shares.

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
/// A waveform's source for its slot ([Cmd::id] the waveform), bound by the
/// poster.
pub const OP_BIND: i32 = 11;
/// The event's position relative to the listener: [Cmd::value] azimuth
/// (degrees), [Cmd::seek] distance (mcsm_audio `SetSpatial`).
pub const OP_SET_SPATIAL: i32 = 12;

pub const NAME: usize = 160;

// ---------------------------------------------------------------- limits

// The render never allocates or frees: what it uses is built
// before it runs, FMOD-style — the mixer's buses and pools with the
// engine, an event instance (its buses, effects, sound slots and the nested
// events it can start) by the thread that posts its start. A full pool
// refuses and reports a problem; nothing is allocated to make room. What
// the render lets go goes to the collector (basedrop).

/// Frames per pass: FMOD 1.06 mixes in blocks of 1024 samples (its default
/// DSP buffer); a longer render call is split.
pub const BLOCK: usize = 1024;
/// Event instances playing at once (with their command ids).
pub const MAX_INSTANCES: usize = 256;
/// Snapshot instances at once.
pub const MAX_SNAPSHOTS: usize = 64;
/// Sounds (voices, nested events, scatterers) one event instance plays at
/// once.
pub const MAX_SOUNDS: usize = 64;
/// Instances of a nested event built per event instrument: one playing and
/// one retriggered while it plays out; a scatterer's, its spawn polyphony.
pub const NESTED_POOL: usize = 2;
/// A scatterer without a spawn polyphony limit: its nested events' pool.
pub const SPAWN_POOL: usize = 8;
/// Samples a voice reads from its source at once (a longer read goes in
/// pieces; the samples are the same).
pub(crate) const CHUNK: usize = 1 << 16;

pub struct Cmd {
    pub op: i32,
    pub id: i32,
    /// The frame it applies at; < 0: when it arrives.
    pub at: i64,
    pub value: f64,
    pub seek: f64,
    /// START: the late start's tolerance; SET_SPATIAL: the cone angle.
    pub late: f64,
    pub has_late: bool,
    pub flag: bool,
    /// SET_VOLUME, STOP: the tail a one-shot keeps (< 0: none).
    pub keep_tail: f64,
    /// STOP: the parameter a fading stop sets to 1 (its string id, −1:
    /// none).
    pub via: i32,
    /// Event or snapshot table index (−1 unknown); a parameter name's
    /// string id.
    pub event: i32,
    pub name_id: i32,
    /// START: the voice line; BIND: the source.
    pub src: Option<SrcRef>,
    /// START: the instance, built by the poster.
    pub inst: Option<Owned<Inst>>,
    /// START_SNAPSHOT: the snapshot instance, built by the poster.
    pub snap: Option<Owned<Snap>>,
    pub gen: i64,
    /// For problem texts (an unknown event's or snapshot's path).
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

/// Settings of an engine that hold for every command (prismarine_audio
/// `AudioRules`).
#[derive(Clone, Copy, Default)]
pub struct Rules {
    /// Frames by which an instance's reported position trails its render.
    pub report_lag: i64,
    /// A late start's position at or under this many seconds starts at 0.
    pub late_min: f64,
    /// A sound's length for a late start in whole ms.
    pub whole_ms: bool,
}

/// What every thread may touch (atomics, lock-free rings, the posters'
/// lock).
pub struct Shared {
    pub m: &'static Model,
    pub rules: Rules,
    /// Real time: streamed waveforms stream; failed decodes play silence.
    pub streaming: bool,
    /// Real time: a streamed sound starts once its stream holds its start
    /// position (`stream_ready_at`); `MCSM_STREAM_HOLD=off` reads silence
    /// until the feeder gets there instead (for A/B checks).
    pub hold_streams: bool,
    /// Commands from any thread to the render thread.
    pub ring: ArrayQueue<Cmd>,
    /// Written by the posters (one per instance start).
    pub gen: CachePadded<std::sync::atomic::AtomicI64>,
    /// Sources are made with this handle: their last drop queues them for
    /// the engine's collector (source.rs).
    pub garbage: basedrop::Handle,
    /// Drops the queued sources (the service thread, the lockstep caller
    /// after a render, the teardown; never the render thread).
    pub collector: std::sync::Mutex<basedrop::Collector>,
    /// Stream taps for the service thread to open: (source, tap).
    pub requests: ArrayQueue<(SrcRef, usize)>,
    pub problems: ArrayQueue<[u8; PROBLEM_LEN]>,
    pub stats: ArrayQueue<Stat>,
    /// Written by the render thread each callback, read by the Dart side:
    /// a line of their own, apart from what the other threads write.
    pub position: CachePadded<std::sync::atomic::AtomicI64>,
    pub consumed: CachePadded<std::sync::atomic::AtomicI64>,
    /// Written by the Dart side, read by the render thread.
    pub paused: CachePadded<std::sync::atomic::AtomicBool>,
    pub muted: CachePadded<std::sync::atomic::AtomicBool>,
}
