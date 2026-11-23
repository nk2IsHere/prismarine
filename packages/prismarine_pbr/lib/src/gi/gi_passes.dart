import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:vector_math/vector_math_64.dart';

import '../pbr_gi_settings.dart';
import '../pbr_point_shadows.dart' show pointShadowAtlas;
import '../pbr_settings.dart';
import 'gi_block.dart';
import 'gi_volume.dart';

/// The names of the targets of the indirect light.
abstract final class GiTargets {
  static const gbufferNormal = 'gbufferNormal',
      gbufferAlbedo = 'gbufferAlbedo',
      skyEnv = 'skyEnv',
      skySpecular = 'skySpecular',
      skyIrradiance = 'skyIrradiance',
      brdfLut = 'brdfLut',
      giRays = 'giRays',
      giIrradiance = 'giIrradiance',
      giIrradianceNext = 'giIrradianceNext',
      giDistance = 'giDistance',
      giDistanceNext = 'giDistanceNext',
      aoRaw = 'aoRaw',
      ao = 'ao',
      ssr = 'ssr',
      ssrBlur = 'ssrBlur',
      giDiffuseHalf = 'giDiffuseHalf',
      giSpecularHalf = 'giSpecularHalf',
      history = 'history';
}

/// The sizes of the sky maps and of the reflection history.
const _skyWidth = 256, _skyMips = 7, _specularWidth = 128, _specularMips = 6;
const _historyMips = 5;

/// The passes of the indirect light in a plan of the builder and the bytes
/// of their block. The builder asks for the targets, the passes before and
/// after the opaque pass and the textures of the blended draws when it makes
/// a plan, and calls [write] each frame.
class GiPasses {
  GiPasses(this.settings);

  final PbrGiSettings settings;

  /// The voxel copy and the probes, or null before they are made.
  GiVolume? volume;

  final block = IndirectBlock();
  final role = FrameRole('pbr.indirect');

  /// The number of frames written so far.
  int frameIndex = 0;

  int _first = 0, _count = 0;
  double _updates = 0;
  GiVolume? _volumeOf;
  Uint8List _voxels = Uint8List(16), _probes = Uint8List(16);
  final _previous = Matrix4.identity(), _inverse = Matrix4.identity();
  bool _hasPrevious = false;

  /// The frames since the reflection history was made. The first frame has
  /// no history to read.
  int _historyFrames = 0;
  int _width = 1, _height = 1;

  bool get _probesOn => settings.probes && volume != null;

  /// A value that changes whenever the passes of a plan would change.
  int get planKey {
    var h = identityHashCode(volume);
    h = (h * 2 + (settings.sky ? 1 : 0)) & 0x3fffffff;
    h = (h * 2 + (_probesOn ? 1 : 0)) & 0x3fffffff;
    h = (h * 2 + (settings.ambientOcclusion ? 1 : 0)) & 0x3fffffff;
    h = (h * 2 + (settings.reflections ? 1 : 0)) & 0x3fffffff;
    h = (h * 2 + (settings.ssrFullSize ? 1 : 0)) & 0x3fffffff;
    h = (h * 31 + settings.raysPerProbe) & 0x3fffffff;
    h = (h * 31 + settings.probesPerFrame) & 0x3fffffff;
    return (h * 31 + settings.debugView.index) & 0x3fffffff;
  }

  int get _tiles => math.max(1, math.sqrt(volume!.probeCount).ceil());
  int get _rows => (volume!.probeCount + _tiles - 1) ~/ _tiles;

