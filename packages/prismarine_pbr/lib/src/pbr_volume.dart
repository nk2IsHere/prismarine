import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_math/clamp.dart';
import 'package:prismarine_math/libm.dart' as libm;
import 'package:vector_math/vector_math_64.dart';

import 'pbr_post.dart';
import 'pbr_settings.dart';

/// The ids of the shaders of the volumetric light.
abstract final class PbrVolumeShaderIds {
  static const inject = 'Pbr/volume_inject.comp',
      integrate = 'Pbr/volume_integrate.comp',
      apply = 'Pbr/volume_apply.frag';
}

/// The names of the froxel targets.
abstract final class PbrVolumeTargets {
  static const scatter = 'volumeScatter',
      history = 'volumeHistory',
      integrated = 'volumeIntegrated';
}

/// The near end of the froxel grid in metres.
const volumeNear = 0.25;

/// The volumetric light: a froxel grid along the view that a compute pass
/// fills with the light that the fog scatters towards the camera, a second
/// one that sums it from near to far and a full-screen draw that lays the
/// sum over the scene.
class PbrVolume {
  PbrVolume(this.settings);
  final PbrSettings settings;

  final _block = Uint8List(56 * 4);
  late final _f = _block.buffer.asFloat32List();
  bool _on = false;
  PbrQuality _quality = PbrQuality.medium;
  int _w = 0, _h = 0, _d = 0;
  final _lastCamera = Vector3.zero(), _lastForward = Vector3.zero();

  /// True with the fog in the plan.
  bool get enabled => _on;

  /// True when the settings need another grid.
  bool changed() =>
      settings.volume.enabled != _on ||
      (_on && settings.volume.quality != _quality);

  /// Adds the froxel targets and returns the passes of the fog over
  /// [scene], which has the depth [depth], for a view of [width] by
  /// [height] pixels. The passes read the lights of [frame].
  // alloc-cold: a new plan on a new size or new settings.
  List<PassPlan> make({
    required int width,
    required int height,
    required String scene,
    required String depth,
    required Uint8List frame,
    required Map<String, TextureRef> shadows,
    required Map<String, TargetSpec> targets,
    required Map<Uint8List, Uint8List> blocks,
  }) {
    _on = settings.volume.enabled;
    _quality = settings.volume.quality;
    if (!_on) return const [];
    final (w, h, d) = switch (_quality) {
      PbrQuality.low => (96, 54, 64),
      PbrQuality.medium => (160, 90, 64),
      PbrQuality.high => (240, 135, 128),
    };
    _w = w;
    _h = h;
    _d = d;
    for (final name in [
      PbrVolumeTargets.scatter,
      PbrVolumeTargets.history,
      PbrVolumeTargets.integrated,
    ]) {
      targets[name] = TargetSpec(
        _w,
        _h,
        'R16G16B16A16_FLOAT',
        layers: _d,
        volume: true,
        storage: true,
      );
    }
    final role = FrameRole('pbr.volume');
    blocks[role.block] = _block;
    final groups = [(_w + 7) ~/ 8, (_h + 7) ~/ 8];
    return [
      DispatchPlan(
        'volumeInject',
        PbrVolumeShaderIds.inject,
        [groups[0], groups[1], _d],
        StageResources(
          blocks: {'Frame': frame, 'Volume': role.block},
          textures: {
            ...shadows,
            'history': const TargetTexture(PbrVolumeTargets.history),
          },
          samplers: {0: _linear, 4: _compare},
          storage: {'scatter': const ImageRef(PbrVolumeTargets.scatter)},
        ),
      ),
      DispatchPlan(
        'volumeIntegrate',
        PbrVolumeShaderIds.integrate,
        [groups[0], groups[1], 1],
        StageResources(
          blocks: {'Volume': role.block},
          textures: {'scatter': const TargetTexture(PbrVolumeTargets.scatter)},
          samplers: {0: _linear},
          storage: {
            'integrated': const ImageRef(PbrVolumeTargets.integrated),
            'history': const ImageRef(PbrVolumeTargets.history),
          },
        ),
      ),
      RenderPassPlan(
        'volumeApply',
        [Attachment(scene)],
        null,
        [
          DrawPlan(
            vertex: PbrPostShaderIds.screenVertex,
            pixel: PbrVolumeShaderIds.apply,
            geometry: screenTriangle,
            state: _applyState,
            viewport: [0, 0, width.toDouble(), height.toDouble(), 0, 1],
            vertexResources: StageResources(),
            pixelResources: StageResources(
              blocks: {'Volume': role.block},
              textures: {
                'depth': TargetTexture(depth),
                'integrated': const TargetTexture(PbrVolumeTargets.integrated),
              },
              samplers: {0: _linear},
            ),
            label: 'fog',
          ),
        ],
      ),
    ];
  }

