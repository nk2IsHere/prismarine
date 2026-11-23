//! Dart's double semantics where they differ from Rust's (the Dart VM's
//! `pow` fast paths, `clamp`, `min`/`max`, `%`), so the mixer computes the
//! same bits as mcsm_audio's Dart code. Rust never fuses multiply-adds and
//! has no fast-math. `sin`, `cos`, `exp`, `log` and `pow` are the `libm`
//! crate's (musl's fdlibm code), not the platform's C library, so every
//! target computes the same bits; prismarine_math's lib/libm.dart is the same
//! code in Dart. clippy.toml
//! forbids f64's own `sin`/`cos`/`exp`/`ln`/`powf` and the rest of the
//! platform maths in this crate.

pub const RATE: i64 = 48000;
pub const RATE_F: f64 = 48000.0;
/// math.sqrt1_2 (Dart's constants are the same doubles as Rust's).
pub const UPMIX: f64 = std::f64::consts::FRAC_1_SQRT_2;
pub const LN10: f64 = std::f64::consts::LN_10;
pub const PI: f64 = std::f64::consts::PI;
pub const SQRT2: f64 = std::f64::consts::SQRT_2;

pub use libm::{cos, exp, log, sin};

/// The Dart VM's double pow: its inlined fast paths, then libm's pow (as
/// mcsm_audio's `dpow`).
#[inline]
pub fn dpow(b: f64, e: f64) -> f64 {
    if e == 0.0 {
        return 1.0;
    }
    if !e.is_nan() {
        if e == 1.0 {
            return b;
        }
        if e == 2.0 {
            return b * b;
        }
        if e == 3.0 {
            return b * b * b;
        }
    }
    if b.is_nan() {
        return f64::NAN;
    }
    if b == 1.0 {
        return 1.0;
    }
    if e.is_nan() {
        return f64::NAN;
    }
    if b != f64::NEG_INFINITY && e == 0.5 {
        if b == 0.0 {
            return 0.0;
        }
        return b.sqrt();
    }
    libm::pow(b, e)
}

/// double.compareTo.
#[inline]
pub fn dcompare(a: f64, b: f64) -> i32 {
    if a < b {
        return -1;
    }
    if a > b {
        return 1;
    }
    if a == b {
        if a == 0.0 {
            let (an, bn) = (a.is_sign_negative(), b.is_sign_negative());
            if an != bn {
                return if an { -1 } else { 1 };
            }
        }
        return 0;
    }
    if a.is_nan() {
        return if b.is_nan() { 0 } else { 1 };
    }
    -1
}

/// num.clamp on a double.
#[inline]
pub fn dclamp(x: f64, lo: f64, hi: f64) -> f64 {
    if lo.is_nan() {
        return lo;
    }
    if x < lo {
        return lo;
    }
    if dcompare(x, hi) > 0 {
        return hi;
    }
    x
}

/// dart:math max.
#[inline]
pub fn dmax(a: f64, b: f64) -> f64 {
    if a > b {
        return a;
    }
    if a < b {
        return b;
    }
    if a == 0.0 && b == 0.0 {
        return if a.is_sign_negative() { b } else { a };
    }
    if b.is_nan() {
        return b;
    }
    a
}

/// dart:math min.
#[inline]
pub fn dmin(a: f64, b: f64) -> f64 {
    if a > b {
        return b;
    }
    if a < b {
        return a;
    }
    if a == 0.0 && b == 0.0 {
        return if a.is_sign_negative() { a } else { b };
    }
    if b.is_nan() {
        return b;
    }
    a
}

/// double % double (the VM's DartModulo).
#[inline]
pub fn dmod(a: f64, b: f64) -> f64 {
    let mut r = a % b;
    if r == 0.0 {
        return 0.0;
    }
    if r < 0.0 {
        r = if b < 0.0 { r - b } else { r + b };
    }
    r
}

/// int % int (Euclidean, as Dart's).
#[inline]
pub fn imod(a: i64, b: i64) -> i64 {
    let r = a % b;
    if r < 0 {
        r + b.abs()
    } else {
        r
    }
}

#[inline]
pub fn dround(x: f64) -> i64 {
    x.round() as i64
}
#[inline]
pub fn dfloor(x: f64) -> i64 {
    x.floor() as i64
}
#[inline]
pub fn dceil(x: f64) -> i64 {
    x.ceil() as i64
}

