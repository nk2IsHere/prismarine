/// `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log` and
/// `pow` with the same bits on every platform. The code is a line-for-line
/// port of the Rust `libm` crate 0.2.16. Native code that uses this crate
/// computes the same bits.
///
/// Use these functions in place of dart:math wherever a result must be the
/// same on every platform. The results of dart:math come from the C library
/// of the platform and differ between platforms. The `sqrt` of dart:math is
/// exact on every platform.
library;

import 'dart:math' as math;
import 'dart:typed_data';

part 'src/libm/bits.dart';
part 'src/libm/trig.dart';
part 'src/libm/rem_pio2.dart';
part 'src/libm/exp_log.dart';
part 'src/libm/pow.dart';
part 'src/libm/atrig.dart';
