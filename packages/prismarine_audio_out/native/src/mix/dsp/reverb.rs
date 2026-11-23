//! The reverb, its delay network, decay and damping.

use super::*;

pub(crate) const RV_LINES: usize = 8;
pub(crate) const RV_PRE: usize = 65536;
pub(crate) const RV_BASE: [i64; RV_LINES] = [1123, 1291, 1447, 1597, 1777, 1949, 2113, 2311];
pub(crate) const RV_DIFF: [usize; 4] = [142, 107, 379, 277];

pub(crate) struct Reverb {
    pub(crate) pre: Vec<f32>,
    pub(crate) pre_pos: i64,
    pub(crate) diff: [Vec<f32>; 4],
    pub(crate) diff_pos: [usize; 4],
    pub(crate) line: [Vec<f32>; RV_LINES],
    pub(crate) line_pos: [i64; RV_LINES],
    pub(crate) line_len: [i64; RV_LINES],
    pub(crate) gain: [f64; RV_LINES],
    pub(crate) damp: [f64; RV_LINES],
    pub(crate) lp: [f64; RV_LINES],
    pub(crate) shelf: Shelf,
    pub(crate) cut_state: [f64; 6],
    pub(crate) cut_a: f64,
    pub(crate) late_norm: f64,
    pub(crate) early_norm: f64,
    pub(crate) taps: &'static [f64],
}

fn rv_excess(t60: f64) -> f64 {
    const PX: [f64; 5] = [0.17, 0.5, 1.5, 3.0, 6.0];
    const PY: [f64; 5] = [0.2, 1.25, 2.15, 2.5, 2.75];
    let x = log(t60);
    if x <= log(opaque(PX[0])) {
        return PY[0];
    }
    for i in 1..5 {
        let x1 = log(opaque(PX[i]));
        if x <= x1 {
            let x0 = log(opaque(PX[i - 1]));
            return PY[i - 1] + (PY[i] - PY[i - 1]) * (x - x0) / (x1 - x0);
        }
    }
    PY[4]
}

fn rv_solve_damp(rho: f64, w: f64) -> f64 {
    if rho >= 0.9999 {
        return 0.0;
    }
    let c0 = cos(w);
    let r2 = rho * rho;
    let a = r2 - 1.0;
    let b = 2.0 - 2.0 * r2 * c0;
    let c = r2 - 1.0;
    let disc = b * b - 4.0 * a * c;
    if disc < 0.0 || a == 0.0 {
        return 0.0;
    }
    let d1 = (-b + disc.sqrt()) / (2.0 * a);
    let d2 = (-b - disc.sqrt()) / (2.0 * a);
    for d in [d1, d2] {
        if (0.0..1.0).contains(&d) {
            return d;
        }
    }
    0.0
}
pub(crate) fn rv_update(r: &mut Reverb, p: &[f64]) {
    let t60 = dmax(p[0], 100.0) / 1000.0;
    let density = dclamp(p[6], 0.0, 100.0) / 100.0;
    let ratio = dclamp(p[4], 10.0, 100.0) / 100.0;
    let w = 2.0 * PI * dclamp(p[3], 20.0, 20000.0) / RATE_F;
    for (i, &base) in RV_BASE.iter().enumerate().take(RV_LINES) {
        let len = dround(base as f64 * (0.6 + 0.4 * density));
        r.line_len[i] = len;
        let g = dpow(10.0, (-3 * len) as f64 / (t60 * RATE_F));
        r.gain[i] = g;
        let g_ref = dpow(10.0, (-3 * len) as f64 / (t60 * ratio * RATE_F));
        let rho = dclamp(g_ref / g, 0.0, 1.0);
        r.damp[i] = rv_solve_damp(rho, w);
    }
    r.shelf.set(p[7], p[8]);
    r.cut_a = 1.0 - exp(-2.0 * PI * dclamp(p[9], 20.0, 20000.0) / RATE_F);
    let mut e = 0.0;
    for g in r.gain {
        e += g * g / (1.0 - g * g) / RV_LINES as f64;
    }
    let target = dpow(10.0, opaque(0.45));
    r.late_norm = (target / e).sqrt() / db_gain(rv_excess(t60));
    let mut es = 0.0;
    for k in 0..r.taps.len() / 3 {
        let gl = r.taps[k * 3 + 1];
        es += gl * gl;
    }
    r.early_norm = (target / es).sqrt();
}