  /// Adds the targets of the indirect light for a view of [width] by
  /// [height] to [targets].
  // alloc-cold: a new plan.
  void addTargets(Map<String, TargetSpec> targets, int width, int height) {
    _width = width;
    _height = height;
    _historyFrames = 0;
    final v = volume;
    if (!identical(v, _volumeOf)) {
      _volumeOf = v;
      _updates = 0;
      _first = 0;
      if (v != null) {
        _voxels = v.voxels.buffer.asUint8List(
          v.voxels.offsetInBytes,
          v.voxels.lengthInBytes,
        );
        _probes = v.probes.buffer.asUint8List(
          v.probes.offsetInBytes,
          v.probes.lengthInBytes,
        );
      }
    }
    const hdr = 'R16G16B16A16_FLOAT';
    targets[GiTargets.gbufferNormal] = TargetSpec(width, height, hdr);
    targets[GiTargets.gbufferAlbedo] = TargetSpec(
      width,
      height,
      'R8G8B8A8_UNORM',
    );
    targets[GiTargets.skyEnv] = const TargetSpec(
      _skyWidth,
      _skyWidth ~/ 2,
      hdr,
      mips: _skyMips,
      storage: true,
    );
    targets[GiTargets.skySpecular] = const TargetSpec(
      _specularWidth,
      _specularWidth ~/ 2,
      hdr,
      mips: _specularMips,
      storage: true,
    );
    targets[GiTargets.skyIrradiance] = const TargetSpec(
      32,
      16,
      hdr,
      storage: true,
    );
    targets[GiTargets.brdfLut] = const TargetSpec(64, 64, hdr, storage: true);
    if (v != null) {
      _count = math.min(settings.probesPerFrame, v.activeCount);
      targets[GiTargets.giRays] = TargetSpec(
        settings.raysPerProbe,
        math.max(_count, 1),
        hdr,
        storage: true,
      );
      for (final (name, side) in const [
        (GiTargets.giIrradiance, 8),
        (GiTargets.giIrradianceNext, 8),
        (GiTargets.giDistance, 16),
        (GiTargets.giDistanceNext, 16),
      ]) {
        targets[name] = TargetSpec(
          _tiles * side,
          _rows * side,
          hdr,
          storage: true,
        );
      }
    }
    final hw = (width + 1) ~/ 2, hh = (height + 1) ~/ 2;
    targets[GiTargets.giDiffuseHalf] = TargetSpec(hw, hh, hdr);
    targets[GiTargets.giSpecularHalf] = TargetSpec(hw, hh, hdr);
    if (settings.ambientOcclusion) {
      targets[GiTargets.aoRaw] = TargetSpec(hw, hh, 'R8_UNORM');
      targets[GiTargets.ao] = TargetSpec(hw, hh, 'R8_UNORM');
    }
    if (settings.reflections) {
      for (final name in const [GiTargets.ssr, GiTargets.ssrBlur]) {
        targets[name] = settings.ssrFullSize
            ? TargetSpec(width, height, hdr)
            : TargetSpec(hw, hh, hdr);
      }
      targets[GiTargets.history] = TargetSpec(hw, hh, hdr, mips: _historyMips);
    }
  }

