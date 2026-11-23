// The factor of the exposure. With auto exposure [adapted] is the log2 of the
// adapted mean luminance, which maps to a grey card of 0.18 shifted by the
// compensation. Without it the manual factor applies.
float exposureFactor(float adapted, float manual, float autoOn,
                     float compensation) {
  if (autoOn < 0.5) return manual;
  return 0.18 * exp2(compensation - adapted);
}
