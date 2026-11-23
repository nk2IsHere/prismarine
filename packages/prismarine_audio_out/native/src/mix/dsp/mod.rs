//! FMOD's built-in DSPs as mcsm_audio rebuilt them (lib/src/mixer/dsp*.dart,
//! biquad.dart), operation for operation.

use crate::mix::dmath::*;

mod eq;
mod filters;
mod process;
mod process51;
mod reverb;
#[cfg(test)]
mod tests;

use eq::*;
use filters::*;
use reverb::*;

pub const LOWPASS: i32 = 0;
pub const HIGHPASS: i32 = 1;
pub const ECHO: i32 = 2;
pub const FLANGE: i32 = 3;
pub const DISTORTION: i32 = 4;
pub const PARAMEQ: i32 = 5;
pub const LIMITER: i32 = 6;
pub const COMPRESSOR: i32 = 7;
pub const REVERB: i32 = 8;
pub const TREMOLO: i32 = 9;
pub const PAN: i32 = 10;
pub const THREEEQ: i32 = 11;
pub const CHORUS: i32 = 12;
pub const MBEQ: i32 = 13;
pub const CHANMIX: i32 = 14;
pub const OBJPAN: i32 = 15;

enum State {
    Lowpass([Biquad; 2]),
    ThreeEq {
        low: [Biquad; 2],
        mid: [Biquad; 4],
        high: [Biquad; 2],
    },
    One(Biquad),
    Distortion,
    /// The source's direction (degrees) and distance (the event's 3D
    /// attributes relative to the listener).
    Pan {
        az: f64,
        dist: f64,
    },
    Compressor {
        use_sidechain: bool,
        env: f64,
        gr: f64,
        /// Unlinked (FMOD 1.09): each channel's follower and reduction.
        envs: [f64; 6],
        grs: [f64; 6],
    },
    Limiter {
        g: [f64; 6],
        fresh: bool,
    },
    Tremolo {
        t: f64,
    },
    Echo {
        line: Line,
        d: i64,
        quiet: i64,
    },
    Flange {
        line: Line,
        phase: f64,
        quiet: i64,
    },
    Chorus(Box<crate::mix::chorus::Chorus>),
    Reverb(Box<Reverb>),
    Eq(Box<[EqBand; 5]>),
    Mix(Box<Mix>),
    /// The object panner: silent on an output without objects (ObjectPan).
    Silence,
}

pub struct Dsp {
    pub kind: i32,
    pub p: Vec<f64>,
    st: State,
    /// The twins that run a per-channel DSP's other two channel pairs of a
    /// 5.1 buffer (Dart `Dsp.processPairs51`), built with a 5.1 strip.
    twins: Option<Box<[Dsp; 2]>>,
    /// The pair buffer [twins] run in.
    pair: Vec<f32>,
    /// FMOD 1.09's lowpass: no bypass at 22000 Hz (Dart `Lowpass.keep22k`).
    pub keep22k: bool,
}

const D_LOWPASS: &[f64] = &[5000.0, 1.0];
const D_HIGHPASS: &[f64] = &[5000.0, 1.0];
const D_ECHO: &[f64] = &[500.0, 50.0, 0.0, 0.0];
const D_FLANGE: &[f64] = &[50.0, 1.0, 0.1];
const D_DISTORTION: &[f64] = &[0.5];
const D_PARAMEQ: &[f64] = &[8000.0, 1.0, 0.0];
const D_LIMITER: &[f64] = &[10.0, 0.0, 0.0, 0.0];
const D_COMP: &[f64] = &[0.0, 2.5, 20.0, 100.0, 0.0, 0.0, 1.0];
const D_REVERB: &[f64] = &[
    1500.0, 20.0, 40.0, 5000.0, 50.0, 100.0, 100.0, 250.0, 0.0, 20000.0, 50.0, -6.0, 0.0,
];
const D_TREMOLO: &[f64] = &[5.0, 1.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0];
const D_PAN: &[f64] = &[
    1.0, 0.0, 0.0, 360.0, 0.0, 0.0, 1.0, 60.0, 0.0, 255.0, 0.0, 0.0, 1.0, 20.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 3.0,
];
const D_EQ3: &[f64] = &[0.0, 0.0, 0.0, 400.0, 4000.0, 1.0];
const D_OBJPAN: &[f64] = &[0.0, 0.0, 1.0, 20.0, 0.0, 0.0, 0.0, 0.0, 1.0];

