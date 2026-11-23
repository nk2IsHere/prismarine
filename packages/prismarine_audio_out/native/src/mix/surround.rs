//! The surround panning onto 5.1 of the pan DSP in surround mode with a 5.1
//! target, as prismarine_audio's `Surround` in the same float order. The
//! channels have the order FL FR C LFE SL SR and the speakers are at −30,
//! 30, 0, −110 and 110 degrees.

use std::f64::consts::{FRAC_1_SQRT_2, PI};

use crate::mix::dmath::sin;

/// The speakers by angle with their channels, the ring of the panning.
const ANGLE: [f64; 5] = [-110.0, -30.0, 0.0, 30.0, 110.0];
const CHAN: [usize; 5] = [4, 0, 2, 1, 5];

/// The gain of C, SL and SR in the fold from 5.1 to stereo.
pub const DOWNMIX: f64 = FRAC_1_SQRT_2;

/// Adds the gains of a mono source at `direction` spread over `extent`
/// degrees, times `gain`, into `out`. The LFE gets the linear `lfe` times
/// `gain`.
pub fn mono(direction: f64, extent: f64, gain: f64, lfe: f64, out: &mut [f64; 6]) {
    out[3] += lfe * gain;
    arc(direction, extent, gain, out, true);
}

/// Adds the gains of a stereo source in distributed mode, stereo mode 0.
pub fn stereo_distributed(
    direction: f64,
    extent: f64,
    rotation: f64,
    gain: f64,
    lfe: f64,
    out_l: &mut [f64; 6],
    out_r: &mut [f64; 6],
) {
    let k = extent / 360.0;
    let rel = wrap(rotation - direction);
    if rel >= 0.0 {
        arc(direction + (rel - 90.0) * k, 180.0 * k, gain, out_l, true);
    } else {
        let mut t = [0.0; 6];
        arc(
            direction + (rel - 180.0) * 0.5 * k,
            k * (rel + 180.0),
            (rel + 180.0) / 180.0 * gain,
            &mut t,
            false,
        );
        arc(
            direction + (rel * 0.5 + 180.0) * k,
            -rel * k,
            -rel / 180.0 * gain,
            &mut t,
            false,
        );
        normalized(&t, gain, out_l);
    }
    if rel > 0.0 {
        let mut t = [0.0; 6];
        arc(
            direction + (rel * 0.5 + 90.0) * k,
            k * (180.0 - rel),
            (180.0 - rel) / 180.0 * gain,
            &mut t,
            false,
        );
        arc(
            direction + (rel * 0.5 - 180.0) * k,
            rel * k,
            rel / 180.0 * gain,
            &mut t,
            false,
        );
        normalized(&t, gain, out_r);
    } else {
        arc(direction + (rel + 90.0) * k, 180.0 * k, gain, out_r, true);
    }
    out_l[3] += lfe * gain * FRAC_1_SQRT_2;
    out_r[3] += lfe * gain * FRAC_1_SQRT_2;
}

/// Adds the gains of a stereo source in discrete mode, stereo mode 1, with
/// the channels as points at `axis` ∓ separation/2.
pub fn stereo_discrete(
    axis: f64,
    separation: f64,
    gain: f64,
    lfe: f64,
    out_l: &mut [f64; 6],
    out_r: &mut [f64; 6],
) {
    mono(
        axis - separation * 0.5,
        0.0,
        gain,
        lfe * FRAC_1_SQRT_2,
        out_l,
    );
    mono(
        axis + separation * 0.5,
        0.0,
        gain,
        lfe * FRAC_1_SQRT_2,
        out_r,
    );
}

fn arc(direction: f64, extent: f64, gain: f64, out: &mut [f64; 6], unit: bool) {
    let d = wrap(direction);
    if extent >= 360.0 {
        let g = gain / 5f64.sqrt();
        for c in CHAN {
            out[c] += g;
        }
        return;
    }
    if extent <= 0.0 {
        for p in 0..5 {
            if in_pair(p, d) {
                vbap(p, d, gain, out, unit);
                return;
            }
        }
        return;
    }
    let mut g = [0.0; 6];
    let s = wrap(d - extent * 0.5);
    for (p, &a) in ANGLE.iter().enumerate() {
        let sp = span(p);
        for shift in [-360.0, 0.0, 360.0] {
            let lo = if s + shift > a { s + shift } else { a };
            let hi = if s + shift + extent < a + sp {
                s + shift + extent
            } else {
                a + sp
            };
            if hi <= lo {
                continue;
            }
            vbap(p, wrap((lo + hi) * 0.5), (hi - lo) / sp, &mut g, true);
        }
    }
    if unit {
        normalized(&g, gain, out);
        return;
    }
    for c in 0..6 {
        out[c] += g[c] * gain;
    }
}

fn normalized(g: &[f64; 6], gain: f64, out: &mut [f64; 6]) {
    let mut sum = 0.0;
    for v in g {
        sum += v * v;
    }
    if sum == 0.0 {
        return;
    }
    let mut k = gain;
    if !(0.999999..=1.000001).contains(&sum) {
        k /= sum.sqrt();
    }
    for c in 0..6 {
        out[c] += g[c] * k;
    }
}

/// Returns `a` wrapped into [−180, 180).
pub fn wrap(mut a: f64) -> f64 {
    while a < -180.0 {
        a += 360.0;
    }
    while a >= 180.0 {
        a -= 360.0;
    }
    a
}

fn span(p: usize) -> f64 {
    let (a, b) = (ANGLE[p], ANGLE[(p + 1) % 5]);
    if b > a {
        b - a
    } else {
        b - a + 360.0
    }
}

fn in_pair(p: usize, d: f64) -> bool {
    let mut t = d - ANGLE[p];
    if t < 0.0 {
        t += 360.0;
    }
    t <= span(p)
}

fn vbap(p: usize, d: f64, w: f64, out: &mut [f64; 6], unit: bool) {
    const RAD: f64 = PI / 180.0;
    let (a, b) = (ANGLE[p], ANGLE[(p + 1) % 5]);
    let ga = sin((b - d) * RAD);
    let gb = sin((d - a) * RAD);
    let n = if unit {
        (ga * ga + gb * gb).sqrt()
    } else {
        sin((b - a) * RAD)
    };
    out[CHAN[p]] += ga / n * w;
    out[CHAN[(p + 1) % 5]] += gb / n * w;
}