  /// The compute passes that run before the opaque pass. [frame] is the
  /// block of the frame role and [shadowMap] the sun's shadow map.
  // alloc-cold: a new plan.
  List<PassPlan> before(Uint8List frame, String shadowMap) {
    final indirect = role.block;
    final passes = <PassPlan>[
      DispatchPlan(
        'gi.brdf',
        _brdfShader,
        const [8, 8, 1],
        StageResources(storage: {'brdfLut': const ImageRef(GiTargets.brdfLut)}),
      ),
      // Each mip of the sky from the model, which is smooth without the
      // sun's disc.
      for (var m = 0; m < _skyMips; m++)
        DispatchPlan(
          m == 0 ? 'gi.sky' : 'gi.skyMip$m',
          _skyShader,
          [_groups(_skyWidth >> m), _groups(_skyWidth >> (m + 1)), 1],
          StageResources(
            blocks: {'Frame': frame},
            storage: {'skyEnv': ImageRef(GiTargets.skyEnv, mip: m)},
          ),
        ),
      for (var m = 0; m < _specularMips; m++)
        DispatchPlan(
          'gi.skySpecular$m',
          _skySpecularShader,
          [_groups(_specularWidth >> m), _groups(_specularWidth >> (m + 1)), 1],
          StageResources(
            blocks: {
              'Level': Float32List.fromList([
                m / (_specularMips - 1),
                (_skyWidth * _skyWidth ~/ 2).toDouble(),
                (_skyMips - 1).toDouble(),
                0,
              ]).buffer.asUint8List(),
            },
            textures: {
              'skyEnv': const TargetTexture(GiTargets.skyEnv, mips: _skyMips),
            },
            samplers: const {6: _equirect},
            storage: {'target': ImageRef(GiTargets.skySpecular, mip: m)},
          ),
        ),
      DispatchPlan(
        'gi.skyIrradiance',
        _skyIrradianceShader,
        const [4, 2, 1],
        StageResources(
          textures: {'source': const TargetTexture(GiTargets.skyEnv, mip: 3)},
          samplers: const {5: _pointClamp},
          storage: {'skyIrradiance': const ImageRef(GiTargets.skyIrradiance)},
        ),
      ),
    ];
    if (!_probesOn) return passes;
    final probes = BufferTexture(_probes, 'R32G32B32A32_FLOAT');
    final rows = math.max(_count, 1);
    passes.addAll([
      DispatchPlan(
        'gi.trace',
        _traceShader,
        [(settings.raysPerProbe + 31) ~/ 32, rows, 1],
        StageResources(
          blocks: {'Frame': frame, 'Indirect': indirect},
          textures: {
            'giProbes': probes,
            'giIrradiance': const TargetTexture(GiTargets.giIrradiance),
            'giDistance': const TargetTexture(GiTargets.giDistance),
            'skyEnv': const TargetTexture(GiTargets.skyEnv, mips: _skyMips),
            'shadowMap': TargetTexture(shadowMap),
            'pointShadowAtlas': const TargetTexture(pointShadowAtlas),
          },
          samplers: const {5: _linearClamp, 6: _equirect, 4: _shadowCompare},
          storage: {
            'RawVoxels': InlineBuffer(_voxels),
            'giRays': const ImageRef(GiTargets.giRays),
          },
        ),
      ),
      DispatchPlan(
        'gi.blend',
        _blendShader,
        [rows, 1, 1],
        StageResources(
          blocks: {'Indirect': indirect},
          textures: {
            'giProbes': probes,
            'giRays': const TargetTexture(GiTargets.giRays),
            'giIrradiance': const TargetTexture(GiTargets.giIrradiance),
            'giDistance': const TargetTexture(GiTargets.giDistance),
          },
          samplers: const {5: _pointClamp},
          storage: {
            'giIrradianceNext': const ImageRef(GiTargets.giIrradianceNext),
            'giDistanceNext': const ImageRef(GiTargets.giDistanceNext),
          },
        ),
      ),
      DispatchPlan(
        'gi.copy',
        _copyShader,
        [rows, 1, 1],
        StageResources(
          blocks: {'Indirect': indirect},
          textures: {
            'giProbes': probes,
            'giIrradianceNext': const TargetTexture(GiTargets.giIrradianceNext),
            'giDistanceNext': const TargetTexture(GiTargets.giDistanceNext),
          },
          samplers: const {5: _pointClamp},
          storage: {
            'giIrradiance': const ImageRef(GiTargets.giIrradiance),
            'giDistance': const ImageRef(GiTargets.giDistance),
          },
        ),
      ),
    ]);
    return passes;
  }

  /// The names of the passes that only the sun and the sky settings
  /// change.
  // alloc-cold: a new plan.
  List<String> get skyPasses => [
    'gi.sky',
    for (var m = 1; m < _skyMips; m++) 'gi.skyMip$m',
    for (var m = 0; m < _specularMips; m++) 'gi.skySpecular$m',
    'gi.skyIrradiance',
  ];

  /// The textures of the indirect light that a pixel shader reads, with
  /// stand-ins for the targets that the plan lacks.
  // alloc-cold: a new plan.
  Map<String, TextureRef> get textures => {
    'giIrradiance': volume == null
        ? _black
        : const TargetTexture(GiTargets.giIrradiance),
    'giDistance': volume == null
        ? _black
        : const TargetTexture(GiTargets.giDistance),
    'giProbes': BufferTexture(_probes, 'R32G32B32A32_FLOAT'),
    'skyEnv': const TargetTexture(GiTargets.skyEnv, mips: _skyMips),
    'skySpecular': const TargetTexture(
      GiTargets.skySpecular,
      mips: _specularMips,
    ),
    'skyIrradiance': const TargetTexture(GiTargets.skyIrradiance),
    'brdfLut': const TargetTexture(GiTargets.brdfLut),
  };

  /// The samplers of the pixel shaders that read [textures].
  static const samplers = {5: _linearClamp, 6: _equirect};

  /// The name of the first pass after the opaque pass in the last plan.
  String firstAfter = 'indirect';