/// A DSP kind's parameter defaults; None for a kind the mixer doesn't have.
fn defaults(kind: i32) -> Option<&'static [f64]> {
    Some(match kind {
        LOWPASS => D_LOWPASS,
        HIGHPASS => D_HIGHPASS,
        PARAMEQ => D_PARAMEQ,
        ECHO => D_ECHO,
        FLANGE => D_FLANGE,
        DISTORTION => D_DISTORTION,
        LIMITER => D_LIMITER,
        COMPRESSOR => D_COMP,
        REVERB => D_REVERB,
        TREMOLO => D_TREMOLO,
        PAN => D_PAN,
        THREEEQ => D_EQ3,
        CHORUS => crate::mix::chorus::DEFAULTS,
        MBEQ => D_MBEQ,
        CHANMIX => D_MIX,
        OBJPAN => D_OBJPAN,
        _ => return None,
    })
}

/// Compressors' sidechain keys (MixerGraph.sidechain): each compressor's
/// key is a buffer of [pool] or none. As in Dart, one tap hands the same
/// buffer to every target that has none yet, so a later tap adds into a
/// shared buffer once per target.
#[derive(Default)]
pub struct Keys {
    pub slot: Vec<Option<usize>>,
    pub pool: Vec<Vec<f32>>,
}

impl Keys {
    /// [slots] keys, each with a buffer of [len] floats ready (a key holds
    /// one buffer at most, so one per key is always enough).
    pub fn with(slots: usize, len: usize) -> Keys {
        Keys {
            slot: vec![None; slots],
            pool: (0..slots).map(|_| Vec::with_capacity(len)).collect(),
        }
    }

    /// A buffer no key holds, holding [buf]; None when the pool has no free
    /// buffer of that size (never with [Keys::with]'s pool).
    pub fn alloc(&mut self, buf: &[f32]) -> Option<usize> {
        let i = (0..self.pool.len()).find(|i| !self.slot.contains(&Some(*i)))?;
        if buf.len() > self.pool[i].capacity() {
            return None;
        }
        self.pool[i].clear();
        self.pool[i].extend_from_slice(buf);
        Some(i)
    }
}

impl Dsp {
    /// A PAN DSP's source position relative to the listener.
    pub fn set_spatial(&mut self, azimuth: f64, distance: f64) {
        if let State::Pan { az, dist } = &mut self.st {
            *az = azimuth;
            *dist = distance;
        }
    }

    /// The DSP of [kind], built with all the memory it will use: an echo
    /// delays up to [echo_frames] frames.
    pub fn new(kind: i32, taps: &'static [f64], echo_frames: i64) -> Option<Dsp> {
        let st = match kind {
            ECHO => State::Echo {
                line: Line::with_room(echo_frames),
                d: 1,
                quiet: 1 << 30,
            },
            FLANGE => State::Flange {
                line: Line::with_room(960 + 2),
                phase: 0.0,
                quiet: 1 << 30,
            },
            CHORUS => State::Chorus(Box::new(crate::mix::chorus::Chorus::new(
                crate::mix::chorus::DEFAULTS,
            ))),
            REVERB => State::Reverb(Box::new(Reverb {
                pre: vec![0.0; RV_PRE],
                pre_pos: 0,
                diff: RV_DIFF.map(|n| vec![0.0; n]),
                diff_pos: [0; 4],
                line: RV_BASE.map(|n| vec![0.0; (n as f64 * 1.2).ceil() as usize + 1]),
                line_pos: [0; RV_LINES],
                line_len: [0; RV_LINES],
                gain: [0.0; RV_LINES],
                damp: [0.0; RV_LINES],
                lp: [0.0; RV_LINES],
                shelf: Shelf::default(),
                cut_state: [0.0; 6],
                cut_a: 1.0,
                late_norm: 1.0,
                early_norm: 1.0,
                taps,
            })),
            MBEQ => State::Eq(Box::new([EqBand::new(); 5])),
            CHANMIX => State::Mix(Box::new(Mix::new())),
            OBJPAN => State::Silence,
            _ => State::Distortion,
        };
        let dflt = defaults(kind)?;
        let mut d = Dsp {
            kind,
            p: dflt.to_vec(),
            st,
            twins: None,
            pair: Vec::new(),
            keep22k: false,
        };
        d.reset();
        Some(d)
    }

