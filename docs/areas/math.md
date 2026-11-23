# prismarine_math

`libm.dart` is a line-for-line Dart port of the Rust `libm` crate 0.2.16, which is musl's fdlibm code. It gives `sin`,
`cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log` and `pow` with the same bits on every OS and CPU. The
functions of `dart:math` call the C library of the platform. Apple's arm64 and x86_64 libraries, glibc and the
MSVC runtime give different bits for the same input. Use `libm.dart` for every value that must match across machines,
such as the state of a simulation that a recording replays. Dart does not fuse multiply-adds. Each operation
rounds as in the Rust code.

`clamp.dart` has `clampDouble`, which clamps a double without the boxing of `num.clamp` and with the same answers.

Native code that uses the Rust crate gets the same bits as the Dart port. A change to the maths goes into the Dart
port and into the Rust code that mirrors it in the same change.

## Checks

Run `dart test` in `packages/prismarine_math`. The libm test runs fixed sweeps over every function and compares their
checksums with the ones a Rust test over the crate computes.
