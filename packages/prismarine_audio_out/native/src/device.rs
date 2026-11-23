//! The output device. It is the default output of the system through
//! `cpal`, CoreAudio on macOS, WASAPI on Windows and ALSA on Linux, at
//! 48 kHz float32 stereo, rendering inside its callback.
//!
//! The device owns the [Render] while it runs. The callback of the stream
//! is the only place that reaches it.
//!
//! The output fades in over [RAMP_FRAMES] when the stream starts and fades
//! out to silence before it stops. It stops when the [Device] is dropped or
//! when the process exits, where an `atexit` hook fades every live device.
//! The speakers then do not click on the step from or to silence. The fade
//! is applied after the render, at the device only. The output of the
//! [Render] is unchanged.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, StreamConfig, SupportedBufferSize};

/// The source that fills the buffers of the device, on the thread of the
/// device.
pub trait Render: Send + 'static {
    /// Fills [out] with interleaved stereo frames.
    fn render(&mut self, out: &mut [f32]);
}

/// The reason that the device did not start, a negative code and the
/// message of the platform.
pub struct StartError {
    pub code: i32,
    pub message: String,
}

fn fail(code: i32, message: impl std::fmt::Display) -> StartError {
    StartError {
        code,
        message: message.to_string(),
    }
}

/// The length of the declick fade, 10 ms at 48 kHz.
pub const RAMP_FRAMES: u32 = 480;

/// The time that a stop waits for the fade-out before it lets the stream go
/// anyway. A device that stopped calling back does not finish the fade.
const FADE_WAIT: Duration = Duration::from_millis(100);

/// The fade state of a device, shared between its callback and the code
/// that stops it.
struct Gate {
    /// Set to fade out. The callback then renders down to silence.
    closing: AtomicBool,
    /// Set by the callback once the output is silent after [closing].
    silent: AtomicBool,
}

