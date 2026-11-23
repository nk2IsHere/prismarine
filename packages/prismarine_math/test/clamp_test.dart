import 'package:prismarine_math/clamp.dart';
import 'package:test/test.dart';

void main() {
  // A NaN limit makes num.clamp throw: no caller has one.
  test('clampDouble gives num.clamp\'s answers, bit for bit', () {
    const values = [
      -2.0, -1.0, -0.0, 0.0, 0.5, 1.0, 2.0, //
      double.nan, double.infinity, double.negativeInfinity,
    ];
    const ranges = [
      (0.0, 1.0), (-1.0, 1.0), (-0.0, 0.0), (0.0, 0.0), (-0.0, -0.0), //
      (-1.0, -0.0),
      (double.negativeInfinity, double.infinity),
    ];
    for (final (lo, hi) in ranges) {
      for (final v in values) {
        final want = v.clamp(lo, hi).toDouble(), got = clampDouble(v, lo, hi);
        expect(
          got.isNaN
              ? want.isNaN
              : got == want && got.isNegative == want.isNegative,
          isTrue,
          reason: '$v in [$lo, $hi]: $got, clamp gives $want',
        );
      }
    }
  });
}
