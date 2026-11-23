//! The native render of prismarine_audio's engine, with its event
//! instances, voices, strips, DSPs, mixer graph and mix states. It runs on a
//! thread outside the Dart heap, driven by commands that any isolate posts,
//! and it renders the same bits as the Dart render. Each module mirrors a
//! file of the Dart engine function for function and in the same float
//! order.
//!
//! Posters on Dart isolates bind sources and push commands. The render
//! thread, the callback of the device or the caller in lockstep, drains the
//! commands and renders. The service thread opens stream taps and frees what
//! the render thread let go.
//!
//! The render allocates and frees nothing. Its storage is built before it
//! runs, within the limits of engine/cmd.rs, and what it lets go goes to the
//! collector. In debug builds the global allocator is the checking wrapper
//! of `assert_no_alloc`, and an allocation or free inside a render aborts.
//!
//! `unsafe` is only at the FFI edge, in the `extern "C"` functions here.

pub mod chorus;
pub mod dmath;
pub mod dsp;
pub mod engine;
pub mod model;
pub mod source;
pub mod spatial;
pub mod surround;

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crossbeam_queue::ArrayQueue;
use crossbeam_utils::CachePadded;

use crate::decode::cache::{Held, READY};
use crate::decode::stream::Stream;
use crate::device;
use engine::{Cmd, Core, Shared, Stat};
use source::{Kind, Src, SrcRef};

/// The system allocator, checked in debug builds. A render that allocates
/// or frees aborts.
#[cfg(debug_assertions)]
#[global_allocator]
static CHECK: assert_no_alloc::AllocDisabler = assert_no_alloc::AllocDisabler;

/// The render state. The callback of the device owns it in real time, and
/// the lock of the engine guards it in lockstep.
struct Renderer {
    core: Core,
    sh: Arc<Shared>,
    broken: bool,
    start: Instant,
    last_cb: i64,
    /// A copy of the mix of each callback for the writer of
    /// `PRISMARINE_AUDIO_TAP`.
    tap: Option<rtrb::Producer<f32>>,
}

impl Renderer {
    /// Renders one block without allocating or freeing.
    fn render_block(&mut self, out: &mut [f32]) {
        if self.broken {
            out.fill(0.0);
            return;
        }
        let (core, sh) = (&mut self.core, &*self.sh);
        let r = catch_unwind(AssertUnwindSafe(|| {
            #[cfg(debug_assertions)]
            assert_no_alloc::assert_no_alloc(|| core.render(sh, out));
            #[cfg(not(debug_assertions))]
            core.render(sh, out);
        }));
        if r.is_err() {
            self.broken = true;
            out.fill(0.0);
            let mut b = [0u8; engine::PROBLEM_LEN];
            let msg = b"audio render panicked: the native mixer is silent from here";
            b[..msg.len()].copy_from_slice(msg);
            let _ = self.sh.problems.push(b);
        }
    }
}

impl device::Render for Renderer {
    /// Renders the block of a callback of the device.
    fn render(&mut self, out: &mut [f32]) {
        let t0 = Instant::now();
        let wall = t0.duration_since(self.start).as_micros() as i64;
        let frames = (out.len() / 2) as i64;
        if self.sh.paused.load(Ordering::Relaxed) {
            out.fill(0.0);
            return;
        }
        self.render_block(out);
        if let Some(tap) = &mut self.tap {
            // The rendered mix, also when muted. A full ring drops the rest
            // when the writer fell behind.
            for &v in out.iter() {
                if tap.push(v).is_err() {
                    break;
                }
            }
        }
        let sh = &self.sh;
        if sh.muted.load(Ordering::Relaxed) {
            out.fill(0.0);
        }
        sh.consumed.fetch_add(frames, Ordering::AcqRel);
        let last = std::mem::replace(&mut self.last_cb, wall);
        let _ = sh.stats.push(Stat {
            wall_us: wall,
            frames,
            render_us: t0.elapsed().as_micros() as i64,
            gap_us: if last == 0 { 0 } else { wall - last },
        });
    }
}

/// The state of the posters under one lock, the source that each waveform
/// is bound to and the problems found while posting.
struct Posters {
    bound: Vec<Option<SrcRef>>,
    problems: Vec<String>,
}

