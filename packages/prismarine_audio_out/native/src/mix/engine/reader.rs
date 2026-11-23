//! Source readers over decoded and streamed waveforms, as voice.dart.

use super::*;

// ---------------------------------------------------------------- sources

/// A SourceReader, whose chunk is [Cx::chunk] of the render.
pub(crate) struct Reader {
    pub(crate) src: SrcRef,
    one: [f32; 16],
    /// The tap that this reader reads of a stream in real time, [NO_TAP]
    /// before its first read, and its id for the owner mark of the tap.
    tap: usize,
    id: i64,
}

const NO_TAP: usize = usize::MAX;

impl Reader {
    pub(crate) fn new(src: SrcRef) -> Reader {
        Reader {
            src,
            one: [0.0; 16],
            tap: NO_TAP,
            id: 0,
        }
    }
}

impl Drop for Reader {
    /// Gives its tap back with atomics only, since the render thread drops
    /// readers.
    fn drop(&mut self) {
        if self.tap < crate::mix::source::TAPS {
            let _ = self.src.view.towner[self.tap].compare_exchange(
                self.id,
                0,
                Ordering::Relaxed,
                Ordering::Relaxed,
            );
        }
    }
}

/// Returns the tap of a stream that reader [rd] reads at [frame]. A playing
/// sound keeps a tap of its own with its own decoder, and layers of one
/// waveform at different positions do not seek the rings of each other
/// away. A jump that the engine cued with stream_cue moves the reader to the
/// cued tap. With every tap owned, readers share by position.
fn reader_tap(sh: &Shared, rd: &mut Reader, frame: i64) -> usize {
    let s = &rd.src;
    let v = &s.view;
    let g = |a: &std::sync::atomic::AtomicI64| a.load(Ordering::Relaxed);
    let n = v.ntaps.load(Ordering::Relaxed);
    if rd.id == 0 {
        rd.id = v.readers.fetch_add(1, Ordering::Relaxed) + 1;
    }
    let mine = rd.tap < n && g(&v.towner[rd.tap]) == rd.id;
    let covers = |i: usize| frame >= g(&v.tstart[i]) - 2 && frame <= g(&v.tend[i]) + 4096;
    if mine && covers(rd.tap) {
        return rd.tap;
    }
    // A free tap whose window holds the frame, a cue made for this jump or
    // one that another reader let go, else any free tap, else a new one.
    let mut pick = None;
    for i in 0..n {
        if g(&v.towner[i]) == 0 && covers(i) {
            pick = Some(i);
            break;
        }
    }
    if pick.is_none() && mine {
        // Its own tap moves, for a jump that nothing cued.
        return rd.tap;
    }
    if pick.is_none() {
        pick = (0..n).find(|&i| g(&v.towner[i]) == 0);
        if let Some(i) = pick {
            if let Some(st) = s.taps[i].get() {
                st.prefetch(frame);
            }
        }
    }
    if pick.is_none() && n < crate::mix::source::TAPS {
        v.tcue[n].store(if frame > 0 { frame } else { 0 }, Ordering::Relaxed);
        if sh.requests.push((s.clone(), n)).is_ok() {
            v.ntaps.store(n + 1, Ordering::Relaxed);
            v.tstart[n].store(frame, Ordering::Relaxed);
            v.tend[n].store(frame, Ordering::Relaxed);
            pick = Some(n);
        }
    }
    let Some(t) = pick else {
        // Every tap has a reader, and readers share by position.
        return stream_tap(sh, s, frame);
    };
    if mine {
        v.towner[rd.tap].store(0, Ordering::Relaxed);
    }
    v.towner[t].store(rd.id, Ordering::Relaxed);
    rd.tap = t;
    t
}

fn stream_tap(sh: &Shared, s: &SrcRef, frame: i64) -> usize {
    let v = &s.view;
    let g = |a: &std::sync::atomic::AtomicI64| a.load(Ordering::Relaxed);
    let n = v.ntaps.load(Ordering::Relaxed);
    if (frame as f64) < 0.5 * s.rate() as f64 {
        let mut best = 0;
        for i in 0..n {
            if g(&v.tused[i]) > g(&v.tused[best]) {
                best = i;
            }
        }
        if frame >= g(&v.tend[best]) || frame < g(&v.tstart[best]) - 2 {
            return best;
        }
    }
    for i in 0..n {
        if frame >= g(&v.tstart[i]) - 2 && frame <= g(&v.tend[i]) + 4096 {
            return i;
        }
    }
    if n < crate::mix::source::TAPS {
        // The service thread opens it, and it reads silence until then, as a
        // stream that is still opening does.
        let _ = sh.requests.push((s.clone(), n));
        v.ntaps.store(n + 1, Ordering::Relaxed);
        return n;
    }
    let mut least = 0;
    for i in 1..n {
        if g(&v.tused[i]) < g(&v.tused[least]) {
            least = i;
        }
    }
    least
}

