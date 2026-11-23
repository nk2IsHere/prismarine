import 'package:prismarine_math/clamp.dart';
import 'package:prismarine_math/libm.dart' as libm;

void main() {
  // The same bits on macOS, Linux and Windows, on arm64 and x86-64.
  final angle = libm.atan2(1, 2);
  final x = libm.cos(angle) * 10, y = libm.sin(angle) * 10;
  final gain = clampDouble(libm.pow(10, -6 / 20), 0, 1);
  print('$x $y $gain');
}