pub struct Engine {
    sh: Arc<Shared>,
    /// The renderer while no device runs, in lockstep.
    lockstep: Mutex<Option<Box<Renderer>>>,
    device: Mutex<Option<device::Device>>,
    service: Mutex<Option<std::thread::JoinHandle<()>>>,
    run: Arc<AtomicBool>,
    posters: Mutex<Posters>,
    problems_lock: Mutex<()>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn exists(path: &str) -> bool {
    Path::new(path).exists()
}

/// Makes a source for waveform [w] of generation [gen], on a poster.
fn make_src(sh: &Shared, w: usize, gen: i64) -> SrcRef {
    let m = sh.m;
    let wv = &m.waves[w];
    let path = m.str(wv.path);
    let failed = |frames, channels, rate| {
        SrcRef::new(
            Src::new(Kind::Failed, path, gen, frames, channels, rate),
            &sh.garbage,
        )
    };
    if !wv.has_file || !exists(path) {
        return failed(0, 1, 48000);
    }
    if sh.streaming && wv.streamed && wv.ogg {
        let s = Src::new(Kind::Stream, path, gen, wv.frames, wv.channels, wv.rate);
        let _ = s.taps[0].set(Stream::open(path, 0.5));
        return SrcRef::new(s, &sh.garbage);
    }
    let held = Held::acquire(path);
    if sh.streaming {
        // In real time it plays once decoded, in the format of the model
        // until then.
        return SrcRef::new(
            Src::new(Kind::Pcm, path, gen, wv.frames, wv.channels, wv.rate).with_pcm(held),
            &sh.garbage,
        );
    }
    // In lockstep it is decoded now, in its own format from the start, as
    // the Dart render decodes whole files at load.
    if held.wait() != READY {
        return failed(wv.frames, wv.channels, wv.rate);
    }
    let s = Src::new(Kind::Pcm, path, gen, wv.frames, wv.channels, wv.rate).with_pcm(held);
    s.take();
    SrcRef::new(s, &sh.garbage)
}

/// Binds waveform [w] for generation [gen] to a new source, unless it is
/// bound to a stream or to this generation already. The render thread takes
/// the binding from the ring in posting order, under the lock of the
/// posters.
fn bind(sh: &Shared, p: &mut Posters, w: usize, gen: i64) {
    if let Some(cur) = &p.bound[w] {
        if cur.kind == Kind::Stream || cur.gen >= gen {
            return;
        }
    }
    let s = make_src(sh, w, gen);
    let mut c = Cmd::new(engine::OP_BIND, w as i32, -1);
    c.src = Some(s.clone());
    // A full ring keeps the binding of the render, and the next start tries
    // again.
    if sh.ring.push(c).is_ok() {
        p.bound[w] = Some(s);
    }
}

/// Acquires a slot sound and waits for it, which keeps a slot sound from
/// starting half loaded. None when it does not load.
fn voice(sh: &Shared, path: &str) -> Option<SrcRef> {
    if !exists(path) {
        return None;
    }
    let held = Held::acquire(path);
    if held.wait() != READY {
        return None;
    }
    let s = Src::new(Kind::Pcm, path, 0, 0, 1, 48000).with_pcm(held);
    s.take();
    Some(SrcRef::new(s, &sh.garbage))
}

/// Writes every sample that the device gets into the file of
/// `PRISMARINE_AUDIO_TAP`, as raw float32 stereo at 48 kHz from the start of
/// the device, for listening to a real-time run and measuring it. Frame f is
/// the audio position f / 48000 s.
fn tap_writer(path: &str, run: Arc<AtomicBool>) -> Option<rtrb::Producer<f32>> {
    use std::io::Write;
    let mut file = std::io::BufWriter::new(std::fs::File::create(path).ok()?);
    let (tx, mut rx) = rtrb::RingBuffer::<f32>::new(48000 * 2 * 4);
    std::thread::Builder::new()
        .name("prismarine-audio-tap".into())
        .spawn(move || {
            let mut buf = Vec::with_capacity(48000 * 2);
            loop {
                let live = run.load(Ordering::Acquire);
                let n = rx.slots();
                if let Ok(chunk) = rx.read_chunk(n) {
                    buf.clear();
                    buf.extend(chunk.into_iter().flat_map(f32::to_le_bytes));
                    let _ = file.write_all(&buf);
                }
                if !live && rx.is_empty() {
                    let _ = file.flush();
                    return;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        })
        .ok()?;
    Some(tx)
}

/// Frees what the render let go, on any thread but the render thread.
fn collect(sh: &Shared) {
    source::collect(&mut lock(&sh.collector));
}

/// Runs the service thread, which opens stream taps and frees garbage.
fn service(sh: Arc<Shared>, run: Arc<AtomicBool>) {
    while run.load(Ordering::Acquire) {
        while let Some((s, tap)) = sh.requests.pop() {
            let st = Stream::open(&s.path, 0.5);
            let cue = s.view.tcue[tap].load(Ordering::Relaxed);
            if cue > 0 {
                st.prefetch(cue);
            }
            let _ = s.taps[tap].set(st);
        }
        collect(&sh);
        std::thread::sleep(Duration::from_millis(2));
    }
}

impl Engine {
    fn new(
        m: &'static model::Model,
        seed: i64,
        streaming: bool,
        rules: engine::Rules,
    ) -> Option<Engine> {
        let collector = basedrop::Collector::new();
        let sh = Arc::new(Shared {
            m,
            rules,
            streaming,
            hold_streams: streaming && crate::mix::env("STREAM_HOLD").is_none_or(|v| v != "off"),
            ring: ArrayQueue::new(4096),
            gen: CachePadded::new(AtomicI64::new(0)),
            garbage: collector.handle(),
            collector: Mutex::new(collector),
            requests: ArrayQueue::new(256),
            problems: ArrayQueue::new(256),
            stats: ArrayQueue::new(8192),
            position: CachePadded::new(AtomicI64::new(0)),
            consumed: CachePadded::new(AtomicI64::new(0)),
            paused: CachePadded::new(AtomicBool::new(false)),
            muted: CachePadded::new(AtomicBool::new(false)),
        });
        let core = Core::new(&sh, seed);
        let r = Renderer {
            core,
            sh: sh.clone(),
            broken: false,
            start: Instant::now(),
            last_cb: 0,
            tap: None,
        };
        Some(Engine {
            sh,
            lockstep: Mutex::new(Some(Box::new(r))),
            device: Mutex::new(None),
            service: Mutex::new(None),
            run: Arc::new(AtomicBool::new(false)),
            posters: Mutex::new(Posters {
                bound: (0..m.waves.len()).map(|_| None).collect(),
                problems: Vec::new(),
            }),
            problems_lock: Mutex::new(()),
        })
    }

    /// Stops everything and frees what the engine holds. Nothing refers to
    /// the model once this returns true.
    fn shut_down(self) -> bool {
        *lock(&self.device) = None;
        self.run.store(false, Ordering::Release);
        if let Some(h) = lock(&self.service).take() {
            let _ = h.join();
        }
        drop(lock(&self.lockstep).take());
        while let Some(c) = self.sh.ring.pop() {
            drop(c);
        }
        while let Some(r) = self.sh.requests.pop() {
            drop(r);
        }
        lock(&self.posters).bound.clear();
        collect(&self.sh);
        let Engine { sh, .. } = self;
        let Some(Shared {
            garbage, collector, ..
        }) = Arc::into_inner(sh)
        else {
            return false;
        };
        drop(garbage);
        // Frees the collector once nothing is left with it, else it leaks a
        // few bytes.
        let _ = collector
            .into_inner()
            .unwrap_or_else(|e| e.into_inner())
            .try_cleanup();
        true
    }

    fn post(&self, mut c: Cmd, name: &str, voice_path: Option<&str>, via: Option<&str>) -> i32 {
        let sh = &*self.sh;
        let m = sh.m;
        match c.op {
            engine::OP_START => {
                c.set_name(name);
                let sid = m.id(name);
                c.event = if sid >= 0 {
                    m.event_by_string[sid as usize]
                } else {
                    -1
                };
                if c.event >= 0 {
                    // The poster builds the instance, and the render only
                    // starts it.
                    let b = engine::Build {
                        m,
                        garbage: &sh.garbage,
                    };
                    let def: &'static model::Event = &m.events[c.event as usize];
                    c.inst = Some(basedrop::Owned::new(
                        &sh.garbage,
                        engine::Inst::build(&b, def, engine::BLOCK, 0.0),
                    ));
                    let mut p = lock(&self.posters);
                    let gen = sh.gen.load(Ordering::Acquire);
                    for &w in &m.events[c.event as usize].waves {
                        bind(sh, &mut p, w as usize, gen);
                    }
                }
                if let Some(v) = voice_path {
                    c.src = voice(sh, v);
                    if c.src.is_none() {
                        let file = v.rsplit('/').next().unwrap_or(v);
                        lock(&self.posters)
                            .problems
                            .push(format!("no voice {file}"));
                    }
                }
            }
            engine::OP_SET_PARAM | engine::OP_SET_SNAP_PARAM => c.name_id = m.id(name),
            engine::OP_STOP => c.via = via.map_or(-1, |v| m.id(v)),
            engine::OP_START_SNAPSHOT => {
                c.set_name(name);
                let sid = m.id(name);
                c.event = if sid >= 0 {
                    m.snap_by_string[sid as usize]
                } else {
                    -1
                };
                if c.event >= 0 {
                    let def: &'static model::Event = &m.snaps[c.event as usize];
                    c.snap = Some(basedrop::Owned::new(&sh.garbage, engine::Snap::build(def)));
                }
            }
            _ => {}
        }
        if sh.ring.push(c).is_ok() {
            0
        } else {
            -1
        }
    }

    fn scene(&self) {
        let sh = &*self.sh;
        let mut p = lock(&self.posters);
        let gen = sh.gen.fetch_add(1, Ordering::AcqRel) + 1;
        for b in p.bound.iter_mut() {
            if b.as_ref()
                .is_some_and(|s| s.kind != Kind::Stream && s.gen < gen)
            {
                *b = None;
            }
        }
        let mut c = Cmd::new(engine::OP_FORGET, 0, -1);
        c.gen = gen;
        let _ = sh.ring.push(c);
    }

    fn render_lockstep(&self, out: &mut [f32]) {
        match lock(&self.lockstep).as_mut() {
            Some(r) => r.render_block(out),
            None => out.fill(0.0),
        }
        collect(&self.sh);
    }

    fn set_position(&self, frames: i64) -> i32 {
        match lock(&self.lockstep).as_mut() {
            Some(r) => {
                r.core.position = frames;
                self.sh.position.store(frames, Ordering::Release);
                0
            }
            None => -1,
        }
    }

    fn problem(&self) -> Option<Vec<u8>> {
        let _l = lock(&self.problems_lock);
        if let Some(p) = lock(&self.posters).problems.pop() {
            return Some(p.into_bytes());
        }
        let b = self.sh.problems.pop()?;
        let n = b.iter().position(|&c| c == 0).unwrap_or(b.len());
        Some(b[..n].to_vec())
    }

    fn start(&self) -> i32 {
        let Some(mut r) = lock(&self.lockstep).take() else {
            return -4;
        };
        self.run.store(true, Ordering::Release);
        if let Some(path) = crate::mix::env("AUDIO_TAP") {
            r.tap = tap_writer(&path, self.run.clone());
        }
        let (sh, run) = (self.sh.clone(), self.run.clone());
        match std::thread::Builder::new()
            .name("prismarine-mix-service".into())
            .spawn(move || service(sh, run))
        {
            Ok(h) => *lock(&self.service) = Some(h),
            Err(_) => {
                *lock(&self.lockstep) = Some(r);
                return -3;
            }
        }
        match device::Device::start(r, 1024) {
            Ok(d) => {
                *lock(&self.device) = Some(d);
                0
            }
            Err(e) => {
                lock(&self.posters)
                    .problems
                    .push(format!("audio device: {}", e.message));
                e.code
            }
        }
    }

    fn missing(&self) -> i64 {
        let mut p = lock(&self.posters);
        let mut m = 0;
        let mut notes = Vec::new();
        for s in p.bound.iter().flatten() {
            if s.kind != Kind::Stream {
                continue;
            }
            for (k, t) in s.taps.iter().enumerate() {
                let Some((n, at, base, filled, seek, head, rate)) =
                    t.get().and_then(|t| t.take_missing_info())
                else {
                    continue;
                };
                m += n;
                // The stream and tap, the frame that it wanted and the
                // position of the ring of the feeder, the cause of an
                // underrun.
                let r = f64::from(rate.max(1));
                let file = s.path.rsplit('/').next().unwrap_or(&s.path);
                notes.push(format!(
                    "audio stream {file} tap {k}: {n} frames silent from {:.3} s (ring {:.3}–{:.3} s{}, head {:.3} s)",
                    at as f64 / r,
                    base as f64 / r,
                    (base + filled) as f64 / r,
                    if seek { ", seeking" } else { "" },
                    head as f64 / r,
                ));
            }
        }
        p.problems.extend(notes);
        m
    }
}

// ---------------------------------------------------------------- the C ABI

/// # Safety
/// [p] is null or a NUL-terminated string.
unsafe fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        // SAFETY: the caller's contract.
        unsafe { CStr::from_ptr(p) }.to_str().ok()
    }
}

/// # Safety
/// [e] is an engine from prismarine_mix_create, not destroyed.
unsafe fn engine<'a>(e: *const Engine) -> &'a Engine {
    // SAFETY: the caller's contract.
    unsafe { &*e }
}

/// Creates an engine from a model blob. With [streaming] it plays in real
/// time, streamed waveforms stream and decodes are not waited for.
/// [report_lag], [late_min] and [whole_ms] are the rules of the engine.
/// Returns null for a bad blob.
///
/// # Safety
/// [blob] holds [len] bytes.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_create(
    blob: *const u8,
    len: i64,
    seed: i64,
    streaming: i32,
    report_lag: i64,
    late_min: f64,
    whole_ms: i32,
) -> *mut Engine {
    // SAFETY: the caller's contract.
    let bytes = unsafe { std::slice::from_raw_parts(blob, len as usize) };
    let Some(m) = model::read(bytes) else {
        return std::ptr::null_mut();
    };
    // The model lasts as long as the engine. prismarine_mix_destroy frees it
    // once nothing refers to it.
    let m: &'static model::Model = Box::leak(m);
    let rules = engine::Rules {
        report_lag,
        late_min,
        whole_ms: whole_ms != 0,
    };
    match Engine::new(m, seed, streaming != 0, rules) {
        Some(e) => Box::into_raw(Box::new(e)),
        None => {
            // SAFETY: leaked just above; nothing else refers to it.
            drop(unsafe { Box::from_raw(m as *const model::Model as *mut model::Model) });
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// [e] is null or an engine from prismarine_mix_create, destroyed once, with no
/// call into it running or following.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_destroy(e: *mut Engine) {
    if e.is_null() {
        return;
    }
    // SAFETY: the caller's contract: boxed by prismarine_mix_create.
    let e = unsafe { Box::from_raw(e) };
    let m = e.sh.m as *const model::Model;
    if e.shut_down() {
        // SAFETY: the model was leaked by prismarine_mix_create for this engine,
        // and everything that referred to it (the shared state, the render
        // core, the service thread) is gone.
        drop(unsafe { Box::from_raw(m as *mut model::Model) });
    }
}

/// Posts a command from any thread. For START [name] is the event path and
/// [sound] the sound file or null. For SET_PARAM and SET_SNAP_PARAM [name] is
/// the lower-cased parameter name, and for START_SNAPSHOT the path. For
/// SET_VOLUME and STOP [keep_tail] is the tail that a one-shot keeps, below
/// 0 for none. For STOP [flag] stops at once and [via] is the lower-cased
/// parameter that a fading stop sets, or null. Returns 0, or −1 when the
/// ring is full.
///
/// # Safety
/// [e] is a live engine; [name], [sound] and [via] are null or
/// NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_post(
    e: *const Engine,
    op: i32,
    id: i32,
    at: i64,
    value: f64,
    seek: f64,
    has_late: i32,
    late: f64,
    flag: i32,
    keep_tail: f64,
    name: *const c_char,
    sound: *const c_char,
    via: *const c_char,
) -> i32 {
    let mut c = Cmd::new(op, id, at);
    c.value = value;
    c.seek = seek;
    c.has_late = has_late != 0;
    c.late = late;
    c.flag = flag != 0;
    c.keep_tail = keep_tail;
    // SAFETY: the caller's contract.
    let (e, name, sound, via) =
        unsafe { (engine(e), cstr(name).unwrap_or(""), cstr(sound), cstr(via)) };
    e.post(c, name, sound, via)
}

/// Starts a new generation of bindings. The older bindings are let go, and
/// playing voices keep theirs.
///
/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_scene(e: *const Engine) {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }.scene();
}

