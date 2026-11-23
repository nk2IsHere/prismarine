//! Output of PCM rendered elsewhere. PCM rendered on a Dart isolate is
//! pushed into a ring that the output device ([device], cpal) drains in its
//! callback. The audio clock counts the frames that the device has taken
//! from the ring ([PushStream::consumed]).
//!
//! The ring is the wait-free single-producer single-consumer buffer of
//! `rtrb`. The producer, one Dart isolate at a time under a lock, pushes.
//! The callback of the device pops and does not allocate or lock.
//!
//! A paused stream takes nothing and the clock stops. A muted stream takes
//! and plays silence and the clock runs. A ring that runs dry plays silence
//! without advancing the clock and waits until [REFILL] frames are queued
//! again, which counts as an underrun.

use crossbeam_utils::CachePadded;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use crate::device::{self, Device, Render, StartError};

/// Interleaved stereo.
const CHANNELS: usize = 2;

/// The frames queued again before a dry ring plays on, 50 ms at 48 kHz.
pub const REFILL: usize = 2400;

/// The room of the ring, two seconds, far beyond the render-ahead of about
/// 65 ms.
const CAPACITY_FRAMES: usize = 96000;

/// The counters of the stream. The reader in the device callback writes
/// consumed and underruns. The Dart side writes paused and muted. Each
/// writer has its own cache line.
#[derive(Default)]
struct Shared {
    consumed: CachePadded<AtomicI64>,
    underruns: AtomicI64,
    paused: CachePadded<AtomicBool>,
    muted: AtomicBool,
}

/// The side of the device.
struct Reader {
    ring: rtrb::Consumer<f32>,
    sh: Arc<Shared>,
    /// True while dry and silent until [REFILL] frames are queued. A new
    /// stream starts dry.
    dry: bool,
}

impl Render for Reader {
    fn render(&mut self, out: &mut [f32]) {
        if self.sh.paused.load(Ordering::Acquire) {
            out.fill(0.0);
            return;
        }
        let queued = self.ring.slots();
        if self.dry {
            if queued < REFILL * CHANNELS {
                out.fill(0.0);
                return;
            }
            self.dry = false;
        }
        // Only whole frames.
        let n = queued.min(out.len()) / CHANNELS * CHANNELS;
        if let Ok(chunk) = self.ring.read_chunk(n) {
            let (a, b) = chunk.as_slices();
            out[..a.len()].copy_from_slice(a);
            out[a.len()..a.len() + b.len()].copy_from_slice(b);
            chunk.commit_all();
        }
        out[n..].fill(0.0);
        if n < out.len() {
            self.dry = true;
            self.sh.underruns.fetch_add(1, Ordering::AcqRel);
        }
        if self.sh.muted.load(Ordering::Acquire) {
            out[..n].fill(0.0);
        }
        self.sh
            .consumed
            .fetch_add((n / CHANNELS) as i64, Ordering::AcqRel);
    }
}

pub struct PushStream {
    sh: Arc<Shared>,
    ring: Mutex<rtrb::Producer<f32>>,
    _device: Device,
}

impl PushStream {
    /// Opens the default output at 48 kHz f32 stereo, with buffers of
    /// [period] frames when the device allows it, fed from a new ring.
    pub fn start(period: u32) -> Result<PushStream, StartError> {
        let (tx, rx) = rtrb::RingBuffer::new(CAPACITY_FRAMES * CHANNELS);
        let sh = Arc::new(Shared::default());
        let reader = Box::new(Reader {
            ring: rx,
            sh: sh.clone(),
            dry: true,
        });
        let device = device::Device::start(reader, period)?;
        Ok(PushStream {
            sh,
            ring: Mutex::new(tx),
            _device: device,
        })
    }

    /// Queues the interleaved stereo [pcm]. Returns the frames taken, fewer
    /// only when the ring is full.
    pub fn push(&self, pcm: &[f32]) -> usize {
        let mut tx = self.ring.lock().unwrap_or_else(|e| e.into_inner());
        let n = tx.slots().min(pcm.len()) / CHANNELS * CHANNELS;
        if let Ok(chunk) = tx.write_chunk_uninit(n) {
            chunk.fill_from_iter(pcm[..n].iter().copied());
        }
        n / CHANNELS
    }

    /// Returns the frames that the device has taken so far.
    pub fn consumed(&self) -> i64 {
        self.sh.consumed.load(Ordering::Acquire)
    }

    pub fn set_paused(&self, v: bool) {
        self.sh.paused.store(v, Ordering::Release);
    }

    pub fn set_muted(&self, v: bool) {
        self.sh.muted.store(v, Ordering::Release);
    }

    /// Returns the underruns since the last call.
    pub fn take_underruns(&self) -> i64 {
        self.sh.underruns.swap(0, Ordering::AcqRel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reader() -> (rtrb::Producer<f32>, Reader) {
        let (tx, rx) = rtrb::RingBuffer::new(CAPACITY_FRAMES * CHANNELS);
        (
            tx,
            Reader {
                ring: rx,
                sh: Arc::new(Shared::default()),
                dry: true,
            },
        )
    }

    fn push(tx: &mut rtrb::Producer<f32>, frames: usize, v: f32) {
        for _ in 0..frames * CHANNELS {
            tx.push(v).unwrap();
        }
    }

    #[test]
    fn starts_dry_until_refill_then_plays_and_counts_frames() {
        let (mut tx, mut r) = reader();
        let mut out = vec![1.0; 1024 * CHANNELS];
        push(&mut tx, REFILL - 1, 0.5);
        r.render(&mut out);
        assert!(out.iter().all(|&s| s == 0.0));
        assert_eq!(r.sh.consumed.load(Ordering::Acquire), 0);
        push(&mut tx, 1, 0.5);
        r.render(&mut out);
        assert!(out.iter().all(|&s| s == 0.5));
        assert_eq!(r.sh.consumed.load(Ordering::Acquire), 1024);
    }

    #[test]
    fn a_dry_ring_plays_what_it_has_counts_an_underrun_and_waits() {
        let (mut tx, mut r) = reader();
        push(&mut tx, REFILL + 100, 0.25);
        let mut out = vec![1.0; REFILL * CHANNELS];
        r.render(&mut out);
        r.render(&mut out);
        assert!(out[..200].iter().all(|&s| s == 0.25));
        assert!(out[200..].iter().all(|&s| s == 0.0));
        assert_eq!(r.sh.consumed.load(Ordering::Acquire), (REFILL + 100) as i64);
        assert_eq!(r.sh.underruns.load(Ordering::Acquire), 1);
        push(&mut tx, 10, 0.25);
        r.render(&mut out);
        assert_eq!(r.sh.consumed.load(Ordering::Acquire), (REFILL + 100) as i64);
    }

    #[test]
    fn paused_takes_nothing_and_muted_takes_silence() {
        let (mut tx, mut r) = reader();
        push(&mut tx, REFILL * 2, 0.5);
        let mut out = vec![1.0; 256 * CHANNELS];
        r.sh.paused.store(true, Ordering::Release);
        r.render(&mut out);
        assert!(out.iter().all(|&s| s == 0.0));
        assert_eq!(r.sh.consumed.load(Ordering::Acquire), 0);
        r.sh.paused.store(false, Ordering::Release);
        r.sh.muted.store(true, Ordering::Release);
        out.fill(1.0);
        r.render(&mut out);
        assert!(out.iter().all(|&s| s == 0.0));
        assert_eq!(r.sh.consumed.load(Ordering::Acquire), 256);
    }
}