    /// As new (Dart's constructor), in the memory it has.
    pub fn reset(&mut self) {
        let Some(dflt) = defaults(self.kind) else {
            return;
        };
        self.p.copy_from_slice(dflt);
        match &mut self.st {
            State::Echo { line, d, quiet } => {
                line.reset();
                *d = 1;
                *quiet = 1 << 30;
            }
            State::Flange { line, phase, quiet } => {
                line.reset();
                line.size(960 + 2);
                *phase = 0.0;
                *quiet = 1 << 30;
            }
            State::Chorus(c) => c.renew(dflt),
            State::Eq(bands) => {
                for (b, band) in bands.iter_mut().enumerate() {
                    *band = EqBand::new();
                    band.design(dflt, b);
                    band.settle();
                }
            }
            State::Mix(m) => m.start(dflt),
            State::Reverb(r) => {
                r.pre.fill(0.0);
                r.pre_pos = 0;
                for b in r.diff.iter_mut().chain(r.line.iter_mut()) {
                    b.fill(0.0);
                }
                r.diff_pos = [0; 4];
                r.line_pos = [0; RV_LINES];
                r.line_len = [0; RV_LINES];
                r.gain = [0.0; RV_LINES];
                r.damp = [0.0; RV_LINES];
                r.lp = [0.0; RV_LINES];
                r.shelf = Shelf::default();
                r.cut_state = [0.0; 6];
                r.cut_a = 1.0;
                r.late_norm = 1.0;
                r.early_norm = 1.0;
            }
            st => {
                *st = match self.kind {
                    LOWPASS => State::Lowpass([Biquad::new(); 2]),
                    HIGHPASS | PARAMEQ => State::One(Biquad::new()),
                    DISTORTION => State::Distortion,
                    LIMITER => State::Limiter {
                        g: [1.0; 6],
                        fresh: true,
                    },
                    COMPRESSOR => State::Compressor {
                        use_sidechain: false,
                        env: 0.0,
                        gr: 0.0,
                        envs: [0.0; 6],
                        grs: [0.0; 6],
                    },
                    TREMOLO => State::Tremolo { t: 0.0 },
                    PAN => State::Pan { az: 0.0, dist: 0.0 },
                    OBJPAN => State::Silence,
                    _ => State::ThreeEq {
                        low: [Biquad::new(); 2],
                        mid: [Biquad::new(); 4],
                        high: [Biquad::new(); 2],
                    },
                }
            }
        }
        match self.kind {
            LOWPASS | THREEEQ | HIGHPASS | PARAMEQ | ECHO | REVERB => self.changed(0),
            LIMITER => {
                let g = db_gain(self.p[1]);
                if let State::Limiter { g: gg, .. } = &mut self.st {
                    *gg = [g; 6];
                }
            }
            _ => {}
        }
        if let Some(t) = self.twins.as_mut() {
            for d in t.iter_mut() {
                d.reset();
            }
        }
    }

    /// The stored parameters are set (Dart `Dsp.start`): a DSP that glides
    /// to new parameters starts at these.
    pub fn start(&mut self) {
        match &mut self.st {
            State::Eq(bands) => {
                for b in bands.iter_mut() {
                    b.settle();
                }
            }
            State::Mix(m) => m.start(&self.p),
            _ => {}
        }
    }

    /// An echo was asked for a longer delay than it was built for (once;
    /// the delay line stays as it was).
    pub fn take_refused(&mut self) -> bool {
        match &mut self.st {
            State::Echo { line, .. } => std::mem::take(&mut line.refused),
            _ => false,
        }
    }

