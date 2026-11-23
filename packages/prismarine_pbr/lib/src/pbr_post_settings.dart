/// The quality of an effect. A change makes a new plan.
enum PbrQuality { low, medium, high }

/// The curve that maps the exposed light of a pixel to the display.
enum PbrToneMap {
  /// The fit of Narkowicz to the ACES RRT and ODT.
  acesFit,

  /// The fit of Hill to the ACES RRT and ODT in the AP1 colour space.
  aces,

  /// AgX with the base contrast. Bright colours go to white without a change
  /// of hue.
  agx,

  /// The Khronos PBR Neutral curve, which keeps the colours of materials.
  neutral,
}

/// The settings of anti-aliasing, bloom, exposure and the tone map. A
/// change of a switch or a quality makes a new plan. The other values apply
/// to the next frame.
class PbrPostSettings {
  /// Temporal anti-aliasing with a jittered camera. On by default.
  bool taa = true;

  /// The quality of TAA. Low clamps the history to a cross of five pixels,
  /// medium clips it to the deviation of nine with bilinear history and high
  /// adds a Catmull-Rom filter of the history and 16 jitter offsets in place
  /// of 8. Medium by default.
  PbrQuality taaQuality = PbrQuality.medium;

  /// Bloom from the HDR image. On by default.
  bool bloom = true;

  /// The levels of the bloom chain, 5, 6 or 7 from low to high. Medium by
  /// default.
  PbrQuality bloomQuality = PbrQuality.medium;

  /// The share of the bloom in the image, 0.04 by default.
  double bloomStrength = 0.04;

  /// Exposure from a histogram of the luminance of the frame. On by default.
  /// Off, `PbrSettings.exposure` applies.
  bool autoExposure = true;

  /// The exposure compensation in EV for auto exposure, -0.5 by default.
  double compensation = -0.5;

  /// The lowest and highest exposure of auto exposure in EV, as the log2 of
  /// the mean luminance that maps to grey. -4 and 8 by default.
  double minEv = -4, maxEv = 8;

  /// The speed of adaptation towards a brighter and a darker scene, per
  /// second. 3 and 1.5 by default.
  double adaptUp = 3, adaptDown = 1.5;

  /// The tone map. AgX by default.
  PbrToneMap toneMap = PbrToneMap.agx;
}

/// The settings of the shadows of point lights. A change of [budget] or
/// [quality] makes a new plan.
class PbrPointShadowSettings {
  /// The most point lights that cast shadows, 2 by default and at most
  /// [maxPointShadows]. 0 turns the shadows off.
  int budget = 2;

  /// The side of a face of the atlas, 256, 512 or 1024 texels from low to
  /// high. Medium by default.
  PbrQuality quality = PbrQuality.medium;

  /// The depth bias in texels of a face, 1.5 by default.
  double bias = 1.5;

  /// The share of the range of a light within which objects cast shadows,
  /// 0.5 by default. Objects further from the light cast none.
  double reach = 0.5;
}

/// The most point lights that cast shadows.
const maxPointShadows = 8;

/// The settings of the volumetric light. A change of [enabled] or [quality]
/// makes a new plan.
class PbrVolumeSettings {
  /// Fog lit by the sun and the point lights. On by default.
  bool enabled = true;

  /// The froxel grid, 96 by 54 by 64 at low, 160 by 90 by 64 at medium and
  /// 240 by 135 by 128 at high quality. Medium by default.
  PbrQuality quality = PbrQuality.medium;

  /// The extinction of the fog per metre at the height [base], 0.006 by
  /// default.
  double density = 0.006;

  /// The falloff of the density per metre above [base], 0.08 by default.
  double heightFalloff = 0.08;

  /// The height of the full density in metres, 0 by default.
  double base = 0;

  /// The anisotropy of the Henyey-Greenstein phase function, from -1 back
  /// to 1 forward. 0.5 by default.
  double anisotropy = 0.5;

  /// The distance of the far end of the grid in metres, 60 by default.
  double range = 60;

  /// The factors of the sun, the point lights and the ambient light in the
  /// fog, 1, 1 and 0.5 by default.
  double sun = 1, points = 1, ambient = 0.5;

  /// The share of the last frame that each froxel keeps, 0.9 by default.
  /// 0 turns the reuse off.
  double history = 0.9;
}
