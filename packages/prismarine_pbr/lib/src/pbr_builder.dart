import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

import 'gi/gi_passes.dart';
import 'gi/gi_volume.dart';
import 'pbr_blocks.dart';
import 'pbr_settings.dart';

/// A scene that the builder draws: its model and the prefix of the stems of
/// its meshes and textures in the render assets.
class PbrScene {
  PbrScene(this.prefix, this.model);
  final String prefix;
  final GltfModel model;

  /// The stem of image [image].
  String textureStem(int image) => '$prefix:$image';

  /// The stem of primitive [primitive] of mesh [mesh].
  String meshStem(int mesh, int primitive) => '$prefix:$mesh:$primitive';
}

/// The names of the targets of the plan.
abstract final class PbrTargets {
  static const shadowMap = 'shadowMap',
      hdr = 'hdr',
      depth = 'depth',
      backbuffer = 'backbuffer';
}

/// Builds the frame plan of a forward renderer for [scenes]: a shadow pass
/// from the sun, the opaque and masked draws, the blended draws from back
/// to front and a tone map into [PbrTargets.backbuffer].
///
/// The plan holds every draw once and stays the same object from frame to
/// frame. [frame] writes the camera, the sun and the [lights] into the bytes
/// of the frame roles and returns the plan. A new view size or shadow map
/// size makes a new plan.
class PbrBuilder {
  PbrBuilder(this.scenes, {PbrSettings? settings})
    : settings = settings ?? PbrSettings() {
    for (final s in scenes) {
      Vector3.min(_min, s.model.min, _min);
      Vector3.max(_max, s.model.max, _max);
    }
  }

  final List<PbrScene> scenes;
  final PbrSettings settings;

  /// The point lights of the frame. Only the first [maxPointLights] light.
  final lights = <PointLight>[];

  final _min = Vector3.all(double.infinity),
      _max = Vector3.all(-double.infinity);

  /// The corners of the bounds of every scene.
  Vector3 get boundsMin => _min;
  Vector3 get boundsMax => _max;

  FramePlan? _plan;
  int _width = 0, _height = 0, _shadowSize = 0, _giKey = 0;
  bool _shadowView = false;

  /// The passes of the indirect light.
  late final gi = GiPasses(settings.gi);

  /// The voxel copy of the scenes for the probes, null until the app sets
  /// it. A new volume makes a new plan.
  GiVolume? get giVolume => gi.volume;
  set giVolume(GiVolume? v) => gi.volume = v;

  final _frame = FrameBlock(), _shadowFrame = FrameBlock();
  final _tonemap = Uint8List(16);
  late final _tonemapData = ByteData.sublistView(_tonemap);
  final _retained = <String, int>{'shadow': 0, 'gi.brdf': 1};
  List<String> _skyPasses = const [];
  final _blend = <_BlendDraw>[];
  List<DrawPlan> _blendDraws = const [];

  /// The number of draws in the plan, counted once for each pass.
  int drawCount = 0;

  /// The plan of the frame with camera [camera] in a view of [width] by
  /// [height] pixels.
  FramePlan frame(PbrCamera camera, int width, int height) {
    if (_plan == null ||
        width != _width ||
        height != _height ||
        settings.shadowSize != _shadowSize ||
        settings.showShadowMap != _shadowView ||
        gi.planKey != _giKey) {
      _plan = _make(width, height);
    }
    _writeFrame(camera, width / height);
    _sortBlend(camera.position);
    final sun = _sunStamp();
    _retained['shadow'] = settings.shadows ? sun : 0;
    final sky = _skyPasses;
    for (var i = 0; i < sky.length; i++) {
      _retained[sky[i]] = sun;
    }
    return _plan!;
  }

  /// The stems of every texture that the plan reads from files.
  Iterable<(PbrScene, int)> get images sync* {
    for (final s in scenes) {
      for (final m in s.model.materials) {
        for (final i in [
          m.baseColor,
          m.metallicRoughness,
          m.normal,
          m.emission,
        ]) {
          if (i != null) yield (s, i);
        }
      }
    }
  }

