//! prismarine_audio_out's output library: the decoders, the decoded-audio cache
//! and streams ([decode]), the output device ([device]) and the ring that
//! feeds it PCM rendered elsewhere ([push]). The mixer crate links it and
//! uses the cache, streams and device directly.
//!
//! `unsafe` lives only at the FFI edge (the `extern "C"` functions here and
//! in decode/ffi.rs, the decoders' calls, the thread role calls in
//! decode/os.rs).

pub mod decode;
pub mod device;
pub mod push;

use std::panic::catch_unwind;

/// The Dart mixer's output ([push]): opens the default output device fed
/// from a new PCM ring. Null when no device opens; [err] (when not null)
/// gets the code of the [device::StartError], or −7 when the start panicked.
///
/// # Safety
/// [err] is null or writable.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_start(err: *mut i32) -> *mut push::PushStream {
    let (stream, code) = match catch_unwind(|| push::PushStream::start(1024)) {
        Ok(Ok(s)) => (Box::into_raw(Box::new(s)), 0),
        Ok(Err(e)) => (std::ptr::null_mut(), e.code),
        Err(_) => (std::ptr::null_mut(), -7),
    };
    if !err.is_null() {
        // SAFETY: the caller's contract.
        unsafe { *err = code };
    }
    stream
}

/// Stops the device and frees the stream.
///
/// # Safety
/// [s] came from [prismarine_push_start] and is not used again.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_destroy(s: *mut push::PushStream) {
    if !s.is_null() {
        // SAFETY: the caller's contract.
        drop(unsafe { Box::from_raw(s) });
    }
}

/// Queues [frames] interleaved stereo frames from [pcm]; the frames taken.
///
/// # Safety
/// [s] is a live stream; [pcm] holds 2 × [frames] floats.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_pcm(
    s: *const push::PushStream,
    pcm: *const f32,
    frames: i64,
) -> i64 {
    if pcm.is_null() || frames <= 0 {
        return 0;
    }
    // SAFETY: the caller's contract.
    let (s, pcm) = unsafe { (&*s, std::slice::from_raw_parts(pcm, frames as usize * 2)) };
    s.push(pcm) as i64
}

/// Frames the device has taken from the stream so far (the audio clock).
///
/// # Safety
/// [s] is a live stream.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_consumed(s: *const push::PushStream) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { &*s }.consumed()
}

/// # Safety
/// [s] is a live stream.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_set_paused(s: *const push::PushStream, paused: i32) {
    // SAFETY: the caller's contract.
    unsafe { &*s }.set_paused(paused != 0);
}

/// # Safety
/// [s] is a live stream.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_set_muted(s: *const push::PushStream, muted: i32) {
    // SAFETY: the caller's contract.
    unsafe { &*s }.set_muted(muted != 0);
}

/// Underruns (the ring ran dry) since the last call.
///
/// # Safety
/// [s] is a live stream.
#[no_mangle]
pub unsafe extern "C" fn prismarine_push_underruns(s: *const push::PushStream) -> i64 {
    // SAFETY: the caller's contract.
    unsafe { &*s }.take_underruns()
}