  /// Writes the block of the frame for [camera] with the projection of
  /// [aspect], after the camera of the last frame [previous] without
  /// jitter. With [reset] the froxels keep nothing of the last frame.
  void write(
    PbrCamera camera,
    double aspect,
    Matrix4 previous,
    int frameIndex, {
    required bool reset,
  }) {
    if (!_on) return;
    final v = settings.volume;
    final f = _f;
    final p = previous.storage;
    for (var i = 0; i < 16; i++) {
      f[i] = p[i];
    }
    final s = camera.view.storage;
    final tanY = libm.tan(camera.yfov / 2), tanX = tanY * aspect;
    final c = camera.position;
    f
      ..[16] = c.x
      ..[17] = c.y
      ..[18] = c.z
      ..[19] = camera.near
      ..[20] = s[0] * tanX
      ..[21] = s[4] * tanX
      ..[22] = s[8] * tanX
      ..[23] = camera.far
      ..[24] = s[1] * tanY
      ..[25] = s[5] * tanY
      ..[26] = s[9] * tanY
      ..[27] = 0
      ..[28] = -s[2]
      ..[29] = -s[6]
      ..[30] = -s[10]
      ..[31] = 0;
    if (reset) {
      _lastCamera.setFrom(c);
      _lastForward.setValues(-s[2], -s[6], -s[10]);
    }
    f
      ..[32] = _lastCamera.x
      ..[33] = _lastCamera.y
      ..[34] = _lastCamera.z
      ..[35] = 0
      ..[36] = _lastForward.x
      ..[37] = _lastForward.y
      ..[38] = _lastForward.z
      ..[39] = 0;
    _lastCamera.setFrom(c);
    _lastForward.setValues(-s[2], -s[6], -s[10]);
    final far = v.range > volumeNear * 2 ? v.range : volumeNear * 2;
    f
      ..[40] = _w.toDouble()
      ..[41] = _h.toDouble()
      ..[42] = _d.toDouble()
      ..[43] = _jitter[frameIndex & 7]
      ..[44] = volumeNear
      ..[45] = far
      ..[46] = libm.log(far / volumeNear)
      ..[47] = reset ? 0 : clampDouble(v.history, 0, 0.98)
      ..[48] = v.density
      ..[49] = v.heightFalloff
      ..[50] = v.base
      ..[51] = clampDouble(v.anisotropy, -0.95, 0.95)
      ..[52] = v.sun
      ..[53] = v.points
      ..[54] = v.ambient
      ..[55] = 0;
  }
}

/// The depth offsets of the froxel samples in eight frames, the Halton
/// sequence in base 2 from index 1.
const _jitter = [0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875, 0.0625];

const _linear = SamplerState(address: ['clamp', 'clamp', 'clamp']);
const _compare = SamplerState(
  address: ['clamp', 'clamp', 'clamp'],
  compare: 'lessEqual',
  mipLinear: false,
);

// The light in front of a pixel adds to it, and its transmittance scales
// what was there.
const _applyState = DrawState(
  cull: 'none',
  depthTest: false,
  depthWrite: false,
  blends: [
    Blend(
      enabled: true,
      color: ['one', 'srcAlpha', 'add'],
      alpha: ['zero', 'one', 'add'],
    ),
  ],
);