  /// The passes after the opaque pass into [hdr] with depth [depth]. [frame]
  /// is the block of the frame role and [view] the viewport of the plan.
  // alloc-cold: a new plan.
  List<RenderPassPlan> after(
    Uint8List frame,
    String hdr,
    String depth,
    List<double> view,
  ) {
    final indirect = role.block;
    final half = <double>[
      0,
      0,
      ((_width + 1) ~/ 2).toDouble(),
      ((_height + 1) ~/ 2).toDouble(),
      0,
      1,
    ];
    DrawPlan screen(
      String pixel,
      List<double> viewport,
      Map<String, TextureRef> textures, {
      DrawState state = _screenState,
      String vertex = _screenVertex,
      String label = '',
    }) => DrawPlan(
      vertex: vertex,
      pixel: pixel,
      geometry: InlineGeometry(_triangle, 8, const {0: ('R32G32_FLOAT', 0)}, 3),
      state: state,
      viewport: viewport,
      vertexResources: StageResources(),
      pixelResources: StageResources(
        blocks: {'Frame': frame, 'Indirect': indirect},
        textures: textures,
        samplers: samplers,
      ),
      label: label.isEmpty ? pixel : label,
    );
    final gbuffer = {
      'depth': TargetTexture(depth),
      'gbufferNormal': const TargetTexture(GiTargets.gbufferNormal),
    };
    final passes = <RenderPassPlan>[];
    if (settings.sky) {
      passes.add(
        RenderPassPlan(
          'sky',
          [Attachment(hdr)],
          Attachment(depth),
          [
            screen(
              _skyPixel,
              view,
              textures,
              state: _skyState,
              vertex: _skyVertex,
            ),
          ],
        ),
      );
    }
    if (settings.ambientOcclusion) {
      passes
        ..add(
          RenderPassPlan(
            'ao',
            const [Attachment(GiTargets.aoRaw)],
            null,
            [screen(_aoPixel, half, gbuffer)],
          ),
        )
        ..add(
          RenderPassPlan(
            'aoBlur',
            const [Attachment(GiTargets.ao)],
            null,
            [
              screen(_aoBlurPixel, half, {
                'depth': TargetTexture(depth),
                'aoRaw': const TargetTexture(GiTargets.aoRaw),
              }),
            ],
          ),
        );
    }
    if (settings.reflections) {
      passes.add(
        RenderPassPlan(
          'ssr',
          const [
            Attachment(GiTargets.ssr, clear: [0, 0, 0, 0]),
          ],
          null,
          [
            screen(_ssrPixel, settings.ssrFullSize ? view : half, {
              ...gbuffer,
              'history': const TargetTexture(
                GiTargets.history,
                mips: _historyMips,
              ),
            }),
          ],
        ),
      );
    }
    if (settings.reflections) {
      passes.add(
        RenderPassPlan(
          'ssrBlur',
          const [Attachment(GiTargets.ssrBlur)],
          null,
          [
            screen(_ssrBlurPixel, settings.ssrFullSize ? view : half, {
              'depth': TargetTexture(depth),
              'ssrRaw': const TargetTexture(GiTargets.ssr),
            }),
          ],
        ),
      );
    }
    passes.add(
      RenderPassPlan(
        'giResolve',
        const [
          Attachment(GiTargets.giDiffuseHalf),
          Attachment(GiTargets.giSpecularHalf),
        ],
        null,
        [
          screen(_resolvePixel, half, {...gbuffer, ...textures}),
        ],
      ),
    );
    final debug = settings.debugView;
    final replace = debug != GiDebugView.none && debug != GiDebugView.probes;
    passes.add(
      RenderPassPlan(
        'indirect',
        [Attachment(hdr)],
        null,
        [
          screen(_indirectPixel, view, {
            ...gbuffer,
            'gbufferAlbedo': const TargetTexture(GiTargets.gbufferAlbedo),
            'ao': settings.ambientOcclusion
                ? const TargetTexture(GiTargets.ao)
                : _white,
            'ssr': settings.reflections
                ? const TargetTexture(GiTargets.ssrBlur)
                : _black,
            'giDiffuseHalf': const TargetTexture(GiTargets.giDiffuseHalf),
            'giSpecularHalf': const TargetTexture(GiTargets.giSpecularHalf),
            'brdfLut': const TargetTexture(GiTargets.brdfLut),
          }, state: replace ? _screenState : _addState),
        ],
      ),
    );
    if (debug == GiDebugView.probes && volume != null) {
      passes.add(
        RenderPassPlan(
          'probes',
          [Attachment(hdr)],
          Attachment(depth),
          [
            DrawPlan(
              vertex: _probeVertex,
              pixel: _probePixel,
              geometry: InlineGeometry(
                _quad,
                8,
                const {0: ('R32G32_FLOAT', 0)},
                6,
                instances: volume!.probeCount,
              ),
              state: const DrawState(cull: 'none'),
              viewport: view,
              vertexResources: StageResources(
                blocks: {'Frame': frame, 'Indirect': indirect},
                textures: {'giProbes': textures['giProbes']!},
              ),
              pixelResources: StageResources(
                blocks: {'Indirect': indirect},
                textures: {
                  'giIrradiance': const TargetTexture(GiTargets.giIrradiance),
                },
                samplers: samplers,
              ),
              label: 'probes',
            ),
          ],
        ),
      );
    }
    if (settings.reflections) {
      passes.add(
        RenderPassPlan(
          'history',
          const [Attachment(GiTargets.history)],
          null,
          [
            screen(_downsamplePixel, half, {'source': TargetTexture(hdr)}),
          ],
        ),
      );
      for (var m = 1; m < _historyMips; m++) {
        final w = math.max(1, ((_width + 1) ~/ 2) >> m);
        final h = math.max(1, ((_height + 1) ~/ 2) >> m);
        passes.add(
          RenderPassPlan(
            'historyMip$m',
            [Attachment(GiTargets.history, mip: m)],
            null,
            [
              screen(
                _downsamplePixel,
                [0, 0, w.toDouble(), h.toDouble(), 0, 1],
                {'source': TargetTexture(GiTargets.history, mip: m - 1)},
              ),
            ],
          ),
        );
      }
    }
    firstAfter = passes.first.name;
    return passes;
  }