  // alloc-cold: a new plan on a new size or new settings.
  FramePlan _make(int width, int height) {
    _width = width;
    _height = height;
    _shadowSize = settings.shadowSize;
    _shadowView = settings.showShadowMap;
    _giKey = gi.planKey;
    _skyPasses = gi.skyPasses;
    final s = _shadowSize.toDouble();
    final view = <double>[0, 0, width.toDouble(), height.toDouble(), 0, 1];
    final shadowView = <double>[0, 0, s, s, 0, 1];
    final frameRole = FrameRole('pbr.frame');
    final shadowRole = FrameRole('pbr.shadowFrame');
    final tonemapRole = FrameRole('pbr.tonemap');
    final opaque = <(int, DrawPlan)>[];
    final giTextures = gi.textures;
    final shadow = <DrawPlan>[];
    _blend.clear();
    for (final scene in scenes) {
      final model = scene.model;
      for (final d in model.draws) {
        final p = model.meshes[d.mesh][d.primitive]!;
        final m = model.materialOf(p);
        final block = drawBlock(d.world, m);
        final geometry = DrawMeshGeometry(
          scene.meshStem(d.mesh, d.primitive),
          0,
          p.firstIndex,
          p.indexCount,
        );
        final masked = m.alphaMode == AlphaMode.mask;
        final blended = m.alphaMode == AlphaMode.blend;
        final pixel = _materialTextures(scene, m);
        final lit = DrawPlan(
          vertex: PbrShaderIds.litVertex,
          pixel: blended
              ? PbrShaderIds.litBlendPixel
              : masked
              ? PbrShaderIds.litMaskedPixel
              : PbrShaderIds.litPixel,
          geometry: geometry,
          state: blended
              ? (m.doubleSided ? _blendTwoSided : _blendOneSided)
              : (m.doubleSided ? _opaqueTwoSided : _opaqueOneSided),
          viewport: view,
          vertexResources: StageResources(
            blocks: {'Frame': frameRole.block, 'Draw': block},
          ),
          pixelResources: blended
              ? StageResources(
                  blocks: {
                    'Frame': frameRole.block,
                    'Draw': block,
                    'Indirect': gi.role.block,
                  },
                  textures: {...pixel, ...giTextures},
                  samplers: {..._samplers, ...GiPasses.samplers},
                )
              : StageResources(
                  blocks: {'Frame': frameRole.block, 'Draw': block},
                  textures: pixel,
                  samplers: _samplers,
                ),
          label: m.name,
        );
        if (blended) {
          _blend.add(_BlendDraw(lit, d.center));
        } else {
          // Masked draws after opaque ones, then by material.
          final key = (masked ? 1 << 20 : 0) + (p.material ?? 0xfffff);
          opaque.add((key, lit));
        }
        if (blended) continue;
        shadow.add(
          DrawPlan(
            vertex: PbrShaderIds.shadowVertex,
            pixel: masked ? PbrShaderIds.shadowMaskedPixel : null,
            geometry: geometry,
            state: _shadowState,
            viewport: shadowView,
            vertexResources: StageResources(
              blocks: {'Frame': shadowRole.block, 'Draw': block},
            ),
            pixelResources: masked
                ? StageResources(
                    blocks: {'Frame': shadowRole.block, 'Draw': block},
                    textures: {'baseColor': pixel['baseColor']!},
                    samplers: _samplers,
                  )
                : StageResources(),
            label: m.name,
          ),
        );
      }
    }
    opaque.sort((a, b) => a.$1.compareTo(b.$1));
    _blendDraws = [for (final b in _blend) b.draw];
    final markers = DrawPlan(
      vertex: PbrShaderIds.markerVertex,
      pixel: PbrShaderIds.markerPixel,
      geometry: InlineGeometry(_markerQuads, 12, const {
        0: ('R32G32B32_FLOAT', 0),
      }, 6 * maxPointLights),
      state: _markerState,
      viewport: view,
      vertexResources: StageResources(blocks: {'Frame': frameRole.block}),
      pixelResources: StageResources(),
      label: 'light markers',
    );
    final overlay = <DrawPlan>[];
    if (_shadowView) {
      final side = (math.min(width, height) / 3).roundToDouble();
      overlay.add(
        DrawPlan(
          vertex: PbrShaderIds.tonemapVertex,
          pixel: PbrShaderIds.depthViewPixel,
          geometry: InlineGeometry(_screenTriangle, 8, const {
            0: ('R32G32_FLOAT', 0),
          }, 3),
          state: _overlayState,
          viewport: [16, 16, side, side, 0, 1],
          vertexResources: StageResources(),
          pixelResources: StageResources(
            textures: {'shadowMap': const TargetTexture(PbrTargets.shadowMap)},
            samplers: {0: _clampSampler},
          ),
          label: 'shadow map view',
        ),
      );
    }
    drawCount =
        opaque.length + shadow.length + _blend.length + 2 + overlay.length;
    final tonemap = DrawPlan(
      vertex: PbrShaderIds.tonemapVertex,
      pixel: PbrShaderIds.tonemapPixel,
      geometry: InlineGeometry(_screenTriangle, 8, const {
        0: ('R32G32_FLOAT', 0),
      }, 3),
      state: const DrawState(cull: 'none', depthTest: false, depthWrite: false),
      viewport: view,
      vertexResources: StageResources(),
      pixelResources: StageResources(
        blocks: {'Tonemap': tonemapRole.block},
        textures: {'hdr': const TargetTexture(PbrTargets.hdr)},
        samplers: {0: _clampSampler},
      ),
      label: 'tonemap',
    );
    final targets = {
      PbrTargets.shadowMap: TargetSpec(_shadowSize, _shadowSize, 'D32_FLOAT'),
      PbrTargets.hdr: TargetSpec(width, height, 'R16G16B16A16_FLOAT'),
      PbrTargets.depth: TargetSpec(width, height, 'D32_FLOAT'),
      PbrTargets.backbuffer: TargetSpec(width, height, 'R8G8B8A8_UNORM'),
    };
    gi.addTargets(targets, width, height);
    return FramePlan(
      targets,
      [
        RenderPassPlan(
          'shadow',
          const [],
          const Attachment(PbrTargets.shadowMap, clearDepth: 1),
          shadow,
        ),
        ...gi.before(frameRole.block, PbrTargets.shadowMap),
        RenderPassPlan(
          'opaque',
          [
            Attachment(
              PbrTargets.hdr,
              clear: [
                settings.background.x,
                settings.background.y,
                settings.background.z,
                1,
              ],
            ),
            const Attachment(GiTargets.gbufferNormal, clear: [0, 0, 0, 0]),
            const Attachment(GiTargets.gbufferAlbedo, clear: [0, 0, 0, 0]),
          ],
          const Attachment(PbrTargets.depth, clearDepth: 1),
          [for (final (_, d) in opaque) d],
        ),
        ...gi.after(frameRole.block, PbrTargets.hdr, PbrTargets.depth, view),
        RenderPassPlan(
          'blend',
          const [Attachment(PbrTargets.hdr)],
          const Attachment(PbrTargets.depth),
          _blendDraws,
        ),
        RenderPassPlan(
          'markers',
          const [Attachment(PbrTargets.hdr)],
          const Attachment(PbrTargets.depth),
          [markers],
        ),
        RenderPassPlan(
          'tonemap',
          const [Attachment(PbrTargets.backbuffer)],
          null,
          [tonemap, ...overlay],
        ),
      ],
      frameBlocks: {
        frameRole.block: _frame.bytes,
        shadowRole.block: _shadowFrame.bytes,
        tonemapRole.block: _tonemap,
        gi.role.block: gi.block.bytes,
      },
      retained: _retained,
    );
  }

