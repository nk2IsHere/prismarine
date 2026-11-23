//! Whole-buffer MP3 (minimp3) and Ogg Vorbis (stb_vorbis) decodes to
//! interleaved float32, and an incremental Vorbis reader for streams. The
//! decoders are the vendored C (build.rs); this module is their only caller.

use std::ffi::{c_int, c_uint, c_void};
use std::ptr::NonNull;

/// Decoded audio: interleaved float32.
pub struct Pcm {
    pub samples: Vec<f32>,
    pub frames: i64,
    pub channels: i32,
    pub rate: i32,
}

impl Pcm {
    /// The decoded bytes the cache counts.
    pub fn bytes(&self) -> i64 {
        self.frames * self.channels as i64 * 4
    }
}

// minimp3.h / minimp3_ex.h.
#[repr(C)]
struct Mp3Dec {
    mdct_overlap: [[f32; 9 * 32]; 2],
    qmf_state: [f32; 15 * 2 * 32],
    reserv: c_int,
    free_format_bytes: c_int,
    header: [u8; 4],
    reserv_buf: [u8; 511],
}

#[repr(C)]
struct Mp3Info {
    buffer: *mut f32,
    samples: usize,
    channels: c_int,
    hz: c_int,
    layer: c_int,
    avg_bitrate_kbps: c_int,
}

// stb_vorbis.c.
#[repr(C)]
struct StbVorbis {
    _opaque: [u8; 0],
}

#[repr(C)]
struct VorbisInfo {
    sample_rate: c_uint,
    channels: c_int,
    setup_memory_required: c_uint,
    setup_temp_memory_required: c_uint,
    temp_memory_required: c_uint,
    max_frame_size: c_int,
}

extern "C" {
    fn mp3dec_load_buf(
        dec: *mut Mp3Dec,
        buf: *const u8,
        buf_size: usize,
        info: *mut Mp3Info,
        progress_cb: *const c_void,
        user_data: *mut c_void,
    ) -> c_int;
    fn stb_vorbis_open_memory(
        data: *const u8,
        len: c_int,
        error: *mut c_int,
        alloc: *const c_void,
    ) -> *mut StbVorbis;
    fn stb_vorbis_get_info(f: *mut StbVorbis) -> VorbisInfo;
    fn stb_vorbis_stream_length_in_samples(f: *mut StbVorbis) -> c_uint;
    fn stb_vorbis_get_samples_float_interleaved(
        f: *mut StbVorbis,
        channels: c_int,
        buffer: *mut f32,
        num_floats: c_int,
    ) -> c_int;
    fn stb_vorbis_seek(f: *mut StbVorbis, sample_number: c_uint) -> c_int;
    fn stb_vorbis_close(f: *mut StbVorbis);
    fn free(p: *mut c_void);
}

// stb_vorbis's maths (build.rs renames its calls): the libm crate's, the same
// bits on every target.
#[no_mangle]
extern "C" fn prismarine_vorbis_sin(x: f64) -> f64 {
    libm::sin(x)
}
#[no_mangle]
extern "C" fn prismarine_vorbis_cos(x: f64) -> f64 {
    libm::cos(x)
}
#[no_mangle]
extern "C" fn prismarine_vorbis_exp(x: f64) -> f64 {
    libm::exp(x)
}
#[no_mangle]
extern "C" fn prismarine_vorbis_log(x: f64) -> f64 {
    libm::log(x)
}
#[no_mangle]
extern "C" fn prismarine_vorbis_pow(x: f64, y: f64) -> f64 {
    libm::pow(x, y)
}

