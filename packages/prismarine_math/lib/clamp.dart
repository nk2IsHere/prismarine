/// Returns [v] clamped to [lo] and [hi] with the exact results of
/// `num.clamp` and without boxing the result.
///
/// The order is that of `compareTo`, in which −0.0 is below 0.0 and NaN is
/// above every number. A NaN [v] returns [hi]. [lo] and [hi] are not NaN and
/// [lo] is at most [hi].
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