/// Gives a jump in real time that is about to reach source frame [frame] of
/// stream [s] a tap of its own with the ring there. The read after the jump
/// finds the destination decoded within the transition lookahead, and the
/// jump plays without a gap. It does not allocate, since the service thread
/// opens the tap.
pub(crate) fn stream_cue(sh: &Shared, s: &SrcRef, frame: i64) {
    if s.kind != Kind::Stream || (frame as f64) < 0.5 * s.rate() as f64 || frame >= s.frames() {
        return;
    }
    let v = &s.view;
    let g = |a: &std::sync::atomic::AtomicI64| a.load(Ordering::Relaxed);
    let n = v.ntaps.load(Ordering::Relaxed);
    // A tap that no reader owns, already there. The own tap of another
    // reader is not one that the jumping reader reads.
    for i in 0..n {
        if g(&v.towner[i]) == 0 && frame >= g(&v.tstart[i]) - 2 && frame <= g(&v.tend[i]) + 4096 {
            return;
        }
    }
    // The tap read last plays now, and the jump takes another.
    let mut now = 0;
    for i in 0..n {
        if g(&v.tused[i]) > g(&v.tused[now]) {
            now = i;
        }
    }
    let t = if n < crate::mix::source::TAPS {
        v.tcue[n].store(frame, Ordering::Relaxed);
        if sh.requests.push((s.clone(), n)).is_err() {
            return;
        }
        v.ntaps.store(n + 1, Ordering::Relaxed);
        n
    } else {
        let mut least = usize::MAX;
        for i in 0..n {
            if i != now
                && g(&v.towner[i]) == 0
                && (least == usize::MAX || g(&v.tused[i]) < g(&v.tused[least]))
            {
                least = i;
            }
        }
        if least == usize::MAX {
            return;
        }
        if let Some(st) = s.taps[least].get() {
            st.prefetch(frame);
        }
        least
    };
    v.tstart[t].store(frame, Ordering::Relaxed);
    v.tend[t].store(frame, Ordering::Relaxed);
    v.tused[t].store(g(&v.clock), Ordering::Relaxed);
}

/// Returns whether stream [s] can serve [frame] and the next block in real
/// time, and cues a tap there with stream_cue when it cannot. A sound that
/// starts in a stream waits for it.
pub(crate) fn stream_ready_at(sh: &Shared, rd: &mut Reader, frame: i64) -> bool {
    if rd.src.kind != Kind::Stream || !sh.hold_streams {
        return true;
    }
    let t = reader_tap(sh, rd, frame);
    rd.src.taps[t]
        .get()
        .is_some_and(|st| st.ready() == 1 && st.has(frame))
}

/// PcmSource.read.
fn src_read(sh: &Shared, rd: &mut Reader, out: Option<&mut [f32]>, frame: i64, count: i64) -> i64 {
    let ch = rd.src.channels();
    let frames = rd.src.frames();
    if frame < 0 || frame >= frames {
        return 0;
    }
    let stream = rd.src.kind == Kind::Stream;
    if stream && count <= 0 {
        return 0;
    }
    let n = (frames - frame).clamp(0, count);
    let len = (n * ch) as usize;
    let tap = if stream { reader_tap(sh, rd, frame) } else { 0 };
    let Reader { src: s, one, .. } = rd;
    let out: &mut [f32] = match out {
        Some(o) => o,
        None => &mut one[..],
    };
    if stream {
        let t = tap;
        let v = &s.view;
        v.tstart[t].store(frame, Ordering::Relaxed);
        v.tend[t].store(frame + n, Ordering::Relaxed);
        let clock = v.clock.load(Ordering::Relaxed) + 1;
        v.clock.store(clock, Ordering::Relaxed);
        v.tused[t].store(clock, Ordering::Relaxed);
        match s.taps[t].get() {
            Some(st) if st.ready() == 1 => {
                st.read(&mut out[..len], frame, n);
            }
            _ => out[..len].fill(0.0),
        }
        return n;
    }
    match s.data() {
        None => out[..len].fill(0.0),
        Some(d) => {
            let at = (frame * ch) as usize;
            out[..len].copy_from_slice(&d[at..at + len]);
        }
    }
    n
}

