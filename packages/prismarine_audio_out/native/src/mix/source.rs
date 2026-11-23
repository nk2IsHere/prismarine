//! Sample sources: the decoded-audio cache's entries and
//! streams, bound to the engine's waveform slots by the thread that posts a
//! start, read by the render thread, freed by the collector.
//!
//! A source is shared through [SrcRef]s. Freeing one takes locks (the
//! cache's, a stream's), which the render thread must not, so the last
//! reference never goes away where it is dropped: a [SrcRef] is basedrop's
//! `Shared`, whose last drop queues the source for the engine's collector
//! (the service thread, or the lockstep caller after a render), which
//! drops it there. Queueing allocates nothing (the node is made with the
//! source, by the poster).

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering::Relaxed};
use std::sync::OnceLock;

use basedrop::{Collector, Handle, Shared};

use crate::decode::cache::{Held, FAILED, READY};
use crate::decode::stream::Stream;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Pcm,
    Stream,
    /// Not there (missing file, failed decode in capture): a problem when
    /// played, as the Dart loader's null.
    Failed,
}

pub const TAPS: usize = 6;

/// The render thread's view of a source. Only the render thread writes it
/// once the source is shared (atomics with relaxed order: plain loads and
/// stores, no locks).
pub struct View {
    frames: AtomicI64,
    channels: AtomicI64,
    rate: AtomicI64,
    /// The decode's format replaced the bank's (or the decode failed).
    taken: AtomicBool,
    /// Stream taps: the frames each read last, and when.
    pub tstart: [AtomicI64; TAPS],
    pub tend: [AtomicI64; TAPS],
    pub tused: [AtomicI64; TAPS],
    pub ntaps: AtomicUsize,
    pub clock: AtomicI64,
    /// A tap opened for a prefetch: the frame its ring starts at (0: none).
    pub tcue: [AtomicI64; TAPS],
    /// The reader that reads each tap (0: none): a playing sound keeps its
    /// own stream, as each FMOD stream instance has its own decoder.
    pub towner: [AtomicI64; TAPS],
    /// The last reader id given out.
    pub readers: AtomicI64,
}

pub struct Src {
    pub kind: Kind,
    pub gen: i64,
    pub path: String,
    /// The cache entry it plays (Kind::Pcm).
    pcm: Option<Held>,
    /// Stream readers, opened by the service thread on the render thread's
    /// request (tap 0 when bound).
    pub taps: [OnceLock<Stream>; TAPS],
    pub view: View,
}

impl Src {
    pub fn new(kind: Kind, path: &str, gen: i64, frames: i64, channels: i64, rate: i64) -> Src {
        Src {
            kind,
            gen,
            path: path.to_string(),
            pcm: None,
            taps: [const { OnceLock::new() }; TAPS],
            view: View {
                frames: AtomicI64::new(frames),
                channels: AtomicI64::new(channels),
                rate: AtomicI64::new(rate),
                taken: AtomicBool::new(false),
                tstart: [const { AtomicI64::new(0) }; TAPS],
                tend: [const { AtomicI64::new(0) }; TAPS],
                tused: [const { AtomicI64::new(0) }; TAPS],
                ntaps: AtomicUsize::new(if kind == Kind::Stream { 1 } else { 0 }),
                clock: AtomicI64::new(0),
                tcue: [const { AtomicI64::new(0) }; TAPS],
                towner: [const { AtomicI64::new(0) }; TAPS],
                readers: AtomicI64::new(0),
            },
        }
    }

    /// Plays [held] (a cache entry).
    pub fn with_pcm(mut self, held: Held) -> Src {
        self.pcm = Some(held);
        self
    }

    pub fn held(&self) -> Option<&Held> {
        self.pcm.as_ref()
    }

    pub fn frames(&self) -> i64 {
        self.view.frames.load(Relaxed)
    }
    pub fn channels(&self) -> i64 {
        self.view.channels.load(Relaxed)
    }
    pub fn rate(&self) -> i64 {
        self.view.rate.load(Relaxed)
    }