  Map<String, TextureRef> _materialTextures(PbrScene s, ModelMaterial m) {
    TextureRef file(int? image, TextureRef fallback, {bool srgb = false}) =>
        image == null
        ? fallback
        : FileTexture(s.textureStem(image), srgb: srgb);
    return {
      'baseColor': file(m.baseColor, _white, srgb: true),
      'normalMap': file(m.normal, _flatNormal),
      'metallicRoughness': file(m.metallicRoughness, _white),
      'emissiveMap': file(m.emission, _white, srgb: true),
      'shadowMap': const TargetTexture(PbrTargets.shadowMap),
    };
  }

  // The camera and the lights each frame, then the sun's matrices.
  void _writeFrame(PbrCamera camera, double aspect) {
    perspective(_projection, camera.yfov, aspect, camera.near, camera.far);
    _viewProjection
      ..setFrom(_projection)
      ..multiply(camera.view);
    _sunMatrices();
    final f = _frame;
    f
      ..matrix(0, _viewProjection)
      ..matrix(16, _shadowMatrix)
      ..vec(32, camera.position, settings.exposure)
      ..vec(36, settings.sunDirection, settings.shadows ? 1 : 0)
      ..vec(40, _scaled(settings.sunColor, settings.sunIntensity), 0)
      ..vec(44, settings.sky, 0);
    final count = math.min(lights.length, maxPointLights);
    f
      ..vec(48, settings.ground, count.toDouble())
      ..floats(
        52,
        1 / _shadowSize,
        settings.shadowBias,
        settings.normalOffset,
        0,
      );
    for (var i = 0; i < maxPointLights; i++) {
      if (i < count) {
        final l = lights[i];
        f
          ..vec(56 + 4 * i, l.position, l.range)
          ..vec(120 + 4 * i, _scaled(l.color, l.intensity), 0);
      } else {
        f
          ..floats(56 + 4 * i, 0, 0, 0, 0)
          ..floats(120 + 4 * i, 0, 0, 0, 0);
      }
    }
    final p = _projection.storage;
    f.floats(
      184,
      p[0],
      p[5],
      settings.markerSize,
      settings.lightMarkers ? 1 : 0,
    );
    _shadowFrame.matrix(0, _sunViewProjection);
    _tonemapData.setFloat32(0, settings.exposure, Endian.little);
    final v = camera.view.storage;
    _cameraForward.setValues(-v[2], -v[6], -v[10]);
    gi.write(
      _viewProjection,
      _projection,
      _cameraForward,
      settings.sunIntensity,
    );
  }

