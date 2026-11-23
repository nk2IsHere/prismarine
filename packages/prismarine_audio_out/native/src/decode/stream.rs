//! Streamed Ogg Vorbis: a waveform FMOD streams (WAIB loading mode 2) is
//! decoded incrementally, never whole on the render thread. Each stream reads
//! its file, decodes a head at open (the start and loops back to it play at
//! once), and a single feeder thread keeps a ring of decoded frames ahead of
//! the reader. The reader only copies from the head or the ring; frames not
//! decoded yet read as silence and are counted.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use super::codec::Vorbis;

#[derive(Default)]
struct Inner {
    channels: i32,
    rate: i32,
    /// Frames in the file.
    total: i64,
    head: Vec<f32>,
    head_frames: i64,
    /// Circular: frame f at (f % cap).
    ring: Vec<f32>,
    cap: i64,
    base: i64,
    filled: i64,
    /// The end of the latest read.
    consumed: i64,
    /// −1: none.
    seek_req: i64,
    /// Frames read as silence (not decoded yet).
    missing: i64,
    /// The first such frame since the last [Stream::take_missing_info], and
    /// the ring then (base, filled, a seek pending): −1 none.
    miss_at: i64,
    miss_ring: (i64, i64, bool),
    /// A prefetch asked for before the stream opened (0: none): the feeder
    /// starts its ring there after the head.
    cue_at: i64,
    closed: bool,
    /// 0 opening (on the feeder), 1 open, −1 failed.
    state: i32,
}

impl Inner {
    fn ring_put(&mut self, src: &[f32], n: i64) {
        let ch = self.channels as usize;
        for i in 0..n {
            let at = (((self.base + self.filled + i) % self.cap) as usize) * ch;
            let from = i as usize * ch;
            self.ring[at..at + ch].copy_from_slice(&src[from..from + ch]);
        }
        self.filled += n;
    }
}

