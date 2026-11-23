/// `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log` and
/// `pow` with the same bits on every platform: a line-for-line port of the
/// Rust `libm` crate 0.2.16 (musl's fdlibm code). Native code on that crate
/// computes the same bits.
///
/// dart:math calls the platform's C maths (Apple's libm differs between
/// arm64 and x86_64, glibc and the MSVC CRT differ again), so the audio path
/// and the game simulation compute with these instead: the Dart and Rust
/// mixers stay bit-identical to each other, and the game's state, event log
/// and captures are the same bits on every target. Dart never fuses
/// multiply-adds, so each operation rounds as in the Rust code.
///
/// `dpow` is dart:math's `pow` on doubles (the VM's fast paths) with the
/// portable `pow` behind it; `sqrt` stays dart:math's (IEEE-exact
/// everywhere).
library;

import 'dart:math' as math;
import 'dart:typed_data';

part 'src/libm/bits.dart';
part 'src/libm/trig.dart';
part 'src/libm/rem_pio2.dart';
part 'src/libm/exp_log.dart';
part 'src/libm/pow.dart';
part 'src/libm/atrig.dart';