  final _projection = Matrix4.zero(), _viewProjection = Matrix4.zero();
  final _sunView = Matrix4.zero(), _sunProjection = Matrix4.zero();
  final _sunViewProjection = Matrix4.zero(), _shadowMatrix = Matrix4.zero();
  final _sunEye = Vector3.zero(), _center = Vector3.zero();
  final _up = Vector3.zero(), _forward = Vector3.zero();
  final _cameraForward = Vector3.zero();
  final _scratch = Vector3.zero();

  Vector3 _scaled(Vector3 v, double s) => _scratch
    ..setFrom(v)
    ..scale(s);

  /// The sun's view and orthographic projection around the bounds of the
  /// scenes, and the matrix from the world into the shadow map's texture
  /// coordinates and depth.
  void _sunMatrices() {
    _center
      ..setFrom(_min)
      ..add(_max)
      ..scale(0.5);
    final radius = math.max(_max.distanceTo(_min) * 0.5, 1e-3);
    final dir = settings.sunDirection;
    _sunEye
      ..setFrom(dir)
      ..scale(radius * 2)
      ..add(_center);
    _forward
      ..setFrom(dir)
      ..negate();
    if (dir.y.abs() > 0.99) {
      _up.setValues(1, 0, 0);
    } else {
      _up.setValues(0, 1, 0);
    }
    lookAlong(_sunView, _sunEye, _forward, _up);
    orthographic(_sunProjection, radius, radius, radius * 3);
    _sunViewProjection
      ..setFrom(_sunProjection)
      ..multiply(_sunView);
    // Clip x and y from -1 to 1 into texture coordinates with v down.
    _shadowMatrix
      ..setZero()
      ..setEntry(0, 0, 0.5)
      ..setEntry(1, 1, -0.5)
      ..setEntry(2, 2, 1)
      ..setEntry(0, 3, 0.5)
      ..setEntry(1, 3, 0.5)
      ..setEntry(3, 3, 1)
      ..multiply(_sunViewProjection);
  }