struct Shared {
    path: String,
    head_seconds: f64,
    inner: Mutex<Inner>,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// A stream; dropping it closes it (the feeder lets it go).
pub struct Stream(Arc<Shared>);

/// Streams the feeder hasn't picked up yet, and whether it runs.
struct Opened {
    new: Vec<Arc<Shared>>,
    feeder: bool,
}

static OPENED: Mutex<Opened> = Mutex::new(Opened {
    new: Vec::new(),
    feeder: false,
});

/// The feeder's own part of a stream.
struct Fed {
    s: Arc<Shared>,
    v: Option<Vorbis>,
    dec_pos: i64,
}

const TMP_FRAMES: i64 = 4096;

fn feeder() {
    // MCSM_FEEDER_QOS=off: the class it was made with (A/B).
    if std::env::var("MCSM_FEEDER_QOS").map_or(true, |v| v != "off") {
        super::os::take_role(super::os::Role::Feeder);
    }
    let mut tmp = vec![0f32; (TMP_FRAMES * 8) as usize];
    let mut list: Vec<Fed> = Vec::new();
    loop {
        {
            let mut o = OPENED.lock().unwrap_or_else(|e| e.into_inner());
            for s in o.new.drain(..) {
                list.push(Fed {
                    s,
                    v: None,
                    dec_pos: 0,
                });
            }
        }
        list.retain(|f| !f.s.lock().closed);
        let mut worked = false;
        for f in &mut list {
            worked |= feed(f, &mut tmp);
        }
        if !worked {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

/// Reads and opens the file and decodes the head (on the feeder thread).
fn init(f: &mut Fed) -> bool {
    let Some(data) = std::fs::read(&f.s.path).ok().filter(|d| !d.is_empty()) else {
        return false;
    };
    let Some(mut v) = Vorbis::open(data.into_boxed_slice()) else {
        return false;
    };
    let ch = v.channels as i64;
    let rate = v.rate;
    let total = v.total;
    let want = ((f.s.head_seconds * rate as f64) as i64).min(total);
    let mut head = vec![0f32; ((want + 1) * ch) as usize];
    let mut got = 0i64;
    while got < want {
        let n = v.read(&mut head[(got * ch) as usize..(want * ch) as usize]);
        if n <= 0 {
            break;
        }
        got += n;
    }
    let cap = rate as i64 * 2;
    let ring = vec![0f32; (cap * ch) as usize];
    let mut s = f.s.lock();
    // A prefetch made while opening: the ring starts there.
    let start = if s.cue_at > got && s.cue_at < total {
        s.cue_at
    } else {
        got
    };
    if start != got {
        v.seek(start);
    }
    s.channels = v.channels;
    s.rate = rate;
    s.total = total;
    s.head = head;
    s.head_frames = got;
    s.cap = cap;
    s.ring = ring;
    s.base = start;
    s.consumed = start;
    drop(s);
    f.dec_pos = start;
    f.v = Some(v);
    true
}

/// One feeder pass over a stream: a pending seek, then decode while the
/// ring has room. True if it did anything.
fn feed(f: &mut Fed, tmp: &mut [f32]) -> bool {
    let state = f.s.lock().state;
    if state == 0 {
        let ok = init(f);
        f.s.lock().state = if ok { 1 } else { -1 };
        return true;
    }
    if state < 0 {
        return false;
    }
    let Some(v) = f.v.as_mut() else { return false };
    let mut worked = false;
    let (mut seek, total, ch) = {
        let mut s = f.s.lock();
        let r = s.seek_req;
        s.seek_req = -1;
        (r, s.total, s.channels as i64)
    };
    if seek >= 0 {
        if seek > total {
            seek = total;
        }
        v.seek(seek);
        f.dec_pos = seek;
        let mut s = f.s.lock();
        s.base = seek;
        s.filled = 0;
        drop(s);
        worked = true;
    }
    loop {
        let (mut room, next) = {
            let mut s = f.s.lock();
            if s.seek_req >= 0 {
                return true;
            }
            // Keep an eighth of the ring behind the reader (re-reads of
            // recent frames, the interpolation's next frame).
            let keep = s.consumed - s.cap / 8;
            if keep > s.base {
                let drop = (keep - s.base).min(s.filled);
                s.base += drop;
                s.filled -= drop;
            }
            (s.cap - s.filled, s.base + s.filled)
        };
        if room <= 0 || f.dec_pos >= total || next != f.dec_pos {
            break;
        }
        if room > TMP_FRAMES {
            room = TMP_FRAMES;
        }
        let n = v.read(&mut tmp[..(room * ch) as usize]);
        if n <= 0 {
            f.dec_pos = total;
            break;
        }
        let mut s = f.s.lock();
        if s.seek_req < 0 && s.base + s.filled == f.dec_pos {
            s.ring_put(tmp, n);
        }
        drop(s);
        f.dec_pos += n;
        worked = true;
    }
    worked
}

impl Stream {
    /// Queues [path] (Ogg Vorbis) for the feeder, which opens it and decodes
    /// a [head_seconds] head; until then reads are silence and [ready] is 0.
    pub fn open(path: &str, head_seconds: f64) -> Stream {
        let s = Arc::new(Shared {
            path: path.to_string(),
            head_seconds,
            inner: Mutex::new(Inner {
                seek_req: -1,
                miss_at: -1,
                ..Inner::default()
            }),
        });
        let mut o = OPENED.lock().unwrap_or_else(|e| e.into_inner());
        o.new.push(s.clone());
        if !o.feeder
            && std::thread::Builder::new()
                .name("prismarine-stream-feeder".into())
                .spawn(feeder)
                .is_ok()
        {
            o.feeder = true;
        }
        Stream(s)
    }

    /// 1 open, 0 still opening, −1 failed.
    pub fn ready(&self) -> i32 {
        self.0.lock().state
    }

    /// Channels, rate, frames (zero until open).
    pub fn info(&self) -> (i32, i32, i64) {
        let s = self.0.lock();
        (s.channels, s.rate, s.total)
    }

    /// Copies [count] frames from [frame] into [out] (interleaved; at most
    /// what fits): the head, the ring, or silence where neither has them
    /// yet. Asks the feeder to move when the ring isn't where the reader
    /// needs it. Returns the frames that had data.
    pub fn read(&self, out: &mut [f32], frame: i64, count: i64) -> i64 {
        let mut s = self.0.lock();
        if s.state != 1 {
            return 0;
        }
        let ch = s.channels as usize;
        let count = count.min((out.len() / ch.max(1)) as i64);
        let mut served = 0;
        for i in 0..count {
            let f = frame + i;
            let dst = &mut out[i as usize * ch..(i as usize + 1) * ch];
            if f >= 0 && f < s.head_frames {
                let at = f as usize * ch;
                dst.copy_from_slice(&s.head[at..at + ch]);
                served += 1;
            } else if f >= s.base && f < s.base + s.filled {
                let at = (f % s.cap) as usize * ch;
                dst.copy_from_slice(&s.ring[at..at + ch]);
                served += 1;
            } else {
                dst.fill(0.0);
            }
        }
        let end = frame + count;
        // The first frame the ring must hold next: past the head.
        let need = if end > s.head_frames {
            frame.max(s.head_frames)
        } else {
            s.head_frames
        };
        if need < s.total {
            let slack = 4096;
            if need < s.base || need > s.base + s.filled + slack {
                s.seek_req = need;
                s.consumed = need;
            } else if end > s.consumed || end < s.consumed - s.cap / 2 {
                s.consumed = end;
            }
        }
        let mut lost = 0;
        let mut first = -1;
        for f in frame..end {
            if f >= s.head_frames && f < s.total && !(f >= s.base && f < s.base + s.filled) {
                if first < 0 {
                    first = f;
                }
                lost += 1;
            }
        }
        if lost > 0 && s.miss_at < 0 {
            s.miss_at = first;
            s.miss_ring = (s.base, s.filled, s.seek_req >= 0);
        }
        s.missing += lost;
        served
    }

    /// Asks the feeder to have [frame] decoded before it is read: a timeline
    /// jump is about to land there (a loop end or a quantized transition,
    /// up to 0.5 s ahead). Frames in the head or the ring already need
    /// nothing; else the ring moves there now (or starts there once the
    /// stream opens), as a read far from it would move it later.
    pub fn prefetch(&self, frame: i64) {
        let mut s = self.0.lock();
        match s.state {
            0 => s.cue_at = frame,
            1 => {
                if frame < s.head_frames
                    || frame >= s.total
                    || (frame >= s.base && frame <= s.base + s.filled)
                {
                    return;
                }
                s.seek_req = frame;
                s.consumed = frame;
            }
            _ => {}
        }
    }

    /// Whether [frame] and the block after it can be read now (open, in the
    /// head or the ring), or lie past the end: a sound starting there won't
    /// read silence.
    pub fn has(&self, frame: i64) -> bool {
        let s = self.0.lock();
        if s.state != 1 {
            return false;
        }
        let last = (frame + 2048).min(s.total) - 1;
        let have = |f: i64| {
            f >= s.total || (f >= 0 && f < s.head_frames) || (f >= s.base && f < s.base + s.filled)
        };
        have(frame) && have(last)
    }

    /// Frames read as silence so far (cleared by the call).
    pub fn take_missing(&self) -> i64 {
        let mut s = self.0.lock();
        s.miss_at = -1;
        std::mem::take(&mut s.missing)
    }

    /// As [take_missing], with where it happened: (frames, the first frame
    /// read as silence, the ring's base and frames then, a seek pending then,
    /// the head's frames, the rate). None when nothing was missing.
    pub fn take_missing_info(&self) -> Option<(i64, i64, i64, i64, bool, i64, i32)> {
        let mut s = self.0.lock();
        let n = std::mem::take(&mut s.missing);
        let at = std::mem::replace(&mut s.miss_at, -1);
        if n == 0 {
            return None;
        }
        let (base, filled, seek) = s.miss_ring;
        Some((n, at, base, filled, seek, s.head_frames, s.rate))
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        self.0.lock().closed = true;
    }
}
