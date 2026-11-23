//! The decoders', cache's, jobs' and streams' C ABI (Dart:
//! lib/src/native.dart). Handles are boxed Rust values; a pointer
//! Dart holds is valid until it hands it back to the matching release.

use std::ffi::{c_char, c_void, CStr};
use std::sync::Arc;

use super::cache::{self, Held};
use super::codec::{self, Pcm};
use super::jobs::{self, Job};
use super::stream::Stream;

extern "C" {
    fn malloc(n: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

/// # Safety
/// [p] is null or a NUL-terminated string.
unsafe fn path<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        return "";
    }
    // SAFETY: the caller's contract.
    unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("")
}

/// Hands [pcm]'s samples to Dart in a malloc'd buffer (prismarine_audio_free).
///
/// # Safety
/// The out pointers are writable.
unsafe fn give(pcm: Option<Pcm>, out: *mut *mut f32, channels: *mut i32, rate: *mut i32) -> i64 {
    let Some(p) = pcm else { return -1 };
    let n = p.samples.len().max(1);
    // SAFETY: a plain allocation of n floats.
    let buf = unsafe { malloc(n * 4) }.cast::<f32>();
    if buf.is_null() {
        return -1;
    }
    // SAFETY: `buf` has room for n ≥ samples.len() floats and doesn't
    // overlap the Vec; the out pointers are writable (the caller's contract).
    unsafe {
        std::ptr::copy_nonoverlapping(p.samples.as_ptr(), buf, p.samples.len());
        *out = buf;
        *channels = p.channels;
        *rate = p.rate;
    }
    p.frames
}

/// Decodes a whole MP3: frames, or −1; *out is released with
/// prismarine_audio_free.
///
/// # Safety
/// [data] holds [len] bytes; the out pointers are writable.
#[no_mangle]
pub unsafe extern "C" fn prismarine_mp3_decode(
    data: *const u8,
    len: i64,
    out: *mut *mut f32,
    channels: *mut i32,
    rate: *mut i32,
) -> i64 {
    // SAFETY: the caller's contract.
    let d = unsafe { std::slice::from_raw_parts(data, len as usize) };
    // SAFETY: the caller's contract.
    unsafe { give(codec::decode_mp3(d), out, channels, rate) }
}

/// Decodes a whole Ogg Vorbis file, as prismarine_mp3_decode.
///
/// # Safety
/// As prismarine_mp3_decode.
#[no_mangle]
pub unsafe extern "C" fn prismarine_ogg_decode(
    data: *const u8,
    len: i64,
    out: *mut *mut f32,
    channels: *mut i32,
    rate: *mut i32,
) -> i64 {
    // SAFETY: the caller's contract.
    let d = unsafe { std::slice::from_raw_parts(data, len as usize) };
    // SAFETY: the caller's contract.
    unsafe { give(codec::decode_ogg(d), out, channels, rate) }
}

/// # Safety
/// [p] came from a decode above (or is null) and is released once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_audio_free(p: *mut c_void) {
    // SAFETY: the caller's contract: malloc'd by `give`.
    unsafe { free(p) };
}

// ---------------------------------------------------------------- jobs

/// Queues a whole-file decode of [path] (.ogg, or .mp3 by extension).
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_decode_async(p: *const c_char) -> *mut Arc<Job> {
    // SAFETY: the caller's contract.
    Box::into_raw(Box::new(jobs::decode_async(unsafe { path(p) })))
}

/// 0 queued or decoding, 1 done, −1 failed.
///
/// # Safety
/// [j] is a live job (prismarine_decode_async, not released).
#[no_mangle]
pub unsafe extern "C" fn prismarine_job_state(j: *const Arc<Job>) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*j }.state()
}

/// A done job's samples (interleaved float32), frames, channels and rate;
/// valid until it is released.
///
/// # Safety
/// [j] is a live job; the out pointers are writable.
#[no_mangle]
pub unsafe extern "C" fn prismarine_job_result(
    j: *const Arc<Job>,
    frames: *mut i64,
    channels: *mut i32,
    rate: *mut i32,
) -> *const f32 {
    // SAFETY: the caller's contract.
    let pcm = unsafe { &*j }.pcm();
    let (f, c, r, p) = match pcm {
        Some(p) => (p.frames, p.channels, p.rate, p.samples.as_ptr()),
        None => (0, 0, 0, std::ptr::null()),
    };
    // SAFETY: the caller's contract.
    unsafe {
        *frames = f;
        *channels = c;
        *rate = r;
    }
    p
}

/// Releases the job (and its samples); a running decode is freed when done.
///
/// # Safety
/// [j] is a live job, released once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_job_release(j: *mut Arc<Job>) {
    if !j.is_null() {
        // SAFETY: the caller's contract: boxed by prismarine_decode_async.
        drop(unsafe { Box::from_raw(j) });
    }
}