/// dbGain / dbToGain: −80 dB and below is silence.
#[inline]
pub fn db_gain(db: f64) -> f64 {
    if db <= -80.0 {
        0.0
    } else {
        dpow(10.0, db / 20.0)
    }
}

/// onePole(ms).
#[inline]
pub fn one_pole(ms: f64) -> f64 {
    if ms <= 0.0 {
        1.0
    } else {
        1.0 - exp(-1.0 / (ms * 1e-3 * RATE_F))
    }
}

/// A value the optimizer can't see, so a maths call on a constant runs at
/// run time (as Dart's does) rather than being folded at compile time.
#[inline]
pub fn opaque(x: f64) -> f64 {
    std::hint::black_box(x)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The checksum prismarine_math's test/libm_test.dart computes over the same
    /// inputs with lib/libm.dart: the two must stay bit-identical, on
    /// every platform.
    pub const LIBM_SWEEP: u64 = 0x06f9_0047_c6d9_745b;

    fn fnv(h: &mut u64, v: f64) {
        // NaN's bits depend on the CPU (x86 and ARM make different default
        // NaNs): every NaN counts as one.
        let b = if v.is_nan() {
            0x7ff8_0000_0000_0000
        } else {
            v.to_bits()
        };
        for byte in b.to_le_bytes() {
            *h ^= byte as u64;
            *h = h.wrapping_mul(0x100000001b3);
        }
    }

    /// xorshift64*: the sweep's inputs (libm_test.dart has the same).
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545F4914F6CDD1D)
        }
        /// Any double (every exponent, NaN and infinities too).
        fn any(&mut self) -> f64 {
            f64::from_bits(self.next())
        }
        /// Uniform in [lo, hi).
        fn range(&mut self, lo: f64, hi: f64) -> f64 {
            lo + (hi - lo) * ((self.next() >> 11) as f64 / (1u64 << 53) as f64)
        }
    }

    pub fn sweep() -> u64 {
        let mut r = Rng(0x9E37_79B9_7F4A_7C15);
        let mut h = 0xcbf29ce484222325u64;
        let n = 100_000;
        for _ in 0..n {
            let x = r.any();
            for v in [sin(x), cos(x), exp(x), log(x)] {
                fnv(&mut h, v);
            }
            let y = r.any();
            fnv(&mut h, libm::pow(x, y));
            fnv(&mut h, libm::atan2(x, y));
        }
        for _ in 0..n {
            let a = r.range(-10.0, 10.0);
            let w = r.range(-1e6, 1e6);
            for v in [
                sin(a),
                cos(a),
                sin(w),
                cos(w),
                exp(a * 70.0),
                log(a.abs()),
                log(w.abs()),
            ] {
                fnv(&mut h, v);
            }
            let b = r.range(0.0, 100.0);
            let e = r.range(-40.0, 40.0);
            fnv(&mut h, dpow(b, e));
            fnv(&mut h, dpow(10.0, e));
            fnv(&mut h, dpow(-b, e.round()));
            fnv(&mut h, libm::atan2(a, r.range(-10.0, 10.0)));
        }
        h
    }

    /// The checksum of prismarine_math's test/libm_test.dart over the functions
    /// only the game simulation uses (tan, asin, acos, atan): the mixer
    /// doesn't call them, but the libm crate is the reference for both.
    pub const SIM_SWEEP: u64 = 0xaa1d_d63e_80aa_a7f4;

    pub fn sim_sweep() -> u64 {
        let mut r = Rng(0xD1B5_4A32_D192_ED03);
        let mut h = 0xcbf29ce484222325u64;
        for _ in 0..100_000 {
            let x = r.any();
            for v in [libm::tan(x), libm::asin(x), libm::acos(x), libm::atan(x)] {
                fnv(&mut h, v);
            }
            let a = r.range(-10.0, 10.0);
            let w = r.range(-1e6, 1e6);
            let u = r.range(-1.1, 1.1);
            for v in [
                libm::tan(a),
                libm::tan(w),
                libm::asin(u),
                libm::acos(u),
                libm::atan(a),
                libm::atan(w),
            ] {
                fnv(&mut h, v);
            }
        }
        h
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn sim_sweep_is_stable() {
        assert_eq!(sim_sweep(), SIM_SWEEP, "{:016x}", sim_sweep());
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn libm_sweep_is_stable() {
        assert_eq!(sweep(), LIBM_SWEEP, "{:016x}", sweep());
    }
}