impl Gate {
    /// Asks for the fade-out and waits, bounded, until it is done.
    fn fade_out(&self) {
        self.closing.store(true, Ordering::Release);
        let t = Instant::now();
        while !self.silent.load(Ordering::Acquire) && t.elapsed() < FADE_WAIT {
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

/// The output gain of the declick fade, stepped per frame toward 1 while
/// playing and toward 0 once closing.
pub struct Declick {
    gain: f32,
}

impl Declick {
    pub fn new() -> Declick {
        Declick { gain: 0.0 }
    }

    /// Returns true when the output is silent for good, closing and fully
    /// faded.
    pub fn silent(&self, closing: bool) -> bool {
        closing && self.gain == 0.0
    }

    /// Scales the interleaved stereo [out] by the fade. Returns true once it
    /// is [closing] and the gain has reached 0.
    pub fn apply(&mut self, out: &mut [f32], closing: bool) -> bool {
        let target = if closing { 0.0 } else { 1.0 };
        if self.gain == target {
            if closing {
                out.fill(0.0);
            }
            return closing;
        }
        let step = 1.0 / RAMP_FRAMES as f32;
        for frame in out.chunks_exact_mut(2) {
            self.gain = if closing {
                (self.gain - step).max(0.0)
            } else {
                (self.gain + step).min(1.0)
            };
            frame[0] *= self.gain;
            frame[1] *= self.gain;
        }
        self.silent(closing)
    }
}

impl Default for Declick {
    fn default() -> Self {
        Declick::new()
    }
}

/// The gate of every running device, for the exit hook.
static LIVE: Mutex<Vec<Arc<Gate>>> = Mutex::new(Vec::new());
static EXIT_HOOK: Once = Once::new();

extern "C" {
    fn atexit(f: extern "C" fn()) -> std::os::raw::c_int;
}

/// Fades every live device to silence at process exit, where no device is
/// dropped. The streams play silence until the end of the process.
extern "C" fn fade_all_at_exit() {
    let live: Vec<Arc<Gate>> = LIVE.lock().unwrap_or_else(|e| e.into_inner()).clone();
    for g in &live {
        g.closing.store(true, Ordering::Release);
    }
    for g in &live {
        g.fade_out();
    }
}

pub struct Device {
    /// Plays while it exists. Dropping it fades out, then stops the callback
    /// and frees the renderer.
    stream: Option<cpal::Stream>,
    gate: Arc<Gate>,
}

impl Device {
    /// Starts the default output with [render] and asks for buffers of
    /// [period] frames when the device allows it.
    pub fn start<R: Render>(mut render: Box<R>, period: u32) -> Result<Device, StartError> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| fail(-1, "no default output device"))?;
        // The buffer as asked when the range of the device holds it, else the
        // own buffer of the device. The render takes any length.
        let fits = device.supported_output_configs().is_ok_and(|mut cs| {
            cs.any(|c| {
                c.channels() == 2
                    && matches!(c.buffer_size(), SupportedBufferSize::Range { min, max } if (*min..=*max).contains(&period))
            })
        });
        let config = StreamConfig {
            channels: 2,
            sample_rate: 48000,
            buffer_size: if fits {
                BufferSize::Fixed(period)
            } else {
                BufferSize::Default
            },
        };
        let gate = Arc::new(Gate {
            closing: AtomicBool::new(false),
            silent: AtomicBool::new(false),
        });
        let cb_gate = gate.clone();
        let mut declick = Declick::new();
        let stream = device
            .build_output_stream::<f32, _, _>(
                config,
                move |out: &mut [f32], _| {
                    let closing = cb_gate.closing.load(Ordering::Acquire);
                    // Faded out. The output is silence and the renderer is
                    // left alone.
                    if declick.silent(closing) {
                        out.fill(0.0);
                        return;
                    }
                    render.render(out);
                    if declick.apply(out, closing) {
                        cb_gate.silent.store(true, Ordering::Release);
                    }
                },
                // A device lost while playing gives silence until the device
                // is made again. This thread cannot recover it.
                |_| {},
                None,
            )
            .map_err(|e| fail(-5, e))?;
        stream.play().map_err(|e| fail(-6, e))?;
        EXIT_HOOK.call_once(|| {
            // SAFETY: atexit of the C library only records the function
            // pointer, a plain extern "C" fn without arguments that exists
            // for the whole program.
            unsafe { atexit(fade_all_at_exit) };
        });
        LIVE.lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(gate.clone());
        Ok(Device {
            stream: Some(stream),
            gate,
        })
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        self.gate.fade_out();
        LIVE.lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|g| !Arc::ptr_eq(g, &self.gate));
        drop(self.stream.take());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fades_in_over_the_ramp_then_passes_through() {
        let mut d = Declick::new();
        let mut out = vec![1.0f32; 2 * 1024];
        assert!(!d.apply(&mut out, false));
        assert_eq!(out[0], 1.0 / RAMP_FRAMES as f32);
        assert!(out[1] == out[0]);
        let last_ramp = 2 * (RAMP_FRAMES as usize - 1);
        assert_eq!(out[last_ramp], 1.0);
        assert!(out[2 * 600..].iter().all(|&s| s == 1.0));
        // Fully open, the next buffer is untouched.
        let mut next = vec![0.25f32; 64];
        assert!(!d.apply(&mut next, false));
        assert!(next.iter().all(|&s| s == 0.25));
    }

    #[test]
    fn fades_out_to_silence_and_reports_it() {
        let mut d = Declick::new();
        let mut warm = vec![1.0f32; 2 * 1024];
        d.apply(&mut warm, false);
        let mut out = vec![1.0f32; 2 * 256];
        assert!(!d.apply(&mut out, true));
        assert!(out[0] < 1.0 && out[0] > 0.99);
        assert!(out
            .chunks_exact(2)
            .collect::<Vec<_>>()
            .windows(2)
            .all(|w| w[0][0] >= w[1][0]));
        let mut rest = vec![1.0f32; 2 * 256];
        assert!(d.apply(&mut rest, true));
        assert!(rest[2 * 230..].iter().all(|&s| s == 0.0));
        assert!(d.silent(true));
        // Silent for good, later buffers are zeroed.
        let mut after = vec![0.5f32; 16];
        assert!(d.apply(&mut after, true));
        assert!(after.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn a_stop_before_the_fade_in_ends_fades_from_where_it_was() {
        let mut d = Declick::new();
        let mut out = vec![1.0f32; 2 * 100];
        d.apply(&mut out, false);
        let at = out[2 * 99];
        let mut down = vec![1.0f32; 2 * 200];
        assert!(d.apply(&mut down, true));
        assert!(down[0] < at);
        assert!(down[2 * 150..].iter().all(|&s| s == 0.0));
    }
}