pub(crate) fn rv_process(r: &mut Reverb, p: &[f64], buf: &mut [f32], frames: usize) {
    let (wet, dry) = (db_gain(p[11]), db_gain(p[12]));
    let mix = dclamp(p[10], 0.0, 100.0) / 100.0;
    let ge = cos(mix * PI / 2.0) * r.early_norm * wet;
    let gl = sin(mix * PI / 2.0) * r.late_norm * wet;
    let early = dround(dclamp(p[1], 0.0, 300.0) * RATE_F / 1000.0);
    let shortest = *r.line_len.iter().min().unwrap();
    let late = (early + dround(dclamp(p[2], 0.0, 100.0) * RATE_F / 1000.0) - shortest).max(0);
    let diffusion = 0.7 * dclamp(p[5], 0.0, 100.0) / 100.0;
    let cut = p[9] < 20000.0;
    let s = 1.0 / (RV_LINES as f64).sqrt();
    let mask = (RV_PRE - 1) as i64;
    let mut y = [0.0f64; RV_LINES];
    let ntaps = r.taps.len() / 3;
    for i in 0..frames {
        let (l0, r0) = (buf[i * 2] as f64, buf[i * 2 + 1] as f64);
        r.pre[r.pre_pos as usize] = r.shelf.tick((l0 + r0) / 2.0) as f32;
        let (mut el, mut er) = (0.0, 0.0);
        if ge != 0.0 {
            for k in 0..ntaps {
                let (t, a, b) = (r.taps[k * 3], r.taps[k * 3 + 1], r.taps[k * 3 + 2]);
                let v = r.pre[((r.pre_pos - (early + dround(t * RATE_F / 1000.0))) & mask) as usize]
                    as f64;
                el += a * v;
                er += b * v;
            }
        }
        let mut x = r.pre[((r.pre_pos - late) & mask) as usize] as f64;
        x = rv_diffuse(r, x, diffusion);
        rv_read_lines(r, &mut y);
        let (mut ll, mut lr) = (0.0, 0.0);
        for (j, yj) in y.iter().enumerate() {
            ll += (if j % 2 == 0 { 1.0 } else { -1.0 }) * yj;
            lr += (if j % 4 < 2 { 1.0 } else { -1.0 }) * yj;
        }
        let mut h = 1;
        while h < RV_LINES {
            let mut a = 0;
            while a < RV_LINES {
                for j in a..a + h {
                    let (u, v) = (y[j], y[j + h]);
                    y[j] = u + v;
                    y[j + h] = u - v;
                }
                a += h << 1;
            }
            h <<= 1;
        }
        rv_write_lines(r, &y, x, s);
        let mut wl = ge * el + gl * ll * s;
        let mut wr = ge * er + gl * lr * s;
        if cut {
            r.cut_state[0] += (wl - r.cut_state[0]) * r.cut_a;
            wl = r.cut_state[0];
            r.cut_state[1] += (wr - r.cut_state[1]) * r.cut_a;
            wr = r.cut_state[1];
        }
        buf[i * 2] = (dry * l0 + wl) as f32;
        buf[i * 2 + 1] = (dry * r0 + wr) as f32;
        r.pre_pos = (r.pre_pos + 1) & mask;
    }
}

/// Row `r` of the 8-point Hadamard matrix at column `j` (Dart `_row`).
fn rv_row(r: usize, j: usize) -> f64 {
    let mut b = r & j;
    let mut p = 1.0;
    while b != 0 {
        if b & 1 == 1 {
            p = -p;
        }
        b >>= 1;
    }
    p
}

