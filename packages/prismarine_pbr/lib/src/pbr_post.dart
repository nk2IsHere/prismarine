import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:vector_math/vector_math_64.dart';

import 'pbr_settings.dart';

/// The ids of the shaders of the passes after the scene.
abstract final class PbrPostShaderIds {
  static const screenVertex = 'Pbr/tonemap.vert',
      taa = 'Pbr/taa.frag',
      exposureHistogram = 'Pbr/exposure_histogram.comp',
      exposureAdapt = 'Pbr/exposure_adapt.comp',
      bloomFirst = 'Pbr/bloom_first.frag',
      bloomDown = 'Pbr/bloom_down.frag',
      bloomUp = 'Pbr/bloom_up.frag',
      tonemap = 'Pbr/tonemap.frag',
      tonemapHistory = 'Pbr/tonemap_history.frag';
}

/// The names of the targets after the scene.
abstract final class PbrPostTargets {
  static const resolved = 'resolved',
      taaHistory = 'taaHistory',
      exposure = 'exposure',
      exposureBins = 'exposureBins';

  /// The target of bloom level [level], half the view at level 0.
  static String bloom(int level) => _bloom[level];
  static final _bloom = [for (var i = 0; i < 8; i++) 'bloom$i'];
}

/// The passes after the scene, the TAA resolve, the auto exposure, the
/// bloom chain and the tone map into the backbuffer, with the overlays of
/// the builder.
class PbrPost {
  PbrPost(this.settings);
  final PbrSettings settings;

  final _taaBlock = Uint8List(56 * 4);
  final _exposureBlock = Uint8List(12 * 4);
  final _toneBlock = Uint8List(8 * 4);
  late final _taaF = _taaBlock.buffer.asFloat32List();
  late final _exposureF = _exposureBlock.buffer.asFloat32List();
  late final _toneF = _toneBlock.buffer.asFloat32List();
  final _zeroBins = Uint8List(256 * 4);

  bool _taa = false, _bloom = false, _auto = false;
  PbrQuality _taaQuality = PbrQuality.medium, _bloomQuality = PbrQuality.medium;
  int _levels = 0, _width = 0, _height = 0;

  /// True with TAA in the plan.
  bool get taa => _taa;

  /// The count of jitter offsets of the plan, 0 without TAA.
  int get jitterCount => !_taa ? 0 : (_taaQuality == PbrQuality.high ? 16 : 8);

  /// Returns true when the settings need passes other than the plan's.
  bool changed() {
    final p = settings.post;
    return p.taa != _taa ||
        p.bloom != _bloom ||
        p.autoExposure != _auto ||
        (_taa && p.taaQuality != _taaQuality) ||
        (_bloom && p.bloomQuality != _bloomQuality);
  }

  /// The first pass of each timed part of the post passes, with its label.
  Iterable<(String, String)> get parts sync* {
    if (_taa) yield ('taa', 'taa');
    if (_auto) {
      yield ('exposure and bloom', 'exposureHistogram');
    } else if (_bloom) {
      yield ('exposure and bloom', 'bloomDown0');
    }
    yield ('tone map', 'tonemap');
  }

