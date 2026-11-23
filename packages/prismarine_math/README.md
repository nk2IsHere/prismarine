# prismarine_math

prismarine_math gives `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log` and `pow` with the same bits on
every OS and CPU. The functions of `dart:math` call the C library of the platform. These libraries give different bits
for the same input on Apple arm64, Apple x86-64, glibc and the MSVC runtime. Use this package for every value that must
match across machines, such as the state of a simulation that a recording replays. The details are on [the area
page](../../docs/areas/math.md).

## Usage

`package:prismarine_math/libm.dart` is a line-for-line Dart port of the Rust `libm` crate. Import it with a prefix, such
as `libm`, to keep its functions apart from those of `dart:math`. Native code that uses the Rust crate gets the same
bits as the Dart port.

`package:prismarine_math/clamp.dart` has `clampDouble`. It clamps a double with the answers of `num.clamp` but returns a
`double` and does not box the result.

## Example

The example turns an angle into a point and a level in decibels into a gain. It is
[`example/example.dart`](example/example.dart):

```dart
import 'package:prismarine_math/clamp.dart';
import 'package:prismarine_math/libm.dart' as libm;

void main() {
  // The same bits on macOS, Linux and Windows, on arm64 and x86-64.
  final angle = libm.atan2(1, 2);
  final x = libm.cos(angle) * 10, y = libm.sin(angle) * 10;
  final gain = clampDouble(libm.pow(10, -6 / 20), 0, 1);
  print('$x $y $gain');
}
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, on arm64 and x86-64, with the same bits on each.
