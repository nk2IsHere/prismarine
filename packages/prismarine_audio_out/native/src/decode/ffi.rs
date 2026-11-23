//! The C ABI of the decoders, the cache, the jobs and the streams for
//! lib/src/native.dart. Handles are boxed Rust values. A pointer that Dart
//! holds is valid until Dart passes it back to the matching release.

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

/// Passes the samples of [pcm] to Dart in a malloc'd buffer, which
/// prismarine_audio_free releases.
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
    // SAFETY: `buf` has room for n ≥ samples.len() floats and does not
    // overlap the Vec. The out pointers are writable by the contract of the
    // caller.
    unsafe {
        std::ptr::copy_nonoverlapping(p.samples.as_ptr(), buf, p.samples.len());
        *out = buf;
        *channels = p.channels;
        *rate = p.rate;
    }
    p.frames
}

/// Decodes a whole MP3 file. Returns the frames, or −1. *out is released
/// with prismarine_audio_free.
///
/// # Safety
/// [data] holds [len] bytes. The out pointers are writable.
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

/// Decodes a whole Ogg Vorbis file as prismarine_mp3_decode does.
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
/// [p] is null or came from a decode above and is released once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_audio_free(p: *mut c_void) {
    // SAFETY: by the contract of the caller, `give` allocated it with malloc.
    unsafe { free(p) };
}

// ---------------------------------------------------------------- jobs

/// Queues a whole-file decode of [path], an .ogg file or an .mp3 file by
/// its extension.
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_decode_async(p: *const c_char) -> *mut Arc<Job> {
    // SAFETY: the caller's contract.
    Box::into_raw(Box::new(jobs::decode_async(unsafe { path(p) })))
}

/// Returns 0 while queued or decoding, 1 when done and −1 when failed.
///
/// # Safety
/// [j] is a live job of prismarine_decode_async that was not released.
#[no_mangle]
pub unsafe extern "C" fn prismarine_job_state(j: *const Arc<Job>) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*j }.state()
}

/// Returns the interleaved float32 samples, frames, channels and rate of a
/// done job, valid until it is released.
///
/// # Safety
/// [j] is a live job. The out pointers are writable.
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

/// Releases the job with its samples. A running decode is freed when done.
///
/// # Safety
/// [j] is a live job, released once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_job_release(j: *mut Arc<Job>) {
    if !j.is_null() {
        // SAFETY: by the contract of the caller, prismarine_decode_async
        // boxed it.
        drop(unsafe { Box::from_raw(j) });
    }
}

// ---------------------------------------------------------------- the cache

/// Asks for [path] ahead of need. Returns its state, 0 for queued, 1 for
/// ready, 2 for decoding and −1 for failed.
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_want(p: *const c_char) -> i32 {
    // SAFETY: the caller's contract.
    cache::want(unsafe { path(p) })
}

/// Takes [path] to play. Returns a reference, which prismarine_pcm_release
/// gives back.
///
/// # Safety
/// [path] is a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_acquire(p: *const c_char) -> *mut Held {
    // SAFETY: the caller's contract.
    Box::into_raw(Box::new(Held::acquire(unsafe { path(p) })))
}

/// # Safety
/// [e] is a live reference of prismarine_pcm_acquire that was not released.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_state(e: *const Held) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*e }.entry().state()
}

/// Waits until it is decoded. Returns 1, or −1 on a failure.
///
/// # Safety
/// As prismarine_pcm_state.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_wait(e: *const Held) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*e }.wait()
}

/// Returns the interleaved float32 samples of a ready entry, valid while
/// referenced.
///
/// # Safety
/// As prismarine_pcm_state. The out pointers are writable.
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

/// Gives a reference back, from the finalizer of a Dart source.
///
/// # Safety
/// [e] is a live reference, released once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_pcm_release(e: *mut c_void) {
    if !e.is_null() {
        // SAFETY: by the contract of the caller, prismarine_pcm_acquire boxed
        // it.
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

/// Writes the 12 int64s of cache::stats into [out].
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

/// Queues the Ogg Vorbis file [path] for the feeder (stream::Stream::open).
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

/// Returns 1 when open, 0 while opening and −1 when failed.
///
/// # Safety
/// [s] is a live stream of prismarine_stream_open that was not closed.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_ready(s: *const Stream) -> i32 {
    // SAFETY: the caller's contract.
    unsafe { &*s }.ready()
}

/// # Safety
/// As prismarine_stream_ready. The out pointers are writable.
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
/// As prismarine_stream_ready. [out] has room for [count] frames of the
/// channels of the stream.
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
    // SAFETY: the contract of the caller, count frames of `ch` channels.
    let out = unsafe { std::slice::from_raw_parts_mut(out, (count * ch as i64) as usize) };
    s.read(out, frame, count)
}

/// Returns and clears the frames read as silence so far.
///
/// # Safety
/// As prismarine_stream_ready.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_take_missing(s: *const Stream) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { &*s }.take_missing()
}

/// Closes the stream. The feeder lets it go.
///
/// # Safety
/// [s] is a live stream, closed once.
#[no_mangle]
pub unsafe extern "C" fn prismarine_stream_close(s: *mut Stream) {
    if !s.is_null() {
        // SAFETY: by the contract of the caller, prismarine_stream_open boxed
        // it.
        drop(unsafe { Box::from_raw(s) });
    }
}