  /// A stamp of what the shadow map shows: the sun's direction and the
  /// shadow settings.
  int _sunStamp() {
    final d = settings.sunDirection;
    var h = _shadowSize;
    h = (h * 31 + (d.x * 1e6).round()) & 0x3fffffff;
    h = (h * 31 + (d.y * 1e6).round()) & 0x3fffffff;
    h = (h * 31 + (d.z * 1e6).round()) & 0x3fffffff;
    return h == 0 ? 1 : h;
  }

  /// Sorts the blended draws from back to front in place. An insertion
  /// sort keeps a nearly sorted list fast.
  void _sortBlend(Vector3 eye) {
    final b = _blend;
    for (var i = 0; i < b.length; i++) {
      b[i].key = b[i].center.distanceToSquared(eye);
    }
    for (var i = 1; i < b.length; i++) {
      final x = b[i];
      var j = i - 1;
      while (j >= 0 && b[j].key < x.key) {
        b[j + 1] = b[j];
        j--;
      }
      b[j + 1] = x;
    }
    final draws = _blendDraws;
    for (var i = 0; i < b.length; i++) {
      draws[i] = b[i].draw;
    }
  }
}

class _BlendDraw {
  _BlendDraw(this.draw, this.center);
  final DrawPlan draw;
  final Vector3 center;
  double key = 0;
}

final _screenTriangle = Float32List.fromList([
  -1, -1, 3, -1, -1, 3, //
]).buffer.asUint8List();

// Two triangles over the corners from -1 to 1 for each point light, the
// index of the light in z.
final _markerQuads = Float32List.fromList([
  for (var i = 0; i < maxPointLights; i++)
    for (final (x, y) in const [
      (-1, -1),
      (1, -1),
      (1, 1),
      (-1, -1),
      (1, 1),
      (-1, 1),
    ]) ...[x.toDouble(), y.toDouble(), i.toDouble()],
]).buffer.asUint8List();

final _white = ConstantTexture(
  'R8G8B8A8_UNORM',
  Uint8List.fromList([255, 255, 255, 255]),
);
final _flatNormal = ConstantTexture(
  'R8G8B8A8_UNORM',
  Uint8List.fromList([128, 128, 255, 255]),
);

const _materialSampler = SamplerState(anisotropy: 8);
const _clampSampler = SamplerState(address: ['clamp', 'clamp', 'clamp']);
const _shadowSampler = SamplerState(
  address: ['clamp', 'clamp', 'clamp'],
  compare: 'lessEqual',
  mipLinear: false,
);
const _samplers = {0: _materialSampler, 4: _shadowSampler};

// The plan's winding follows Direct3D, which counts it on the render target
// with y down. The counter-clockwise front faces of glTF in clip space with y
// up are clockwise there, the default of a draw state.
const _opaqueOneSided = DrawState();
const _opaqueTwoSided = DrawState(cull: 'none');
const _blendFactors = Blend(
  enabled: true,
  color: ['srcAlpha', 'invSrcAlpha', 'add'],
  alpha: ['one', 'invSrcAlpha', 'add'],
);
const _blendOneSided = DrawState(depthWrite: false, blends: [_blendFactors]);
const _blendTwoSided = DrawState(
  cull: 'none',
  depthWrite: false,
  blends: [_blendFactors],
);
const _shadowState = DrawState(cull: 'none');
const _markerState = DrawState(
  cull: 'none',
  depthWrite: false,
  blends: [
    Blend(
      enabled: true,
      color: ['one', 'one', 'add'],
      alpha: ['zero', 'one', 'add'],
    ),
  ],
);
const _overlayState = DrawState(
  cull: 'none',
  depthTest: false,
  depthWrite: false,
);