    pub fn nparams(&self) -> usize {
        self.p.len()
    }

    pub fn set(&mut self, index: usize, value: f64) {
        if index >= self.p.len() {
            return;
        }
        if self.p[index] == value {
            return;
        }
        self.p[index] = value;
        self.changed(index);
    }

    fn changed(&mut self, index: usize) {
        let p = &self.p;
        match &mut self.st {
            State::Lowpass(s) => {
                for (k, b) in s.iter_mut().enumerate() {
                    b.set(p[0], butterworth4(k) * p[1], false);
                }
            }
            State::ThreeEq { low, mid, high } => {
                let q = 1.0 / SQRT2;
                for b in low.iter_mut() {
                    b.set(p[3], q, false);
                }
                mid[0].set(p[3], q, true);
                mid[1].set(p[3], q, true);
                mid[2].set(p[4], q, false);
                mid[3].set(p[4], q, false);
                for b in high.iter_mut() {
                    b.set(p[4], q, true);
                }
            }
            State::One(b) => {
                if self.kind == HIGHPASS {
                    b.set(p[0], dmax(p[1], 0.01), true);
                } else {
                    b.peaking(p[0], p[1], p[2]);
                }
            }
            State::Limiter { g, fresh } => {
                if index == 1 && *fresh {
                    *g = [db_gain(p[1]); 6];
                }
            }
            State::Eq(bands) => bands[index / 4].design(p, index / 4),
            State::Mix(m) => m.changed(p, index),
            State::Echo { line, d, .. } => {
                if index == 0 {
                    *d = line.size(dround(p[0] * RATE_F / 1000.0).max(1));
                }
            }
            State::Reverb(r) => rv_update(r, p),
            _ => {}
        }
    }

    pub fn use_sidechain(&self) -> bool {
        matches!(
            self.st,
            State::Compressor {
                use_sidechain: true,
                ..
            }
        )
    }
    pub fn set_use_sidechain(&mut self, on: bool) {
        if let State::Compressor { use_sidechain, .. } = &mut self.st {
            *use_sidechain = on;
        }
    }
    pub fn is_compressor(&self) -> bool {
        self.kind == COMPRESSOR
    }

    /// Sound held inside that silence would bring out.
    pub fn ringing(&self) -> bool {
        match &self.st {
            State::Echo { d, quiet, .. } => quiet < d,
            State::Flange { quiet, .. } => *quiet < 960 + 2,
            State::Chorus(c) => c.ringing(),
            _ => false,
        }
    }

    /// [frames] of silence went by unprocessed. [keyed]: a compressor has a
    /// sidechain key. True when a compressor's key is to be dropped.
    pub fn idle(&mut self, frames: i64, keyed: bool) -> bool {
        let p = &self.p;
        match &mut self.st {
            State::Compressor {
                use_sidechain,
                env,
                gr,
                ..
            } => {
                if *use_sidechain && keyed {
                    return false;
                }
                *env *= dpow(1.0 - one_pole(p[3] / 2.0), frames as f64);
                *gr *= dpow(1.0 - comp_smooth(), frames as f64);
                return true;
            }
            State::Limiter { g, fresh } => {
                *fresh = false;
                let up = exp(frames as f64 / (dmax(p[0], 0.01) * 1e-3 * RATE_F));
                for gg in g.iter_mut() {
                    *gg = dmin(1.0, *gg * up);
                }
            }
            State::Tremolo { t } => *t += frames as f64 / RATE_F,
            State::Echo { quiet, .. } => *quiet += frames,
            State::Chorus(c) => c.idle(p, frames),
            State::Flange { quiet, phase, .. } => {
                *quiet += frames;
                let inc = (p[2] / RATE_F) as f32 as f64;
                let mut ph = *phase;
                for _ in 0..frames {
                    ph = (ph + inc) as f32 as f64;
                    if ph >= 1.0 {
                        ph = (ph - 1.0) as f32 as f64;
                    }
                }
                *phase = ph;
            }
            _ => {}
        }
        false
    }
}