  /// Drops the reflection history, for a cut of the camera.
  void cut() => _historyFrames = 0;

  /// Writes the block for a frame with the view-projection [viewProjection]
  /// and the projection [projection] of a camera at [camera] that looks
  /// along [forward]. [sunScale] is the factor of the sky's radiance.
  void write(
    Matrix4 viewProjection,
    Matrix4 projection,
    Vector3 forward,
    double sunScale,
  ) {
    final b = block;
    _inverse.copyInverse(viewProjection);
    b.matrix(IndirectBlock.inverseViewProjection, _inverse);
    if (!_hasPrevious) {
      _previous.setFrom(viewProjection);
      _hasPrevious = true;
    }
    b
      ..matrix(IndirectBlock.previousViewProjection, _previous)
      ..floats(
        IndirectBlock.view,
        _width.toDouble(),
        _height.toDouble(),
        1 / _width,
        1 / _height,
      )
      ..floats(
        IndirectBlock.switches,
        settings.sky ? 1 : 0,
        _probesOn ? 1 : 0,
        settings.ambientOcclusion ? 1 : 0,
        settings.reflections && _historyFrames > 0 ? 1 : 0,
      );
    _historyFrames++;
    _previous.setFrom(viewProjection);
    final v = volume;
    if (v != null) {
      final active = math.max(v.activeCount, 1);
      // The first update of a probe replaces what its texels held.
      final cycle = _updates.floor();
      final h = cycle == 0
          ? 0.0
          : math.min(settings.hysteresis, 1 - 1 / (1 + cycle));
      _updates += _count / active;
      b
        ..floats(
          IndirectBlock.probeOrigin,
          v.probeOrigin.x,
          v.probeOrigin.y,
          v.probeOrigin.z,
          v.spacing,
        )
        ..floats(
          IndirectBlock.probeCounts,
          v.px.toDouble(),
          v.py.toDouble(),
          v.pz.toDouble(),
          _tiles.toDouble(),
        )
        ..floats(
          IndirectBlock.atlas,
          1 / (_tiles * 8),
          1 / (_rows * 8),
          1 / (_tiles * 16),
          1 / (_rows * 16),
        )
        ..floats(
          IndirectBlock.trace,
          _first.toDouble(),
          _count.toDouble(),
          active.toDouble(),
          settings.raysPerProbe.toDouble(),
        )
        ..rotation(frameIndex)
        ..floats(
          IndirectBlock.voxelOrigin,
          v.origin.x,
          v.origin.y,
          v.origin.z,
          v.cell,
        )
        ..floats(
          IndirectBlock.voxelCounts,
          v.nx.toDouble(),
          v.ny.toDouble(),
          v.nz.toDouble(),
          v.spacing * 1.5,
        )
        ..floats(IndirectBlock.probeParams, h, settings.bounce, 0.25, 0.1);
      _first = (_first + _count) % active;
    }
    final p = projection.storage;
    b
      ..floats(
        IndirectBlock.skyParams,
        sunScale * settings.skyIntensity,
        settings.intensity,
        (_specularMips - 1).toDouble(),
        (_skyMips - 1).toDouble(),
      )
      ..floats(
        IndirectBlock.aoParams,
        settings.aoRadius,
        settings.aoIntensity,
        settings.aoDirections.toDouble(),
        settings.aoSteps.toDouble(),
      )
      ..floats(
        IndirectBlock.ssrParams,
        settings.ssrSteps.toDouble(),
        settings.ssrMaxRoughness,
        settings.ssrThickness,
        (frameIndex & 0xffff).toDouble(),
      )
      ..floats(
        IndirectBlock.misc,
        settings.debugView.index.toDouble(),
        p[10],
        p[14],
        p[5],
      )
      ..floats(IndirectBlock.cameraForward, forward.x, forward.y, forward.z, 0);
    frameIndex++;
  }

