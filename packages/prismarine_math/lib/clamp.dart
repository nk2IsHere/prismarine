/// `v.clamp(lo, hi)` on doubles without the boxing of `num.clamp` (its
/// result is a `num`: a hot caller made a double per call), with its exact
/// answers: `compareTo`'s order, in which −0.0 is below 0.0 and NaN above
/// everything (a NaN clamps to [hi]). The limits are numbers, [lo] at most
/// [hi] (`clamp` throws otherwise).
@pragma('vm:prefer-inline')
double clampDouble(double v, double lo, double hi) {
  if (v < lo || (v == 0 && lo == 0 && v.isNegative && !lo.isNegative)) {
    return lo;
  }
  if (v > hi ||
      v.isNaN ||
      (v == 0 && hi == 0 && !v.isNegative && hi.isNegative)) {
    return hi;
  }
  return v;
}