/// prismarine_mp3_decode: the whole file, or None.
pub fn decode_mp3(data: &[u8]) -> Option<Pcm> {
    let mut dec = Box::new(Mp3Dec {
        mdct_overlap: [[0.0; 9 * 32]; 2],
        qmf_state: [0.0; 15 * 2 * 32],
        reserv: 0,
        free_format_bytes: 0,
        header: [0; 4],
        reserv_buf: [0; 511],
    });
    let mut info = Mp3Info {
        buffer: std::ptr::null_mut(),
        samples: 0,
        channels: 0,
        hz: 0,
        layer: 0,
        avg_bitrate_kbps: 0,
    };
    // SAFETY: `dec` and `info` are valid, writable and laid out as
    // minimp3's mp3dec_t and mp3dec_file_info_t; `data` is read within its
    // length; no progress callback.
    let r = unsafe {
        mp3dec_load_buf(
            &mut *dec,
            data.as_ptr(),
            data.len(),
            &mut info,
            std::ptr::null(),
            std::ptr::null_mut(),
        )
    };
    let buffer = info.buffer;
    let pcm = if r != 0 || buffer.is_null() || info.channels <= 0 {
        None
    } else {
        // SAFETY: on success minimp3 hands back a malloc'd buffer of
        // `info.samples` floats, all written.
        let samples = unsafe { std::slice::from_raw_parts(buffer, info.samples) }.to_vec();
        Some(Pcm {
            samples,
            frames: (info.samples / info.channels as usize) as i64,
            channels: info.channels,
            rate: info.hz,
        })
    };
    if !buffer.is_null() {
        // SAFETY: minimp3 allocated it with malloc, and nothing else holds
        // it (the samples were copied).
        unsafe { free(buffer.cast()) };
    }
    pcm
}

/// An open Ogg Vorbis decoder over a buffer it borrows for its life.
pub struct Vorbis {
    v: NonNull<StbVorbis>,
    _data: Box<[u8]>,
    pub channels: i32,
    pub rate: i32,
    /// Frames in the stream.
    pub total: i64,
}

impl Vorbis {
    pub fn open(data: Box<[u8]>) -> Option<Vorbis> {
        let len = c_int::try_from(data.len()).ok()?;
        let mut err: c_int = 0;
        // SAFETY: stb_vorbis reads `len` bytes of `data`, which the decoder
        // owns (`_data`) and never moves (a boxed slice) until it closes.
        let v = NonNull::new(unsafe {
            stb_vorbis_open_memory(data.as_ptr(), len, &mut err, std::ptr::null())
        })?;
        // SAFETY: `v` is an open decoder.
        let info = unsafe { stb_vorbis_get_info(v.as_ptr()) };
        // SAFETY: as above.
        let total = unsafe { stb_vorbis_stream_length_in_samples(v.as_ptr()) } as i64;
        Some(Vorbis {
            v,
            _data: data,
            channels: info.channels,
            rate: info.sample_rate as i32,
            total,
        })
    }

    /// Decodes up to `out.len() / channels` frames into `out` (interleaved
    /// in this stream's channels); the frames written, 0 at the end.
    pub fn read(&mut self, out: &mut [f32]) -> i64 {
        let floats = c_int::try_from(out.len()).unwrap_or(c_int::MAX);
        // SAFETY: `v` is open and `out` has room for `floats` floats.
        unsafe {
            stb_vorbis_get_samples_float_interleaved(
                self.v.as_ptr(),
                self.channels,
                out.as_mut_ptr(),
                floats,
            )
        }
        .max(0) as i64
    }

    pub fn seek(&mut self, frame: i64) {
        // SAFETY: `v` is open.
        unsafe { stb_vorbis_seek(self.v.as_ptr(), frame as c_uint) };
    }
}

impl Drop for Vorbis {
    fn drop(&mut self) {
        // SAFETY: `v` is open and closed only here.
        unsafe { stb_vorbis_close(self.v.as_ptr()) };
    }
}

/// prismarine_ogg_decode: the whole file, or None.
pub fn decode_ogg(data: &[u8]) -> Option<Pcm> {
    let mut v = Vorbis::open(data.into())?;
    let ch = v.channels as i64;
    let total = v.total;
    let mut buf = vec![0f32; (total * ch + 1) as usize];
    let mut got = 0i64;
    while got < total {
        let end = (total * ch) as usize;
        let n = v.read(&mut buf[(got * ch) as usize..end]);
        if n <= 0 {
            break;
        }
        got += n;
    }
    buf.truncate((got * ch) as usize);
    Some(Pcm {
        samples: buf,
        frames: got,
        channels: v.channels,
        rate: v.rate,
    })
}

/// A whole file (.ogg, or .mp3 by its extension), or None when it can't be
/// read or decoded.
pub fn decode_file(path: &str) -> Option<Pcm> {
    let data = std::fs::read(path).ok().filter(|d| !d.is_empty())?;
    if path.len() > 4 && (path.ends_with(".mp3") || path.ends_with(".MP3")) {
        decode_mp3(&data)
    } else {
        decode_ogg(&data)
    }
}