  static int _groups(int texels) => math.max(1, (texels + 7) ~/ 8);
}

const _brdfShader = 'Pbr/brdf_lut.comp',
    _skyShader = 'Pbr/sky_env.comp',
    _skySpecularShader = 'Pbr/sky_specular.comp',
    _skyIrradianceShader = 'Pbr/sky_irradiance.comp',
    _traceShader = 'Pbr/gi_trace.comp',
    _blendShader = 'Pbr/gi_blend.comp',
    _copyShader = 'Pbr/gi_copy.comp',
    _screenVertex = 'Pbr/tonemap.vert',
    _skyVertex = 'Pbr/sky.vert',
    _skyPixel = 'Pbr/sky.frag',
    _aoPixel = 'Pbr/ao.frag',
    _aoBlurPixel = 'Pbr/ao_blur.frag',
    _ssrPixel = 'Pbr/ssr.frag',
    _ssrBlurPixel = 'Pbr/ssr_blur.frag',
    _indirectPixel = 'Pbr/indirect.frag',
    _resolvePixel = 'Pbr/gi_resolve.frag',
    _downsamplePixel = 'Pbr/downsample.frag',
    _probeVertex = 'Pbr/probe.vert',
    _probePixel = 'Pbr/probe.frag';

/// The shader ids of the indirect light.
const giShaderIds = [
  _brdfShader,
  _skyShader,
  _skySpecularShader,
  _skyIrradianceShader,
  _traceShader,
  _blendShader,
  _copyShader,
  _skyVertex,
  _skyPixel,
  _aoPixel,
  _aoBlurPixel,
  _ssrPixel,
  _ssrBlurPixel,
  _indirectPixel,
  _resolvePixel,
  _downsamplePixel,
  _probeVertex,
  _probePixel,
  PbrShaderIds.litBlendPixel,
];

final _triangle = Float32List.fromList([
  -1, -1, 3, -1, -1, 3, //
]).buffer.asUint8List();

final _quad = Float32List.fromList([
  -1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1, //
]).buffer.asUint8List();

final _white = ConstantTexture(
  'R8G8B8A8_UNORM',
  Uint8List.fromList([255, 255, 255, 255]),
);
final _black = ConstantTexture('R8G8B8A8_UNORM', Uint8List(4));

const _linearClamp = SamplerState(address: ['clamp', 'clamp', 'clamp']);
const _pointClamp = SamplerState(
  minLinear: false,
  magLinear: false,
  mipLinear: false,
  address: ['clamp', 'clamp', 'clamp'],
);
const _equirect = SamplerState(address: ['wrap', 'clamp', 'clamp']);
const _shadowCompare = SamplerState(
  address: ['clamp', 'clamp', 'clamp'],
  compare: 'lessEqual',
  mipLinear: false,
);
const _screenState = DrawState(
  cull: 'none',
  depthTest: false,
  depthWrite: false,
);
const _skyState = DrawState(cull: 'none', depthWrite: false);
const _addState = DrawState(
  cull: 'none',
  depthTest: false,
  depthWrite: false,
  blends: [
    Blend(
      enabled: true,
      color: ['one', 'one', 'add'],
      alpha: ['zero', 'one', 'add'],
    ),
  ],
);