    /// The decoded samples once taken (None: not there, or failed).
    pub fn data(&self) -> Option<&[f32]> {
        if !self.view.taken.load(Relaxed) {
            return None;
        }
        self.pcm
            .as_ref()
            .and_then(|h| h.entry().pcm())
            .map(|p| &p.samples[..])
    }

    /// CachedPcmSource._take on the render thread: the decode's format
    /// replaces the bank's once the data is there.
    pub fn take(&self) {
        let v = &self.view;
        if v.taken.load(Relaxed) || self.kind != Kind::Pcm {
            return;
        }
        let Some(e) = self.pcm.as_ref().map(Held::entry) else {
            return;
        };
        match e.state() {
            READY => {
                if let Some(p) = e.pcm() {
                    v.frames.store(p.frames, Relaxed);
                    v.channels.store(p.channels as i64, Relaxed);
                    v.rate.store(p.rate as i64, Relaxed);
                }
                v.taken.store(true, Relaxed);
            }
            FAILED => v.taken.store(true, Relaxed),
            _ => {}
        }
    }

    /// pcmReady.
    pub fn ready(&self) -> bool {
        match self.kind {
            Kind::Pcm => {
                self.take();
                self.view.taken.load(Relaxed)
            }
            Kind::Stream => self.taps[0].get().is_some_and(|t| t.ready() != 0),
            Kind::Failed => true,
        }
    }
}

/// A shared reference to a source; its last drop never frees the source
/// where it is dropped (see the module comment).
#[derive(Clone)]
pub struct SrcRef(Shared<Src>);

impl SrcRef {
    /// Shares [src]; its last drop queues it for [garbage]'s collector.
    pub fn new(src: Src, garbage: &Handle) -> SrcRef {
        SrcRef(Shared::new(garbage, src))
    }

    pub fn ptr_eq(a: &SrcRef, b: &SrcRef) -> bool {
        std::ptr::eq::<Src>(&**a, &**b)
    }
}

impl std::ops::Deref for SrcRef {
    type Target = Src;
    fn deref(&self) -> &Src {
        &self.0
    }
}

/// The collector: drops the sources whose last reference went (never the
/// render thread).
pub fn collect(garbage: &mut Collector) {
    garbage.collect();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(path: &str, garbage: &Handle) -> SrcRef {
        SrcRef::new(Src::new(Kind::Failed, path, 0, 0, 1, 48000), garbage)
    }

    #[test]
    fn a_dropped_reference_goes_to_the_collector() {
        let mut g = Collector::new();
        let a = src("x", &g.handle());
        let b = a.clone();
        drop(a);
        // A share is left: nothing is queued.
        g.collect();
        assert_eq!(g.alloc_count(), 1);
        assert_eq!(b.path, "x");
        // The last share queues it; the source is still there until the
        // collector runs.
        drop(b);
        assert_eq!(g.alloc_count(), 1);
        collect(&mut g);
        assert_eq!(g.alloc_count(), 0);
        assert!(g.try_cleanup().is_ok());
    }

    #[test]
    fn shares_cross_threads() {
        let mut g = Collector::new();
        let a = SrcRef::new(Src::new(Kind::Pcm, "p", 3, 10, 2, 44100), &g.handle());
        let b = a.clone();
        assert!(SrcRef::ptr_eq(&a, &b));
        assert!(!SrcRef::ptr_eq(&a, &src("q", &g.handle())));
        let t = std::thread::spawn(move || {
            assert_eq!(b.frames(), 10);
            assert_eq!(b.gen, 3);
        });
        t.join().unwrap();
        assert!(!a.ready());
        drop(a);
        collect(&mut g);
        assert_eq!(g.alloc_count(), 0);
        assert!(g.try_cleanup().is_ok());
    }
}