/// Renders [frames] stereo frames into [out] on the caller's thread in
/// lockstep, then frees what the render let go. Writes silence while a
/// device renders.
///
/// # Safety
/// [e] is a live engine; [out] has room for 2 × [frames] floats.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_render(e: *const Engine, out: *mut f32, frames: i64) {
    // SAFETY: the caller's contract.
    let (e, buf) = unsafe {
        (
            engine(e),
            std::slice::from_raw_parts_mut(out, (frames * 2) as usize),
        )
    };
    e.render_lockstep(buf);
}

/// Moves the render head to [frames] without rendering, in lockstep only.
/// Commands at or before it apply at the next frame, as with the setter of
/// AudioEngine.position. Returns −1 while a device renders.
///
/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_set_position(e: *const Engine, frames: i64) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }.set_position(frames)
}

/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_position(e: *const Engine) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }.sh.position.load(Ordering::Acquire)
}

/// Writes the next problem text into [out] with a NUL at its end. Returns
/// its length, or 0 when there is none.
///
/// # Safety
/// [e] is a live engine; [out] has room for [cap] ≥ 1 bytes.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_problem(e: *const Engine, out: *mut u8, cap: i32) -> i32 {
    // SAFETY: the caller's contract.
    let Some(p) = unsafe { engine(e) }.problem() else {
        return 0;
    };
    let n = p.len().min(cap.max(1) as usize - 1);
    // SAFETY: the caller's contract: n + 1 ≤ cap bytes.
    unsafe {
        std::ptr::copy_nonoverlapping(p.as_ptr(), out, n);
        *out.add(n) = 0;
    }
    n as i32
}

