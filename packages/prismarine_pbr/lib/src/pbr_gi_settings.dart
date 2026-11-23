/// The presets of the indirect light, from the cheapest to the finest.
enum GiQuality { low, medium, high }

/// The picture that the indirect pass shows in place of the frame.
enum GiDebugView {
  /// The frame.
  none,

  /// The diffuse indirect light on a white surface.
  diffuse,

  /// The ambient occlusion.
  occlusion,

  /// The specular indirect light on a white mirror.
  reflections,

  /// The frame with a sphere at each probe, lit by the probe.
  probes,
}

/// The settings of the indirect light: the sky, the probes, the ambient
/// occlusion and the reflections. A change of a switch, of [quality], of
/// [raysPerProbe], [probesPerFrame], [ssrFullSize] or [debugView] makes a
/// new plan. The others apply to the next frame.
class PbrGiSettings {
  PbrGiSettings() {
    quality = GiQuality.medium;
  }

  /// Draws the procedural sky and lights with it. Off, the sky and the
  /// indirect light take the flat colours of the settings. On by default.
  bool sky = true;

  /// Lights with the irradiance probes. Off, the diffuse indirect light
  /// comes from the sky without occlusion. On by default.
  bool probes = true;

  /// Darkens the indirect light in creases and contacts from the depth
  /// buffer. On by default.
  bool ambientOcclusion = true;

  /// Reflects the screen on smooth surfaces. Off, reflections come from the
  /// probes and the sky only. On by default.
  bool reflections = true;

  /// The factor of the sky's radiance, 1 by default.
  double skyIntensity = 1;

  /// The factor of the indirect light, 1 by default.
  double intensity = 1;

  /// The share of the light that a ray hit passes on to the next bounce, 1
  /// by default. Lower values damp the bounces.
  double bounce = 1;

  /// The weight of a probe's old value against a new update, 0.85 by
  /// default. Higher values are smoother and slower to follow the lights.
  double hysteresis = 0.85;

  /// The radius of the ambient occlusion in world units and its strength,
  /// 1 and 1 by default.
  double aoRadius = 1, aoIntensity = 1;

  /// The roughness above which the screen is not reflected, 0.6 by default.
  double ssrMaxRoughness = 0.6;

  /// The depth in world units behind the depth buffer that counts as a hit
  /// of a reflected ray, 0.4 by default.
  double ssrThickness = 0.4;

  /// The rays per probe update and the probes updated per frame.
  int raysPerProbe = 96, probesPerFrame = 256;

  /// The directions and the steps along each of the ambient occlusion.
  int aoDirections = 2, aoSteps = 6;

  /// The steps of a reflected ray through the depth buffer.
  int ssrSteps = 32;

  /// Traces the reflections at the size of the view, not at half of it.
  bool ssrFullSize = false;

  /// The picture of the indirect pass. [GiDebugView.none] by default.
  GiDebugView debugView = GiDebugView.none;

  GiQuality _quality = GiQuality.medium;

  /// The preset that the counts above last took. Setting it sets them.
  GiQuality get quality => _quality;
  set quality(GiQuality q) {
    _quality = q;
    switch (q) {
      case GiQuality.low:
        raysPerProbe = 64;
        probesPerFrame = 128;
        aoDirections = 2;
        aoSteps = 4;
        ssrSteps = 16;
        ssrFullSize = false;
      case GiQuality.medium:
        raysPerProbe = 96;
        probesPerFrame = 256;
        aoDirections = 2;
        aoSteps = 6;
        ssrSteps = 32;
        ssrFullSize = false;
      case GiQuality.high:
        raysPerProbe = 192;
        probesPerFrame = 768;
        aoDirections = 4;
        aoSteps = 8;
        ssrSteps = 64;
        ssrFullSize = true;
    }
  }
}