// ---------------------------------------------------------------- the cache

/// Asks for [path] ahead of need: its state (0 queued, 1 ready, 2
/// decoding, −1 failed).
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_want(p: *const c_char) -> i32 {
    // SAFETY: the caller's contract.
    cache::want(unsafe { path(p) })
}

/// Takes [path] to play: a reference (prismarine_pcm_release gives it back).
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_acquire(p: *const c_char) -> *mut Held {
    // SAFETY: the caller's contract.
    Box::into_raw(Box::new(Held::acquire(unsafe { path(p) })))
}

/// # Safety
/// [e] is a live reference (prismarine_pcm_acquire, not released).
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_state(e: *const Held) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*e }.entry().state()
}

/// Waits until it is decoded: 1 or −1.
///
/// # Safety
/// As prismarine_pcm_state.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_wait(e: *const Held) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*e }.wait()
}

/// A ready entry's samples (interleaved float32; valid while referenced).
///
/// # Safety
/// As prismarine_pcm_state; the out pointers are writable.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_data(
    e: *const Held,
    frames: *mut i64,
    channels: *mut i32,
    rate: *mut i32,
) -> *const f32 {
    // SAFETY: the caller's contract.
    let pcm = unsafe { &*e }.entry().pcm();
    let (f, c, r, p) = match pcm {
        Some(p) => (p.frames, p.channels, p.rate, p.samples.as_ptr()),
        None => (0, 0, 0, std::ptr::null()),
    };
    // SAFETY: the caller's contract.
    unsafe {
        *frames = f;
        *channels = c;
        *rate = r;
    }
    p
}

/// Gives a reference back (a Dart source's finalizer).
///
/// # Safety
/// [e] is a live reference, released once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_release(e: *mut c_void) {
    if !e.is_null() {
        // SAFETY: the caller's contract: boxed by prismarine_pcm_acquire.
        drop(unsafe { Box::from_raw(e.cast::<Held>()) });
    }
}

#[no_mangle]
pub extern "C" fn prismarine_pcm_scene_changed() {
    cache::scene_changed();
}

#[no_mangle]
pub extern "C" fn prismarine_pcm_set_budget(bytes: i64) {
    cache::set_budget(bytes);
}

#[no_mangle]
pub extern "C" fn prismarine_pcm_clear() {
    cache::clear();
}

/// [out] (12 int64s): see cache::stats.
///
/// # Safety
/// [out] has room for 12 int64s.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_stats(out: *mut i64) {
    let s = cache::stats();
    // SAFETY: the caller's contract.
    unsafe { std::ptr::copy_nonoverlapping(s.as_ptr(), out, s.len()) };
}

// ---------------------------------------------------------------- streams

/// Queues [path] (Ogg Vorbis) for the feeder (stream::Stream::open).
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_open(
    p: *const c_char,
    head_seconds: f64,
) -> *mut Stream {
    // SAFETY: the caller's contract.
    Box::into_raw(Box::new(Stream::open(unsafe { path(p) }, head_seconds)))
}

/// 1 open, 0 still opening, −1 failed.
///
/// # Safety
/// [s] is a live stream (prismarine_stream_open, not closed).
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_ready(s: *const Stream) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*s }.ready()
}

/// # Safety
/// As prismarine_stream_ready; the out pointers are writable.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_info(
    s: *const Stream,
    channels: *mut i32,
    rate: *mut i32,
    frames: *mut i64,
) {
    // SAFETY: the caller's contract.
    let (c, r, f) = unsafe { &*s }.info();
    // SAFETY: the caller's contract.
    unsafe {
        *channels = c;
        *rate = r;
        *frames = f;
    }
}

/// Copies [count] frames from [frame] into [out] (stream::Stream::read).
///
/// # Safety
/// As prismarine_stream_ready; [out] has room for [count] frames of the stream's
/// channels.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_read(
    s: *const Stream,
    out: *mut f32,
    frame: i64,
    count: i64,
) -> i64 {
    // SAFETY: the caller's contract.
    let s = unsafe { &*s };
    let ch = s.info().0;
    if ch <= 0 || count <= 0 {
        return 0;
    }
    // SAFETY: the caller's contract (count frames of `ch` channels).
    let out = unsafe { std::slice::from_raw_parts_mut(out, (count * ch as i64) as usize) };
    s.read(out, frame, count)
}

/// Frames read as silence so far (cleared by the call).
///
/// # Safety
/// As prismarine_stream_ready.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_take_missing(s: *const Stream) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { &*s }.take_missing()
}

/// Closes the stream (the feeder lets it go).
///
/// # Safety
/// [s] is a live stream, closed once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_close(s: *mut Stream) {
    if !s.is_null() {
        // SAFETY: the caller's contract: boxed by prismarine_stream_open.
        drop(unsafe { Box::from_raw(s) });
    }
}