/// Starts the service thread and the output device for real time. Returns
/// 0, or −1 without an output device, −3 without a service thread, −4 when
/// started already, −5 when the stream does not open and −6 when it does
/// not play. The engine is silent after an error, and its problems give the
/// cause.
///
/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_start(e: *const Engine) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }.start()
}

/// Audio frames handed to the device so far.
///
/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_consumed(e: *const Engine) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }.sh.consumed.load(Ordering::Acquire)
}

/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_set_paused(e: *const Engine, paused: i32) {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }
        .sh
        .paused
        .store(paused != 0, Ordering::Release);
}

/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_set_muted(e: *const Engine, muted: i32) {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }
        .sh
        .muted
        .store(muted != 0, Ordering::Release);
}

/// Writes up to [max] callback records into [out], each the wall time in
/// µs, the frames, the render time in µs and the gap in µs. Returns the
/// count.
///
/// # Safety
/// [e] is a live engine; [out] has room for 4 × [max] int64s.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_stats(e: *const Engine, out: *mut i64, max: i32) -> i32 {
    // SAFETY: the caller's contract.
    let sh = &unsafe { engine(e) }.sh;
    let mut n = 0;
    while n < max {
        let Some(s) = sh.stats.pop() else { break };
        // SAFETY: the caller's contract: record n of max fits.
        unsafe {
            let o = out.add(n as usize * 4);
            *o = s.wall_us;
            *o.add(1) = s.frames;
            *o.add(2) = s.render_us;
            *o.add(3) = s.gap_us;
        }
        n += 1;
    }
    n
}