#[allow(clippy::too_many_arguments)]
/// Adds frames as SourceReader.addInto. Returns false once the source has
/// ended.
// The test keeps a NaN position playing, as Dart's does.
#[allow(clippy::nonminimal_bool)]
pub(crate) fn reader_add(
    sh: &Shared,
    chunk: &mut [f32],
    rd: &mut Reader,
    out: &mut [f32],
    mut rear: Option<&mut [f32]>,
    at: i64,
    n: i64,
    posp: &mut f64,
    rate: f64,
    g0: f64,
    g1: f64,
    gains: Option<&[f32]>,
    lp: bool,
    downmix: bool,
    pan_l: f64,
    pan_r: f64,
) -> bool {
    let frames = rd.src.frames();
    if frames <= 0 {
        return false;
    }
    let ch = rd.src.channels();
    let mut pos = *posp;
    let first = if pos < 0.0 { 0 } else { dfloor(pos) };
    let last = dfloor(pos + n as f64 * rate) + 1;
    let end = if last < frames { last } else { frames - 1 };
    let span = if lp { 0 } else { end - first + 1 };
    // The chunk holds the frames from base to base + have. Dart reads the
    // span at once, and a span longer than the chunk is read in pieces with
    // the same samples.
    let room = (chunk.len() as i64 / ch).max(2);
    let (mut base, mut have) = (first, 0i64);
    if span > 0 {
        have = span.min(room);
        src_read(sh, rd, Some(&mut *chunk), first, have);
    }
    for i in 0..n {
        if pos >= frames as f64 {
            if !lp {
                return false;
            }
            pos = dmod(pos, frames as f64);
        }
        if pos < 0.0 {
            pos += rate;
            continue;
        }
        let f = dfloor(pos);
        let frac = pos - f as f64;
        let mut g = g0 + (g1 - g0) * (i as f64 / n as f64);
        if let Some(gs) = gains {
            g *= gs[i as usize] as f64;
        }
        let (l0, r0, l1, r1);
        if lp {
            src_read(sh, rd, None, f, 1);
            l0 = rd.one[0] as f64;
            r0 = if ch > 1 { rd.one[1] as f64 } else { l0 };
            src_read(sh, rd, None, if f + 1 < frames { f + 1 } else { 0 }, 1);
            l1 = rd.one[0] as f64;
            r1 = if ch > 1 { rd.one[1] as f64 } else { l1 };
        } else {
            let hi = if f + 1 < frames { f + 1 } else { f };
            if f < base || hi >= base + have {
                base = f;
                have = (end - f + 1).min(room);
                src_read(sh, rd, Some(&mut *chunk), f, have);
            }
            let k = ((f - base) * ch) as usize;
            l0 = chunk[k] as f64;
            r0 = if ch > 1 { chunk[k + 1] as f64 } else { l0 };
            if f + 1 < frames {
                l1 = chunk[k + ch as usize] as f64;
                r1 = if ch > 1 {
                    chunk[k + ch as usize + 1] as f64
                } else {
                    l1
                };
            } else {
                l1 = l0;
                r1 = r0;
            }
        }
        let o = ((at + i) * 2) as usize;
        // The third and fourth channels of a quad source go into SL and SR
        // of a 5.1 strip, as Dart's `SourceReader._rears`.
        if let Some(rb) = rear.as_deref_mut() {
            if ch >= 4 {
                let (sl0, sr0, sl1, sr1);
                if lp {
                    src_read(sh, rd, None, f, 1);
                    let (a, b) = (rd.one[2] as f64, rd.one[3] as f64);
                    src_read(sh, rd, None, if f + 1 < frames { f + 1 } else { 0 }, 1);
                    (sl0, sr0, sl1, sr1) = (a, b, rd.one[2] as f64, rd.one[3] as f64);
                } else {
                    let k = ((f - base) * ch) as usize;
                    let n = if f + 1 < frames { ch as usize } else { 0 };
                    (sl0, sr0) = (chunk[k + 2] as f64, chunk[k + 3] as f64);
                    (sl1, sr1) = (chunk[k + n + 2] as f64, chunk[k + n + 3] as f64);
                }
                let q = ((at + i) * 6) as usize;
                rb[q + 4] = (rb[q + 4] as f64 + (sl0 + (sl1 - sl0) * frac) * g * pan_l) as f32;
                rb[q + 5] = (rb[q + 5] as f64 + (sr0 + (sr1 - sr0) * frac) * g * pan_r) as f32;
            }
        }
        let mut l = (l0 + (l1 - l0) * frac) * g;
        let mut r = (r0 + (r1 - r0) * frac) * g;
        if downmix {
            l = (l + r) * UPMIX;
            r = l;
        }
        out[o] = (out[o] as f64 + l * pan_l) as f32;
        out[o + 1] = (out[o + 1] as f64 + r * pan_r) as f32;
        pos += rate;
    }
    *posp = pos;
    !(pos >= frames as f64 && !lp)
}

/// Returns the gain and the downmix flag, as _format.
pub(crate) fn src_format(src: &Src, bus_mono: bool) -> (f64, bool) {
    let mono = src.channels() == 1;
    if mono && !bus_mono {
        return (UPMIX, false);
    }
    if !mono && bus_mono {
        return (1.0, true);
    }
    (1.0, false)
}
