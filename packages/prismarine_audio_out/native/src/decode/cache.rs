//! The decoded-audio cache: whole-file decodes (in-memory bank waveforms,
//! voice lines) to interleaved float32, keyed by path, process-wide. Any
//! isolate may ask for a file ahead of need ([want]: the sim's preloader) or
//! take it to play ([Held::acquire]: the render isolate, the mixer); the
//! samples live outside the Dart heap, so neither the decode nor the data
//! touch the heap the isolates share. Decodes run on low-priority threads.
//! Entries nobody holds are dropped two scene changes after they were last
//! wanted, or oldest first while the cache is over its budget.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Condvar, LazyLock, Mutex, MutexGuard, OnceLock};
use std::time::Instant;

use super::codec::{self, Pcm};

pub const QUEUED: i32 = 0;
pub const READY: i32 = 1;
pub const DECODING: i32 = 2;
pub const FAILED: i32 = -1;

// Under Miri decodes run on the waiting thread (no threads left running).
const WORKERS: usize = if cfg!(miri) { 0 } else { 2 };

/// One file's decode. Its state and data are read without the cache's lock
/// (the render thread): the data is set once, before the state turns READY.
pub struct Entry {
    path: String,
    state: AtomicI32,
    pcm: OnceLock<Pcm>,
}

impl Entry {
    pub fn path(&self) -> &str {
        &self.path
    }
    /// QUEUED, DECODING, READY or FAILED.
    pub fn state(&self) -> i32 {
        self.state.load(Ordering::Acquire)
    }
    /// The decoded audio once READY.
    pub fn pcm(&self) -> Option<&Pcm> {
        if self.state() == READY {
            self.pcm.get()
        } else {
            None
        }
    }
}

/// What the cache keeps per entry (under its lock).
struct Meta {
    entry: Arc<Entry>,
    /// Holders ([Held]); never dropped while > 0.
    refs: i32,
    /// The newest scene generation that wanted or took it.
    gen: i64,
    /// LRU stamp.
    used: i64,
}

#[derive(Default)]
struct Stats {
    bytes: i64,
    entries: i64,
    decoded: i64,
    decode_us: i64,
    evicted: i64,
    hits: i64,
    misses: i64,
    waits: i64,
    wait_us: i64,
    wanted: i64,
    failed: i64,
}

struct Inner {
    map: HashMap<String, Meta>,
    /// Entries waiting for a worker (state QUEUED), next first.
    queue: VecDeque<Arc<Entry>>,
    workers: usize,
    gen: i64,
    clock: i64,
    budget: i64,
    s: Stats,
}

struct Cache {
    inner: Mutex<Inner>,
    /// The queue is not empty.
    work: Condvar,
    /// A decode finished.
    done: Condvar,
}

static CACHE: LazyLock<Cache> = LazyLock::new(|| Cache {
    inner: Mutex::new(Inner {
        map: HashMap::new(),
        queue: VecDeque::new(),
        workers: 0,
        gen: 0,
        clock: 0,
        budget: 512 << 20,
        s: Stats::default(),
    }),
    work: Condvar::new(),
    done: Condvar::new(),
});

fn lock() -> MutexGuard<'static, Inner> {
    // A panic under the lock leaves the counters as they were: keep going.
    CACHE.inner.lock().unwrap_or_else(|e| e.into_inner())
}

fn now_us(t0: Instant) -> i64 {
    t0.elapsed().as_micros() as i64
}

fn bytes_of(e: &Entry) -> i64 {
    e.pcm().map_or(0, Pcm::bytes)
}

impl Inner {
    fn unqueue(&mut self, e: &Arc<Entry>) {
        if let Some(i) = self.queue.iter().position(|q| Arc::ptr_eq(q, e)) {
            self.queue.remove(i);
        }
    }

    /// Unlinks [path]'s entry (nobody holds it, not decoding).
    fn drop_entry(&mut self, path: &str) {
        if let Some(m) = self.map.remove(path) {
            self.unqueue(&m.entry);
            self.s.bytes -= bytes_of(&m.entry);
            self.s.entries -= 1;
            self.s.evicted += 1;
        }
    }

    /// While over budget, drops the least recently used entry nobody holds.
    fn trim_budget(&mut self) {
        while self.s.bytes > self.budget {
            let victim = self
                .map
                .iter()
                .filter(|(_, m)| droppable(m) && m.entry.state() == READY)
                .min_by_key(|(_, m)| m.used)
                .map(|(k, _)| k.clone());
            match victim {
                Some(k) => self.drop_entry(&k),
                None => return,
            }
        }
    }

    /// [path]'s entry, made (and queued) when new; [front]: ahead of earlier
    /// asks.
    fn get(&mut self, path: &str, front: bool) -> &mut Meta {
        if !self.map.contains_key(path) {
            let entry = Arc::new(Entry {
                path: path.to_string(),
                state: AtomicI32::new(QUEUED),
                pcm: OnceLock::new(),
            });
            if front {
                self.queue.push_front(entry.clone());
            } else {
                self.queue.push_back(entry.clone());
            }
            self.map.insert(
                path.to_string(),
                Meta {
                    entry,
                    refs: 0,
                    gen: 0,
                    used: 0,
                },
            );
            self.s.entries += 1;
            while self.workers < WORKERS {
                if std::thread::Builder::new()
                    .name("prismarine-pcm-decode".into())
                    .spawn(worker)
                    .is_err()
                {
                    break;
                }
                self.workers += 1;
            }
            CACHE.work.notify_one();
        } else if front {
            let e = self.map[path].entry.clone();
            if e.state() == QUEUED && !self.queue.front().is_some_and(|q| Arc::ptr_eq(q, &e)) {
                self.unqueue(&e);
                self.queue.push_front(e);
            }
        }
        let (gen, clock) = (self.gen, self.clock + 1);
        self.clock = clock;
        let m = self.map.get_mut(path).expect("just made");
        m.gen = gen;
        m.used = clock;
        m
    }
}