/// Frames streams read as silence since the last call.
///
/// # Safety
/// [e] is a live engine.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mix_missing(e: *const Engine) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { engine(e) }.missing()
}

/// The value of the environment variable `PRISMARINE_<name>`, else of
/// `MCSM_<name>`.
pub(crate) fn env(name: &str) -> Option<String> {
    std::env::var(format!("PRISMARINE_{name}"))
        .or_else(|_| std::env::var(format!("MCSM_{name}")))
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The command ring with many posters and one render thread. The source
    /// of a slot sound goes with its command and to the collector after it.
    #[test]
    fn commands_from_many_threads_reach_the_render_in_order() {
        let ring: Arc<ArrayQueue<Cmd>> = Arc::new(ArrayQueue::new(64));
        let mut collector = basedrop::Collector::new();
        let posters: Vec<_> = (0..4)
            .map(|t| {
                let (ring, garbage) = (ring.clone(), collector.handle());
                std::thread::spawn(move || {
                    for i in 0..8 {
                        let mut c = Cmd::new(engine::OP_START, t, i);
                        c.src = Some(SrcRef::new(
                            Src::new(Kind::Failed, "v", 0, 0, 1, 48000),
                            &garbage,
                        ));
                        assert!(ring.push(c).is_ok());
                    }
                })
            })
            .collect();
        for p in posters {
            p.join().unwrap();
        }
        let mut last = [-1i64; 4];
        let mut n = 0;
        while let Some(c) = ring.pop() {
            assert!(c.at > last[c.id as usize]);
            last[c.id as usize] = c.at;
            n += 1;
        }
        assert_eq!(n, 32);
        // A full ring refuses, and the sources of refused commands are let
        // go.
        for i in 0..64 {
            assert!(ring.push(Cmd::new(engine::OP_STOP, 0, i)).is_ok());
        }
        assert!(ring.push(Cmd::new(engine::OP_STOP, 0, 64)).is_err());
        assert_eq!(collector.alloc_count(), 32);
        source::collect(&mut collector);
        assert_eq!(collector.alloc_count(), 0);
        assert!(collector.try_cleanup().is_ok());
    }
}