/// The 5.1 form as Dart's `Reverb.process51`. The sum of the six channels
/// goes in, and six uncorrelated outputs at the 5.1 level come out, with dry
/// per channel.
pub(crate) fn rv_process51(r: &mut Reverb, p: &[f64], buf: &mut [f32], frames: usize) {
    let (wet, dry) = (db_gain(p[11]), db_gain(p[12]));
    if wet == 0.0 && dry == 0.0 {
        buf[..frames * 6].fill(0.0);
        return;
    }
    let wet51 = dpow(10.0, opaque(-5.2) / 20.0);
    let mix = dclamp(p[10], 0.0, 100.0) / 100.0;
    let ge = cos(mix * PI / 2.0) * r.early_norm * wet * wet51;
    let gl = sin(mix * PI / 2.0) * r.late_norm * wet * wet51;
    let early = dround(dclamp(p[1], 0.0, 300.0) * RATE_F / 1000.0);
    let shortest = *r.line_len.iter().min().unwrap();
    let late = (early + dround(dclamp(p[2], 0.0, 100.0) * RATE_F / 1000.0) - shortest).max(0);
    let diffusion = 0.7 * dclamp(p[5], 0.0, 100.0) / 100.0;
    let cut = p[9] < 20000.0;
    let s = 1.0 / (RV_LINES as f64).sqrt();
    let mask = (RV_PRE - 1) as i64;
    let mut y = [0.0f64; RV_LINES];
    let ntaps = r.taps.len() / 3;
    for i in 0..frames {
        let mut sum = 0.0;
        for v in &buf[i * 6..i * 6 + 6] {
            sum += *v as f64;
        }
        r.pre[r.pre_pos as usize] = r.shelf.tick(sum / 2.0) as f32;
        let mut e = [0.0f64; 6];
        if ge != 0.0 {
            for k in 0..ntaps {
                let (t, a, b) = (r.taps[k * 3], r.taps[k * 3 + 1], r.taps[k * 3 + 2]);
                let v = r.pre[((r.pre_pos - (early + dround(t * RATE_F / 1000.0))) & mask) as usize]
                    as f64;
                let alt = if k % 2 == 0 { v } else { -v };
                e[0] += a * v;
                e[1] += b * v;
                e[2] += a * b.signum() * v;
                e[3] += a * b.signum() * alt;
                e[4] += a * alt;
                e[5] += b * alt;
            }
        }
        let mut x = r.pre[((r.pre_pos - late) & mask) as usize] as f64;
        x = rv_diffuse(r, x, diffusion);
        rv_read_lines(r, &mut y);
        let mut l = [0.0f64; 6];
        for (j, yj) in y.iter().enumerate() {
            for (c, lc) in l.iter_mut().enumerate() {
                *lc += rv_row(c + 2, j) * yj;
            }
        }
        let mut h = 1;
        while h < RV_LINES {
            let mut a = 0;
            while a < RV_LINES {
                for j in a..a + h {
                    let (u, v) = (y[j], y[j + h]);
                    y[j] = u + v;
                    y[j + h] = u - v;
                }
                a += h << 1;
            }
            h <<= 1;
        }
        rv_write_lines(r, &y, x, s);
        for (c, o) in buf[i * 6..i * 6 + 6].iter_mut().enumerate() {
            let mut w = ge * e[c] + gl * l[c] * s;
            if cut {
                r.cut_state[c] += (w - r.cut_state[c]) * r.cut_a;
                w = r.cut_state[c];
            }
            *o = (dry * *o as f64 + w) as f32;
        }
        r.pre_pos = (r.pre_pos + 1) & mask;
    }
}

/// The four diffusers on the late input.
fn rv_diffuse(r: &mut Reverb, mut x: f64, diffusion: f64) -> f64 {
    for (k, &len) in RV_DIFF.iter().enumerate() {
        let pp = r.diff_pos[k];
        let z = r.diff[k][pp] as f64;
        let v = x + diffusion * z;
        r.diff[k][pp] = v as f32;
        x = z - diffusion * v;
        r.diff_pos[k] = (pp + 1) % len;
    }
    x
}

/// Writes the damped and decayed output of each line into `y`.
fn rv_read_lines(r: &mut Reverb, y: &mut [f64; RV_LINES]) {
    for (j, yj) in y.iter_mut().enumerate() {
        let n = r.line[j].len() as i64;
        let out = r.line[j][imod(r.line_pos[j] - r.line_len[j], n) as usize] as f64;
        r.lp[j] = (1.0 - r.damp[j]) * out + r.damp[j] * r.lp[j];
        *yj = r.lp[j] * r.gain[j];
    }
}

/// Feeds back `y` plus the input `x` with alternating signs into the lines.
fn rv_write_lines(r: &mut Reverb, y: &[f64; RV_LINES], x: f64, s: f64) {
    for (j, yj) in y.iter().enumerate() {
        let n = r.line[j].len() as i64;
        let at = imod(r.line_pos[j], n) as usize;
        r.line[j][at] = (yj * s + x * (if j % 2 == 0 { 1.0 } else { -1.0 })) as f32;
        r.line_pos[j] = imod(r.line_pos[j] + 1, n);
    }
}