fn droppable(m: &Meta) -> bool {
    m.refs == 0 && m.entry.state() != DECODING
}

/// Decodes [e] (its state is DECODING) and publishes the result.
fn decode(e: &Entry) {
    let t0 = Instant::now();
    let pcm = decode_path(&e.path);
    let mut c = lock();
    match pcm {
        Some(p) => {
            let _ = e.pcm.set(p);
            e.state.store(READY, Ordering::Release);
            c.s.bytes += bytes_of(e);
        }
        None => {
            e.state.store(FAILED, Ordering::Release);
            c.s.failed += 1;
        }
    }
    c.s.decoded += 1;
    c.s.decode_us += now_us(t0);
    c.trim_budget();
    CACHE.done.notify_all();
}

/// A dev tool's or test's decoder in place of the files' (set_loader).
type Loader = fn(&str) -> Option<Pcm>;
static LOADER: Mutex<Option<Loader>> = Mutex::new(None);

/// Decodes through [f] instead of the vendored decoders from now on (dev
/// tools that replay another engine's PCM, tests).
pub fn set_loader(f: Loader) {
    *LOADER.lock().unwrap_or_else(|e| e.into_inner()) = Some(f);
}

fn decode_path(path: &str) -> Option<Pcm> {
    let loader = *LOADER.lock().unwrap_or_else(|e| e.into_inner());
    match loader {
        Some(f) => f(path),
        None => codec::decode_file(path),
    }
}

fn worker() {
    // Below the UI, raster and audio threads: preloading never competes
    // with a frame.
    super::os::take_role(super::os::Role::Background);
    loop {
        let e = {
            let mut c = lock();
            loop {
                if let Some(e) = c.queue.pop_front() {
                    // Under the lock: a waiter sees it taken.
                    e.state.store(DECODING, Ordering::Release);
                    break e;
                }
                c = CACHE.work.wait(c).unwrap_or_else(|e| e.into_inner());
            }
        };
        decode(&e);
    }
}

/// Asks for [path] ahead of need (queued behind earlier asks; an entry that
/// is there is kept for this scene). Its state.
pub fn want(path: &str) -> i32 {
    let mut c = lock();
    c.s.wanted += 1;
    c.get(path, false).entry.state()
}

/// A reference to a cache entry: it stays cached (and its data valid) while
/// held. Dropping it gives the reference back (takes the cache's lock: never
/// on the render thread).
pub struct Held(Arc<Entry>);

impl Held {
    /// Takes [path] to play; a file not decoded yet moves to the front of
    /// the queue.
    pub fn acquire(path: &str) -> Held {
        let mut c = lock();
        let m = c.get(path, true);
        m.refs += 1;
        let e = m.entry.clone();
        if e.state() == READY {
            c.s.hits += 1;
        } else {
            c.s.misses += 1;
        }
        Held(e)
    }

    pub fn entry(&self) -> &Entry {
        &self.0
    }

    /// Waits until it is decoded, decoding it on the calling thread when no
    /// worker has started it. READY or FAILED.
    pub fn wait(&self) -> i32 {
        let e = &self.0;
        let t0 = Instant::now();
        let mut c = lock();
        let s = e.state();
        if s == READY || s == FAILED {
            return s;
        }
        c.s.waits += 1;
        if s == QUEUED {
            c.unqueue(e);
            e.state.store(DECODING, Ordering::Release);
            drop(c);
            decode(e);
            c = lock();
        }
        while e.state() == DECODING {
            c = CACHE.done.wait(c).unwrap_or_else(|e| e.into_inner());
        }
        c.s.wait_us += now_us(t0);
        e.state()
    }
}

impl Drop for Held {
    fn drop(&mut self) {
        let mut c = lock();
        if let Some(m) = c.map.get_mut(self.0.path()) {
            if Arc::ptr_eq(&m.entry, &self.0) && m.refs > 0 {
                m.refs -= 1;
            }
        }
        c.trim_budget();
    }
}

/// A scene change: entries nobody holds and nobody wanted since the change
/// before this one are dropped (queued ones leave the queue), so the scene
/// being left and the next scene's preloads stay until the change after.
pub fn scene_changed() {
    let mut c = lock();
    c.gen += 1;
    let gen = c.gen;
    let old: Vec<String> = c
        .map
        .iter()
        .filter(|(_, m)| droppable(m) && m.gen < gen - 1)
        .map(|(k, _)| k.clone())
        .collect();
    for k in old {
        c.drop_entry(&k);
    }
}

/// Decoded bytes kept before the oldest unheld entries are dropped.
pub fn set_budget(bytes: i64) {
    let mut c = lock();
    c.budget = bytes;
    c.trim_budget();
}

/// Drops every entry nobody holds (tests, shutdown).
pub fn clear() {
    let mut c = lock();
    let all: Vec<String> = c
        .map
        .iter()
        .filter(|(_, m)| droppable(m))
        .map(|(k, _)| k.clone())
        .collect();
    for k in all {
        c.drop_entry(&k);
    }
}

/// Entries, decoded bytes, queued, decodes done, decode µs, dropped,
/// acquires ready, acquires not ready, waits, wait µs, wants, failed.
pub fn stats() -> [i64; 12] {
    let c = lock();
    let s = &c.s;
    [
        s.entries,
        s.bytes,
        c.queue.len() as i64,
        s.decoded,
        s.decode_us,
        s.evicted,
        s.hits,
        s.misses,
        s.waits,
        s.wait_us,
        s.wanted,
        s.failed,
    ]
}