  // alloc-cold: a new plan on a new size or new settings.
  /// Adds the targets, buffers, blocks and passes after the scene for a
  /// view of [width] by [height] pixels. The passes read [scene] and the
  /// TAA reads [depth]. The tone map draws into [output], then the draws of
  /// [overlay].
  void make({
    required int width,
    required int height,
    required String scene,
    required String depth,
    required String output,
    required Map<String, TargetSpec> targets,
    required Map<String, BufferSpec> buffers,
    required Map<Uint8List, Uint8List> blocks,
    required List<PassPlan> passes,
    required List<DrawPlan> overlay,
  }) {
    final p = settings.post;
    _taa = p.taa;
    _bloom = p.bloom;
    _auto = p.autoExposure;
    _taaQuality = p.taaQuality;
    _bloomQuality = p.bloomQuality;
    _width = width;
    _height = height;
    final taaRole = FrameRole('pbr.taa'),
        exposureRole = FrameRole('pbr.exposure'),
        toneRole = FrameRole('pbr.tonemap');
    blocks[taaRole.block] = _taaBlock;
    blocks[exposureRole.block] = _exposureBlock;
    blocks[toneRole.block] = _toneBlock;
    final view = <double>[0, 0, width.toDouble(), height.toDouble(), 0, 1];
    var image = scene;
    if (_auto) {
      targets[PbrPostTargets.exposure] = const TargetSpec(
        1,
        1,
        'R32_FLOAT',
        storage: true,
      );
    }
    final TextureRef exposure = _auto
        ? const TargetTexture(PbrPostTargets.exposure)
        : _zeroExposure;
    if (_taa) {
      targets[PbrPostTargets.resolved] = TargetSpec(
        width,
        height,
        'R16G16B16A16_FLOAT',
      );
      targets[PbrPostTargets.taaHistory] = TargetSpec(
        width,
        height,
        'R16G16B16A16_FLOAT',
      );
      passes.add(
        RenderPassPlan(
          'taa',
          const [Attachment(PbrPostTargets.resolved)],
          null,
          [
            _screen(
              PbrPostShaderIds.taa,
              view,
              StageResources(
                blocks: {'Taa': taaRole.block},
                textures: {
                  'hdr': TargetTexture(scene),
                  'depth': TargetTexture(depth),
                  'history': const TargetTexture(PbrPostTargets.taaHistory),
                  'exposure': exposure,
                },
                samplers: {0: _pointSampler, 3: _linearSampler},
              ),
              'taa',
            ),
          ],
        ),
      );
      image = PbrPostTargets.resolved;
    }
    if (_auto) {
      buffers[PbrPostTargets.exposureBins] = BufferSpec(
        _zeroBins.length,
        initial: _zeroBins,
      );
      const bins = BufferRef(PbrPostTargets.exposureBins);
      passes
        ..add(
          DispatchPlan(
            'exposureHistogram',
            PbrPostShaderIds.exposureHistogram,
            [(width + 31) ~/ 32, (height + 31) ~/ 32, 1],
            StageResources(
              blocks: {'Exposure': exposureRole.block},
              textures: {'image': TargetTexture(image)},
              samplers: {0: _pointSampler},
              storage: {'RawBins': bins},
            ),
          ),
        )
        ..add(
          DispatchPlan(
            'exposureAdapt',
            PbrPostShaderIds.exposureAdapt,
            const [1, 1, 1],
            StageResources(
              blocks: {'Exposure': exposureRole.block},
              storage: {
                'RawBins': bins,
                'exposure': const ImageRef(PbrPostTargets.exposure),
              },
            ),
          ),
        );
    }
    _levels = !_bloom ? 0 : 5 + _bloomQuality.index;
    if (_bloom) _bloomPasses(image, width, height, targets, passes);
    final first = [
      Attachment(output),
      if (_taa) const Attachment(PbrPostTargets.taaHistory),
    ];
    passes.add(
      RenderPassPlan('tonemap', first, null, [
        _screen(
          _taa ? PbrPostShaderIds.tonemapHistory : PbrPostShaderIds.tonemap,
          view,
          StageResources(
            blocks: {'Tonemap': toneRole.block},
            textures: {
              'hdr': TargetTexture(image),
              'bloom': _bloom ? TargetTexture(PbrPostTargets.bloom(0)) : _black,
              'exposure': exposure,
            },
            samplers: {0: _linearSampler},
          ),
          'tonemap',
        ),
        // The overlays write the backbuffer only.
        for (final d in overlay) _taa ? _withoutHistory(d) : d,
      ]),
    );
  }

  void _bloomPasses(
    String image,
    int width,
    int height,
    Map<String, TargetSpec> targets,
    List<PassPlan> passes,
  ) {
    final w = Int32List(_levels), h = Int32List(_levels);
    for (var i = 0; i < _levels; i++) {
      w[i] = math.max(1, width >> (i + 1));
      h[i] = math.max(1, height >> (i + 1));
      targets[PbrPostTargets.bloom(i)] = TargetSpec(
        w[i],
        h[i],
        'R11G11B10_FLOAT',
      );
    }
    for (var i = 0; i < _levels; i++) {
      final source = i == 0 ? image : PbrPostTargets.bloom(i - 1);
      final sw = i == 0 ? width : w[i - 1], sh = i == 0 ? height : h[i - 1];
      passes.add(
        RenderPassPlan(
          'bloomDown$i',
          [Attachment(PbrPostTargets.bloom(i))],
          null,
          [
            _screen(
              i == 0 ? PbrPostShaderIds.bloomFirst : PbrPostShaderIds.bloomDown,
              [0, 0, w[i].toDouble(), h[i].toDouble(), 0, 1],
              StageResources(
                blocks: {'Bloom': _texelBlock(sw, sh)},
                textures: {'source': TargetTexture(source)},
                samplers: {0: _linearSampler},
              ),
              'bloom down $i',
            ),
          ],
        ),
      );
    }
    for (var i = _levels - 2; i >= 0; i--) {
      passes.add(
        RenderPassPlan(
          'bloomUp$i',
          [Attachment(PbrPostTargets.bloom(i))],
          null,
          [
            _screen(
              PbrPostShaderIds.bloomUp,
              [0, 0, w[i].toDouble(), h[i].toDouble(), 0, 1],
              StageResources(
                blocks: {'Bloom': _texelBlock(w[i + 1], h[i + 1])},
                textures: {
                  'source': TargetTexture(PbrPostTargets.bloom(i + 1)),
                },
                samplers: {0: _linearSampler},
              ),
              'bloom up $i',
              state: _addState,
            ),
          ],
        ),
      );
    }
  }

