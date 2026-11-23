//! The 3D panning onto a stereo output of the pan DSP in surround mode with
//! a 3D pan blend, as prismarine_audio's `Spatial` in the same float order.

use std::f64::consts::PI;

use crate::mix::dmath::sin;

/// Returns the attenuation of rolloff `rolloff` at distance `d`.
pub fn attenuation(rolloff: i64, d: f64, min: f64, max: f64) -> f64 {
    if min >= d {
        return 1.0;
    }
    match rolloff {
        0 | 1 => {
            if d >= max {
                return 0.0;
            }
            let v = (max - d) / (max - min);
            if rolloff == 0 {
                v * v
            } else {
                v
            }
        }
        2 => min / (if max > d { d } else { max }),
        3 => {
            if d >= max {
                return 0.0;
            }
            let v = (max - d) / (max - min);
            let (lin, inv) = (v * v, min / d);
            if lin > inv {
                inv
            } else {
                lin
            }
        }
        _ => 1.0,
    }
}

/// Returns the 3D extent in degrees at distance `d`.
pub fn extent(mode: i64, d: f64, min: f64, size: f64, min_extent: f64) -> f64 {
    let from_size = |s: f64| {
        if s > 0.0 && s * 5.0 > d {
            360.0 / (d * d / (s * s) * 4.0 + 1.0)
        } else {
            0.0
        }
    };
    match mode {
        0 => from_size(min * 2.0),
        1 => {
            let e = from_size(size);
            if min_extent > e {
                min_extent
            } else {
                e
            }
        }
        _ => 0.0,
    }
}

/// Returns the left and right gains of a mono source at `direction` spread
/// over `extent`.
pub fn mono(direction: f64, extent: f64) -> (f64, f64) {
    let mut s = sin(direction * PI / 180.0);
    if extent >= 360.0 {
        s = 0.0;
    } else if extent > 0.0 {
        let h = extent * PI / 360.0;
        s *= sin(h) / h;
    }
    let g = (2.0 - s * s).sqrt();
    ((g - s) * 0.5, (g + s) * 0.5)
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

fn join(w1: f64, p1: (f64, f64), w2: f64, p2: (f64, f64)) -> (f64, f64) {
    let (l, r) = (w1 * p1.0 + w2 * p2.0, w1 * p1.1 + w2 * p2.1);
    let n = (l * l + r * r).sqrt();
    if n > 0.0 {
        (l / n, r / n)
    } else {
        (0.0, 0.0)
    }
}

/// Returns the gains of a stereo source as (L into left, L into right) and
/// (R into left, R into right).
pub fn stereo(direction: f64, extent: f64, rotation: f64) -> ((f64, f64), (f64, f64)) {
    let k = extent / 360.0;
    let rel = wrap(rotation - direction);
    let l = if rel < 0.0 {
        join(
            (rel + 180.0) / 180.0,
            mono(direction + (rel - 180.0) * 0.5 * k, k * (rel + 180.0)),
            -rel / 180.0,
            mono(direction + (rel * 0.5 + 180.0) * k, -rel * k),
        )
    } else {
        mono(direction + (rel - 90.0) * k, k * 180.0)
    };
    let r = if rel > 0.0 {
        join(
            (180.0 - rel) / 180.0,
            mono(direction + (rel + 180.0) * 0.5 * k, k * (180.0 - rel)),
            rel / 180.0,
            mono(direction + (rel * 0.5 - 180.0) * k, rel * k),
        )
    } else {
        mono(direction + (rel + 90.0) * k, k * 180.0)
    };
    (l, r)
}

/// Returns the 3D gains of the pan DSP as L into left, R into left, L into
/// right and R into right.
pub fn gains(p: &[f64], azimuth: f64, distance: f64, mono_in: bool) -> [f64; 4] {
    let (min, max) = (p[12], p[13]);
    let att = attenuation(p[11].round() as i64, distance, min, max);
    let e = extent(p[14].round() as i64, distance, min, p[15], p[16]);
    if mono_in {
        let (l, r) = mono(azimuth, e);
        [l * att, 0.0, r * att, 0.0]
    } else {
        let (sl, sr) = stereo(azimuth, e, 0.0);
        [sl.0 * att, sr.0 * att, sl.1 * att, sr.1 * att]
    }
}
