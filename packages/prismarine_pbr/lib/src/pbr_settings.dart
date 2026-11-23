import 'package:vector_math/vector_math_64.dart';

import 'pbr_post_settings.dart';

export 'pbr_post_settings.dart';

/// The ids of the shaders of the renderer in its bundle.
abstract final class PbrShaderIds {
  static const litVertex = 'Pbr/lit.vert',
      litPixel = 'Pbr/lit.frag',
      litMaskedPixel = 'Pbr/lit_masked.frag',
      shadowVertex = 'Pbr/shadow.vert',
      shadowMaskedPixel = 'Pbr/shadow_masked.frag',
      nullPixel = 'Pbr/null.frag',
      tonemapVertex = 'Pbr/tonemap.vert',
      tonemapPixel = 'Pbr/tonemap.frag',
      markerVertex = 'Pbr/marker.vert',
      markerPixel = 'Pbr/marker.frag',
      depthViewPixel = 'Pbr/depth_view.frag';

  static const all = [
    litVertex,
    litPixel,
    litMaskedPixel,
    shadowVertex,
    shadowMaskedPixel,
    nullPixel,
    tonemapVertex,
    tonemapPixel,
    markerVertex,
    markerPixel,
    depthViewPixel,
  ];
}

/// The most point lights that a frame lights with.
const maxPointLights = 16;

/// A point light of `KHR_lights_punctual`. [range] bounds its reach. The
/// renderer reads the fields each frame.
class PointLight {
  final position = Vector3.zero();

  /// The linear colour.
  final color = Vector3(1, 1, 1);

  /// The intensity in candela.
  double intensity = 1;
  double range = 10;
}

/// The camera of a frame. The renderer reads the fields each frame.
class PbrCamera {
  /// The world-to-view matrix. The camera looks along negative z.
  final view = Matrix4.identity();

  /// The vertical field of view in radians.
  double yfov = 0.9;
  double near = 0.05, far = 300;

  /// The position of the camera in the world, which [view] must match.
  final position = Vector3.zero();
}

/// The settings of the renderer. A change to [shadowSize] makes a new plan.
/// The others apply to the next frame.
class PbrSettings {
  /// The side of the shadow map in texels, 2048 by default.
  int shadowSize = 2048;

  /// Draws the sun's shadows. On by default.
  bool shadows = true;

  /// The factor of the light before the tone map without auto exposure, 1
  /// by default.
  double exposure = 1;

  /// The direction towards the sun.
  final sunDirection = Vector3(0.3, 1, 0.2)..normalize();

  /// The linear colour of the sun.
  final sunColor = Vector3(1, 0.93, 0.82);

  /// The illuminance of the sun in lux, scaled to the exposure.
  double sunIntensity = 8;

  /// The linear colour where no geometry is drawn, read when a plan is
  /// made.
  final background = Vector3(0.55, 0.7, 0.95);

  /// The ambient colour from above and from below.
  final sky = Vector3(0.22, 0.25, 0.30);
  final ground = Vector3(0.12, 0.10, 0.08);

  /// Draws a disc in the colour of each point light at its place. On by
  /// default.
  bool lightMarkers = true;

  /// The radius of a light's disc in metres, 0.2 by default.
  double markerSize = 0.2;

  /// Shows the shadow map in the top left corner of the view. Off by default. A change
  /// makes a new plan.
  bool showShadowMap = false;

  /// The depth bias of the shadow test and the offset along the normal in
  /// world units.
  double shadowBias = 0.0008, normalOffset = 0.02;

  /// Anti-aliasing, bloom, exposure and the tone map.
  final post = PbrPostSettings();

  /// The shadows of the point lights.
  final pointShadows = PbrPointShadowSettings();

  /// The volumetric light.
  final volume = PbrVolumeSettings();
}