  /// Writes the blocks of the frame. [inverseJittered] turns the clip space
  /// of the jittered camera into the world, [viewProjection] and [previous]
  /// are the camera of this frame and of the last one without jitter. [dt]
  /// is the time step in seconds. With [reset] the histories start again.
  void write({
    required Matrix4 inverseJittered,
    required Matrix4 viewProjection,
    required Matrix4 previous,
    required double dt,
    required bool reset,
  }) {
    final p = settings.post;
    final t = _taaF;
    _matrix(t, 0, inverseJittered);
    _matrix(t, 16, viewProjection);
    _matrix(t, 32, previous);
    t
      ..[48] = 1 / _width
      ..[49] = 1 / _height
      ..[50] = reset ? 1 : 1 / 12
      ..[51] = _taaQuality.index.toDouble()
      ..[52] = settings.exposure
      ..[53] = _auto ? 1 : 0
      ..[54] = p.compensation
      ..[55] = 0;
    final e = _exposureF;
    e
      ..[0] = _minLog
      ..[1] = 1 / (_maxLog - _minLog)
      ..[2] = dt
      ..[3] = reset ? 1 : 0
      ..[4] = p.compensation
      ..[5] = p.minEv
      ..[6] = p.maxEv
      ..[7] = p.adaptUp
      ..[8] = p.adaptDown
      ..[9] = _width.toDouble()
      ..[10] = _height.toDouble()
      ..[11] = 0;
    final o = _toneF;
    o
      ..[0] = settings.exposure
      ..[1] = _auto ? 1 : 0
      ..[2] = p.compensation
      ..[3] = p.toneMap.index.toDouble()
      ..[4] = _bloom ? p.bloomStrength : 0
      ..[5] = _levels == 0 ? 0 : 1 / _levels
      ..[6] = _levels == 0 ? 0 : 1 / math.max(1, _width >> 1)
      ..[7] = _levels == 0 ? 0 : 1 / math.max(1, _height >> 1);
  }

  static void _matrix(Float32List f, int at, Matrix4 m) {
    final s = m.storage;
    for (var i = 0; i < 16; i++) {
      f[at + i] = s[i];
    }
  }
}

/// The range of the histogram of the auto exposure in EV.
const _minLog = -10.0, _maxLog = 6.0;

/// Returns a block with the texel size of a [width] by [height] source.
Uint8List _texelBlock(int width, int height) => Float32List.fromList([
  1 / width,
  1 / height,
  width.toDouble(),
  height.toDouble(),
]).buffer.asUint8List();

DrawPlan _screen(
  String pixel,
  List<double> viewport,
  StageResources resources,
  String label, {
  DrawState state = _screenState,
}) => DrawPlan(
  vertex: PbrPostShaderIds.screenVertex,
  pixel: pixel,
  geometry: screenTriangle,
  state: state,
  viewport: viewport,
  vertexResources: StageResources(),
  pixelResources: resources,
  label: label,
);

/// Returns [d] with a blend state that leaves the second target alone.
DrawPlan _withoutHistory(DrawPlan d) => DrawPlan(
  vertex: d.vertex,
  pixel: d.pixel,
  geometry: d.geometry,
  state: DrawState(
    cull: d.state.cull,
    depthTest: d.state.depthTest,
    depthWrite: d.state.depthWrite,
    blends: [
      d.state.blends.isEmpty ? const Blend() : d.state.blends.first,
      const Blend(writeMask: 0),
    ],
  ),
  viewport: d.viewport,
  vertexResources: d.vertexResources,
  pixelResources: d.pixelResources,
  label: d.label,
);

/// One triangle over the view, its corners as positions.
final screenTriangle = InlineGeometry(
  Float32List.fromList([-1, -1, 3, -1, -1, 3]).buffer.asUint8List(),
  8,
  const {0: ('R32G32_FLOAT', 0)},
  3,
);

final _black = ConstantTexture(
  'R8G8B8A8_UNORM',
  Uint8List.fromList([0, 0, 0, 0]),
);
final _zeroExposure = ConstantTexture('R32_FLOAT', Uint8List(4));

const _screenState = DrawState(
  cull: 'none',
  depthTest: false,
  depthWrite: false,
);
const _addState = DrawState(
  cull: 'none',
  depthTest: false,
  depthWrite: false,
  blends: [
    Blend(
      enabled: true,
      color: ['one', 'one', 'add'],
      alpha: ['one', 'one', 'add'],
    ),
  ],
);
const _pointSampler = SamplerState(
  minLinear: false,
  magLinear: false,
  mipLinear: false,
  address: ['clamp', 'clamp', 'clamp'],
);
const _linearSampler = SamplerState(address: ['clamp', 'clamp', 'clamp']);
