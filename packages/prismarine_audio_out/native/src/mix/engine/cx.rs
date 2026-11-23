//! What render code reaches besides its object (Cx), the random generator
//! (rng.dart), curves and parameter maps (curve.dart), and the output map.

use super::*;

/// What the render code reaches besides the object it works on.
pub struct Cx<'a> {
    pub m: &'static Model,
    pub sh: &'a Shared,
    pub(crate) seen: &'a mut [u32],
    /// The waveforms' bound sources (the render thread's own table).
    pub(crate) slots: &'a mut Vec<Option<SrcRef>>,
    /// Where voices read their sources' samples.
    pub(crate) chunk: &'a mut [f32],
    /// The last key given to a snapshot an event instrument started.
    pub(crate) snap_key: &'a mut i64,
}

impl Cx<'_> {
    pub(crate) fn problem(&mut self, args: std::fmt::Arguments) {
        struct W {
            b: [u8; PROBLEM_LEN],
            n: usize,
        }
        impl std::fmt::Write for W {
            fn write_str(&mut self, s: &str) -> std::fmt::Result {
                for &c in s.as_bytes() {
                    if self.n + 1 < PROBLEM_LEN {
                        self.b[self.n] = c;
                        self.n += 1;
                    }
                }
                Ok(())
            }
        }
        let mut w = W {
            b: [0; PROBLEM_LEN],
            n: 0,
        };
        let _ = w.write_fmt(args);
        let mut h: u32 = 2166136261;
        for &c in &w.b[..w.n] {
            h = (h ^ c as u32).wrapping_mul(16777619);
        }
        h |= 1;
        let cap = self.seen.len();
        let mut k = h as usize & (cap - 1);
        for _ in 0..cap {
            if self.seen[k] == h {
                return;
            }
            if self.seen[k] == 0 {
                self.seen[k] = h;
                break;
            }
            k = (k + 1) & (cap - 1);
        }
        let _ = self.sh.problems.push(w.b);
    }
    pub(crate) fn s(&self, id: i32) -> &'static str {
        self.m.str(id)
    }
}

macro_rules! problem {
    ($cx:expr, $($t:tt)*) => { $cx.problem(format_args!($($t)*)) };
}

// ---------------------------------------------------------------- Rng

#[derive(Clone, Copy)]
pub struct Rng(pub(crate) u32);

impl Rng {
    pub(crate) fn new(seed: i64) -> Rng {
        Rng(seed as u32)
    }
    pub(crate) fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x6d2b79f5);
        let mut t = self.0;
        t = (t ^ (t >> 15)).wrapping_mul(t | 1);
        t ^= t.wrapping_add((t ^ (t >> 7)).wrapping_mul(t | 61));
        (t ^ (t >> 14)) as f64 / 4294967296.0
    }
    pub(crate) fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next()
    }
}

// ---------------------------------------------------------------- curves

fn shape(t: f64, s: f64) -> f64 {
    let k = 7.0 * s;
    if k.abs() < 1e-6 {
        return t;
    }
    (exp(k * t) - 1.0) / (exp(k) - 1.0)
}

pub(crate) fn curve_at(c: &Curve, x: f64) -> f64 {
    let n = c.x.len();
    if n == 0 {
        return 0.0;
    }
    if x <= c.x[0] {
        return c.y[0];
    }
    if x >= c.x[n - 1] {
        return c.y[n - 1];
    }
    let mut i = 0;
    while c.x[i + 1] <= x {
        i += 1;
    }
    let (x0, y0, s) = (c.x[i], c.y[i], c.s[i]);
    let (x1, y1) = (c.x[i + 1], c.y[i + 1]);
    let t = if x1 > x0 { (x - x0) / (x1 - x0) } else { 1.0 };
    y0 + (y1 - y0) * shape(t, s)
}

pub(crate) fn map_map(m: &PMap, x: f64) -> f64 {
    let n = m.x.len();
    if n == 0 {
        return x;
    }
    if x <= m.x[0] {
        return m.y[0];
    }
    if x >= m.x[n - 1] {
        return m.y[n - 1];
    }
    let mut i = 0;
    while m.x[i + 1] <= x {
        i += 1;
    }
    let (x0, y0, x1, y1) = (m.x[i], m.y[i], m.x[i + 1], m.y[i + 1]);
    y0 + (y1 - y0) * (x - x0) / (x1 - x0)
}

pub(crate) fn map_unmap(m: &PMap, y: f64) -> f64 {
    let n = m.x.len();
    if n == 0 {
        return y;
    }
    let up = m.y[n - 1] >= m.y[0];
    for i in 0..n - 1 {
        let (x0, y0, x1, y1) = (m.x[i], m.y[i], m.x[i + 1], m.y[i + 1]);
        let inside = if up {
            y >= y0 && y <= y1
        } else {
            y <= y0 && y >= y1
        };
        if inside {
            return if y1 == y0 {
                x0
            } else {
                x0 + (x1 - x0) * (y - y0) / (y1 - y0)
            };
        }
    }
    let below = if up { y < m.y[0] } else { y > m.y[0] };
    if below {
        m.x[0]
    } else {
        m.x[n - 1]
    }
}

pub(crate) fn map_span(m: &PMap) -> f64 {
    if m.x.is_empty() {
        0.0
    } else {
        m.x[m.x.len() - 1] - m.x[0]
    }
}

pub(crate) fn mapped(p: &Prop, ui: f64) -> f64 {
    match &p.map {
        Some(m) => map_map(m, ui),
        None => ui,
    }
}

// ---------------------------------------------------------------- buffers

/// Map<key, Float32List> in insertion order, over buffers made with it;
/// clearing keeps them.
#[derive(Default)]
pub struct OutMap {
    pub(crate) e: Vec<(i32, Vec<f32>, usize)>,
    pub(crate) n: usize,
}

impl OutMap {
    /// Room for [keys] keys of up to [len] floats.
    pub(crate) fn with(keys: usize, len: usize) -> OutMap {
        OutMap {
            e: (0..keys).map(|_| (-1, vec![0.0; len], 0)).collect(),
            n: 0,
        }
    }
    pub(crate) fn clear(&mut self) {
        self.n = 0;
    }
    /// putIfAbsent(key, () => Float32List(len)); None when it has no room
    /// for another key or for [len].
    pub(crate) fn put(&mut self, key: i32, len: usize) -> Option<&mut [f32]> {
        if let Some(i) = self.e[..self.n].iter().position(|e| e.0 == key) {
            let e = &mut self.e[i];
            return Some(&mut e.1[..e.2]);
        }
        if self.n == self.e.len() || self.e[self.n].1.len() < len {
            return None;
        }
        let e = &mut self.e[self.n];
        self.n += 1;
        e.0 = key;
        e.1[..len].fill(0.0);
        e.2 = len;
        Some(&mut e.1[..len])
    }
    pub(crate) fn iter(&self) -> impl Iterator<Item = (i32, &[f32])> {
        self.e[..self.n].iter().map(|e| (e.0, &e.1[..e.2]))
    }
}
