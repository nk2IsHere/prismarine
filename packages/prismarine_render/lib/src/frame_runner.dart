import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_kept/prismarine_kept.dart';
import 'package:vector_math/vector_math.dart';

import 'env.dart';
import 'gpu_state.dart';
import 'load_tally.dart';
import 'loose_map.dart';
import 'render_assets.dart';
import 'uniform_ring.dart';

part 'runner_cascades.dart';
part 'runner_compute.dart';
part 'runner_first_uses.dart';
part 'runner_kept.dart';
part 'runner_passes.dart';
part 'runner_prepare.dart';
part 'runner_pulled.dart';
part 'runner_pulled_data.dart';
part 'runner_pulled_parts.dart';
part 'runner_record.dart';
part 'runner_release.dart';
part 'runner_resources.dart';
part 'runner_retained.dart';
part 'runner_slots.dart';
part 'runner_srgb.dart';
part 'runner_stencil.dart';
part 'runner_stores.dart';
part 'runner_warm.dart';

/// Runs a [FramePlan] on the GPU: creates its targets, then records each
/// pass in order on one command buffer, with each shader's constant
/// buffers bound by block and its textures, samplers and texel buffers
/// apart, as Direct3D 11 binds them.
class FrameRunner {
  FrameRunner(this.assets, this.shaders) {
    assets.onOwners = _pipelinesOwned;
  }

  final RenderAssets assets;
  final RunnerShaders shaders;

  /// The stencil copy's shaders when the assets have them, else none (a
  /// read of a stencil then gets a stand-in, runner_resources.dart).
  late final List<String> _stencilCopyShaders =
      assets.hasShader(shaders.stencilCopyVertex) &&
          assets.hasShader(shaders.stencilCopyPixel)
      ? List.unmodifiable([shaders.stencilCopyVertex, shaders.stencilCopyPixel])
      : const <String>[];

  /// Problems worth a log line.
  void Function(String)? warn;

  /// Draws skipped so far, each named once.
  final _failedDraws = <String>{};
  final _failed = <String>{};

  /// Whether every attachment is written back, for reading targets after
  /// a frame (the replay bench's `ours`); else a frame's last use of its
  /// scene and back-buffer depth stores nothing (runner_stores.dart).
  bool keepStores = false;

  /// Our renderer's cooked data: when set, the G-buffer pass draws what it
  /// can in pulled form (runner_pulled.dart).
  Pulled? pulled;

  /// Each pulled pass's frame (runner_pulled.dart).
  final _pulledFrames = <String, _PulledFrame>{};

  /// Prints each draw as it is recorded (`PRISMARINE_RENDER_TRACE=1`).
  static final trace = envVar('RENDER_TRACE') == '1';
  final targets = <String, gpu.Texture>{};
  final _specs = <String, TargetSpec>{};

  /// The pipelines by shaders and vertex feed (a mesh's own: one per mesh
  /// and shader pair), let go with the scenes that asked for them as the
  /// textures and meshes are (RunnerRelease.release).
  final _pipelines = LooseMap<Object, gpu.RenderPipeline>();
  void _pipelinesOwned(int owners) => _pipelines.owners = owners;
  final _tagged = _PipelineTags();

  /// An inline geometry's register map as its pipeline key names it, per
  /// map object (the post draws share a few).
  final _registersKey = Expando<String>('inline registers');
  final _constants = <String, gpu.Texture>{};
  final _views = <String, gpu.Texture>{};

  /// Each sRGB-viewed target's view, with the texture it was made of
  /// (runner_srgb.dart).
  final _srgbViews = <String, (gpu.Texture, gpu.Texture)>{};
  final _slots = Expando<_SlotMaps>('shader slots');
  final _fileTextures = Expando<gpu.Texture>('file textures');
  final _packed = Expando<Map<Object, (gpu.VertexLayout, Uint8List)>>(
    'packed inline vertices',
  );
  final _samplers = <String, gpu.McsmSampler>{};
  final _samplerObjects = Expando<gpu.McsmSampler>('samplers by state');
  final _constantObjects = Expando<Map<String, gpu.Texture>>(
    'constant textures by texel object',
  );

  /// Each depth target's stencil copy, what its stencil can hold, and the
  /// copy's draws by value (runner_stencil.dart).
  final _stencilCopies = <String, gpu.Texture>{};
  final _stencilValues = <String, StencilValues>{};
  final _stencilDraws = <int, DrawPlan>{};

  /// The retained passes' stamps as run (runner_retained.dart) and how
  /// many passes the last run left out.
  final _retained = _Retained();
  int get lastRetained => _retained.left;

  /// Per pixel shader id, the uint textures it declares (the stencil views
  /// a one-draw pass may read, runner_stencil.dart).
  final _stencilReaders = <String, List<String>>{};

  /// The constant textures standing in for an unreadable or missing input,
  /// by kind and shader type.
  final _standIns = <String, gpu.Texture>{};
  final _shaderSlots = Expando<_ShaderSlots>('shader slots by interface');

  /// Bumped whenever a texture a draw's input resolves to may change (a
  /// target made again, a twin or stencil copy made): the stages' resolved
  /// textures (_StageInputs.resolved) hold until then.
  int _texGen = 0;

  /// The constant blocks bound in recent runs with their place in the
  /// uniform ring of the run that last wrote them, by block identity and
  /// size.
  final _uniformViews = HashMap<Uint8List, _UniformView>.identity();

  /// The frame being recorded's role blocks (FramePlan.frameBlocks).
  Map<Uint8List, Uint8List> _frameBlocks = const {};

  /// Each frame role's view in the run that last bound it, by its block.
  final _roleViews = HashMap<Uint8List, _RoleView>.identity();

  /// Whether the plans' byte blocks never change once made (plans read
  /// through the plan codec, whose blocks are its own copies): a block
  /// bound in two runs in a row is then written once into the block store
  /// and bound from there after (runner_slots.dart _uniform). A plan the
  /// builder hands over directly may change a block in place between
  /// frames, so its blocks are written to the ring each frame.
  bool get keepBlocks => _store != null;
  set keepBlocks(bool on) {
    if (on == keepBlocks) return;
    _store = on ? BlockStore() : null;
  }

  BlockStore? _store;
  UniformRing? _host;

  /// The loads [plan] needs that no run made before: the shaders and PNG
  /// textures of the draws not recorded yet (shards and textures stay
  /// loaded), in passes this runner hasn't loaded for, and the dispatches'
  /// shaders; null when there are none (perf: a set over every draw and
  /// three awaits each frame).
  Future<void>? _newLoads(FramePlan plan) {
    final shaders = _loadShaders..clear(), pngs = _loadPngs..clear();
    final passes = _loadPasses..clear();
    final loaded = _loadDraws..clear();
    for (final p in plan.passes) {
      switch (p) {
        case final RenderPassPlan r:
          final c = _passOf(r);
          if (c.loaded) continue;
          passes.add(c);
          final draws = r.allDraws;
          for (var i = 0; i < draws.length; i++) {
            final d = draws[i];
            final c = _cacheOf(d);
            // Recorded, or loaded for before (a pulled row is never
            // recorded: its textures were walked every frame).
            if (c.setup != null || c.loaded) continue;
            loaded.add(c);
            shaders
              ..add(d.vertex)
              ..add(d.pixel ?? _depthOnly(d));
            for (final t in d.pixelResources.textures.values) {
              if (t is FileTexture) pngs.add(t.stem);
            }
          }
        case final DispatchPlan c:
          if (!_shadersLoaded.contains(c.shader)) shaders.add(c.shader);
      }
    }
    if (!_stencilShadersLoaded) shaders.addAll(_stencilCopyShaders);
    if (shaders.isEmpty && pngs.isEmpty) {
      for (final c in passes) {
        c.loaded = true;
      }
      for (final c in loaded) {
        c.loaded = true;
      }
      return null;
    }
    return _load({...shaders}, {...pngs}, [...passes], [...loaded]);
  }

  Future<void> _load(
    Set<String> shaders,
    Set<String> pngs,
    List<_PassCache> passes,
    List<_DrawCache> draws,
  ) async {
    await assets.loadShaders(shaders);
    await assets.loadTextures(pngs);
    _shadersLoaded.addAll(shaders);
    _stencilShadersLoaded = true;
    for (final c in passes) {
      c.loaded = true;
    }
    for (final c in draws) {
      c.loaded = true;
    }
  }

  /// _depthUnstored's walk (runner_stores.dart), kept from run to run.
  final _unstored = KeptSet<RenderPassPlan>.identity();
  final _later = KeptSet<String>(),
      _lastSeen = KeptSet<String>(),
      _used = KeptSet<String>();
  final _lastTarget = KeptList<String>(), _usedOrder = KeptList<String>();
  final _lastPass = KeptList<RenderPassPlan>();
  final _firstClears = KeptMap<String, bool>();

  final _loadShaders = <String>{}, _loadPngs = <String>{};
  final _loadPasses = <_PassCache>[];
  final _loadDraws = <_DrawCache>[];

  /// The shaders loaded by a run (the dispatches' are looked up here).
  final _shadersLoaded = <String>{};
  bool _stencilShadersLoaded = false;

  void _ensureTargets(FramePlan plan) {
    // The same map as last run (the codec gives it again while the targets
    // hold): nothing to make.
    if (identical(plan.targets, _ensured)) return;
    _ensured = plan.targets;
    for (final name in plan.targets.keys) {
      final s = plan.targets[name]!;
      if (_namedAt[name] != _targetEpoch) _namedAt[name] = _targetEpoch;
      final had = _specs[name];
      if (had != null &&
          had.width == s.width &&
          had.height == s.height &&
          had.format == s.format &&
          had.layers == s.layers &&
          had.mips == s.mips &&
          had.samples == s.samples &&
          had.storage == s.storage &&
          had.volume == s.volume) {
        continue;
      }
      final f = pixelFormat(s.format);
      try {
        targets[name] = _create(s, f);
      } catch (e) {
        throw StateError(
          'target $name (${s.width}x${s.height} ${s.format}, ${s.layers} '
          'layers, ${s.mips} mips, ${s.samples} samples'
          '${s.storage ? ', storage' : ''}${s.volume ? ', 3D' : ''}): $e',
        );
      }
      _specs[name] = s;
      if (firstUses) {
        warn?.call(
          'target made ${Timeline.now} $name ${s.width}x${s.height} '
          '${s.format} ${s.layers} layers ${s.mips} mips ${s.samples} samples',
        );
      }
      _views.removeWhere((k, _) => k.startsWith('$name|'));
      _texGen++;
    }
  }

  Map<String, TargetSpec>? _ensured;

  /// The scene-close epoch (RunnerRelease.closed) in which a plan last
  /// named each target.
  final _namedAt = <String, int>{};
  int _targetEpoch = 0;

  gpu.Texture _create(TargetSpec s, gpu.PixelFormat f) =>
      gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        s.width,
        s.height,
        format: f,
        sampleCount: s.samples,
        textureType: s.samples > 1
            ? gpu.TextureType.texture2DMultisample
            : s.volume
            ? gpu.TextureType.texture3D
            : (s.layers > 1 ? gpu.TextureType.texture2DArray : null),
        layers: s.volume ? 1 : s.layers,
        depth: s.volume ? s.layers : 1,
        mipLevelCount: s.mips,
        enableShaderWriteUsage: s.storage,
        // A 3D texture is only written by compute (the light grid).
        enableRenderTargetUsage: !s.volume,
      );

  final _buffers = <String, List<gpu.DeviceBuffer>>{};

  /// The targets filled from the CPU (TargetSpec.initial) of the plan's
  /// target map [_uploadsOf], and the bytes and target each last took
  /// (runner_resources.dart _uploadTargets).
  final _uploadNames = <String>[];
  Map<String, TargetSpec>? _uploadsOf;
  final _uploaded = <String, (Uint8List, gpu.Texture)>{};

  /// Each read-back buffer's bytes once its frame is done on the GPU
  /// (BufferSpec.readBack), and the plan buffers that read back.
  void Function(String name, Uint8List bytes)? onReadBack;
  final _readNames = <String>[];
  Map<String, BufferSpec>? _readsOf;

  /// Bumped whenever a plan buffer is made again: views of the buffers
  /// kept with a draw (_DrawFixed.streamViews) hold until then.
  int _bufferGen = 0;
  final _bufferSizes = <String, int>{}, _bufferRun = <String, int>{};
  var _frame = 0;

  /// This frame's copy of each plan buffer: three in turn, so the CPU fills
  /// one while earlier frames' GPU work may still read the others.
  final _current = <String, gpu.DeviceBuffer>{};

  /// Views into the frame buffers by buffer, offset and length ([_bufferView];
  /// immutable), dropped when buffers are made again ([_viewsGen]).
  final _bufferViews =
      HashMap<gpu.DeviceBuffer, Map<int, gpu.BufferView>>.identity();
  int _viewsGen = -1;

  void _ensureBuffers(FramePlan plan) {
    _frame = (_frame + 1) % 3;
    for (final name in plan.buffers.keys) {
      final spec = plan.buffers[name]!;
      if (_bufferSizes[name] != spec.size) {
        _bufferGen++;
        // The copies of the old size go now (G17): kept views see the
        // generation move on, and the batched skinning's output grows.
        _buffers[name]?.forEach(_release);
        gpu.GpuMemory.tag = 'buffer.plan';
        _buffers[name] = [
          for (var i = 0; i < 3; i++)
            gpu.gpuContext.createDeviceBuffer(
              gpu.StorageMode.hostVisible,
              spec.size,
            ),
        ];
        gpu.GpuMemory.tag = null;
        _bufferSizes[name] = spec.size;
      }
      _bufferRun[name] = _runs;
      final b = _current[name] = _buffers[name]![_frame];
      if (spec.initial case final bytes?) {
        b.overwrite(ByteData.sublistView(bytes));
      }
    }
  }

  gpu.VertexLayout _withStreams(
    gpu.VertexLayout base,
    ShaderRecord shader,
    DrawMeshGeometry g,
  ) => gpu.VertexLayout(
    buffers: [
      ...base.buffers,
      for (final MapEntry(key: register, value: (_, stride, format))
          in g.streams.entries)
        gpu.VertexBuffer(
          strideInBytes: stride,
          attributes: [
            for (final a in shader.attributes)
              if (a.register == register)
                gpu.VertexAttribute(name: a.name, format: streamFormat(format)),
          ],
        ),
    ],
  );

  /// The presentation copies [run] made of its `present` target, in turn,
  /// so a picture on screen is never the one the next frame draws into.
  final _presented = <gpu.Texture>[];
  int _presentTurn = 0;

  /// The last finished frame's copy of its `present` target.
  gpu.Texture? presented;

  /// The last frame's CPU time recording its commands, and the time from
  /// its submission to the GPU's completion (ms; profiles).
  double lastRecordMs = 0, lastGpuMs = 0;

  /// The last frame's GPU time of its own (ms; profiles): from its
  /// submission or the previous frame's completion, whichever is later, to
  /// its completion. Submission to completion counts the wait behind the
  /// frame before it too, which with two frames on the GPU is most of it.
  double lastGpuOwnMs = 0;
  final _gpuClock = Stopwatch()..start();
  int _lastDoneUs = 0;

  /// The last frame's CPU time loading assets (shards included) and
  /// creating pipelines (ms; profiles): the first-use work in its record.
  double lastLoadMs = 0, lastPipelineMs = 0;

  /// The last frame's record split: targets and buffers (of it, targets
  /// made anew, buffers made or written), render passes, dispatches (ms).
  double lastSetupMs = 0, lastRenderMs = 0, lastComputeMs = 0;

  /// The last run's submit, on the timeline clock (diagnostics).
  int lastSubmitAt = 0;
  double lastTargetsMs = 0, lastBuffersMs = 0;
  int lastDraws = 0, lastDispatches = 0;
  double _pipelineMs = 0;

  /// CPU time making vertex layouts (padded stream copies included), and
  /// in pipeline creations that failed and were retried (ms; profiles).
  double _layoutMs = 0, _failedPipelineMs = 0;
  final _clock = Stopwatch()..start();

  /// With `PRISMARINE_RENDER_PASS_LOG` set to a file, the last frame's GPU
  /// work in order, an encoder a line, to name the encoders of a Metal
  /// System Trace.
  static final _passLogPath = envVar('RENDER_PASS_LOG');
  List<String>? _passLog;

  /// Records [plan] and submits it; completes when the GPU is done. With
  /// [present], the frame ends by copying that target into the next of
  /// three presentation textures, [presented] once the GPU is done.
  Future<bool> run(FramePlan plan, {String? present}) async {
    final loadsBefore = assets.loadMs;
    _pipelineMs = 0;
    // A prepare for this frame, if any, runs after this point and sets it.
    lastPrepareMs = 0;
    // Only draws not recorded before: a recorded draw is the same object
    // with the same textures, loaded when it was new, and the textures are
    // never dropped.
    if (_newLoads(plan) case final loads?) await loads;
    if (pulled case final p?) {
      await p.shaders.loadShaders({
        _pulledCull,
        _pulledCascadeCull,
        for (final r in plan.passes.whereType<RenderPassPlan>())
          if (p.passes.contains(r.name))
            for (final d in r.allDraws)
              if (p.shaders.hasShader(d.vertex)) d.vertex,
        for (final r in plan.passes.whereType<RenderPassPlan>())
          if (p.passes.contains(r.name))
            for (final d in r.allDraws)
              if (d.pixel case final px? when p.shaders.hasShader(px)) px,
      });
    }
    final record = Stopwatch()..start();
    _ensureTargets(plan);
    final targetsUs = record.elapsedMicroseconds;
    _ensureBuffers(plan);
    final host = _host ??= UniformRing();
    host.reset();
    // Blocks the last runs bound and this one has not are forgotten now
    // and then (the map keeps each block's views from run to run).
    if (_runs % 64 == 0) {
      _uniformViews.removeWhere((_, v) => v.run < _runs - 2);
      _dropUnnamed();
    }
    _frameBlocks = plan.frameBlocks;
    _runs++;
    _store?.begin();
    final cb = gpu.gpuContext.createCommandBuffer();
    _uploadTargets(cb, plan, host);
    _passLog = _passLogPath == null ? null : [];
    final setup = record.elapsedMicroseconds;
    var computeUs = 0;
    // Consecutive dispatches share one compute pass (an encoder each cost
    // more than the dispatch), until anything else is recorded.
    gpu.ComputePass? compute;
    var draws = 0, dispatches = 0;
    final unstored = _depthUnstored(plan);
    final retained = _retained..begin(plan, _texGen);
    for (final p in plan.passes) {
      if (retained.leaves(p)) continue;
      switch (p) {
        case final RenderPassPlan r:
          compute = null;
          draws += r.allDraws.length;
          final at = record.elapsedMicroseconds;
          _render(cb, r, host, store: !unstored.contains(r));
          _uses?.pass(r.name, record.elapsedMicroseconds - at);
        case final DispatchPlan c:
          final at = record.elapsedMicroseconds;
          if (trace) warn?.call('renderer: dispatch ${c.name} ${c.shader}');
          final copies = _copies;
          _stencilCompute(cb, c, host);
          if (_copies != copies) compute = null;
          compute = _dispatch(cb, c, host, compute);
          dispatches++;
          _passLog?.add('compute ${c.name}');
          computeUs += record.elapsedMicroseconds - at;
          _uses?.pass('compute', record.elapsedMicroseconds - at);
      }
    }
    lastDraws = draws;
    if (_uses case final u?) {
      u.ran(warn, record.elapsedMicroseconds);
    }
    lastDispatches = dispatches;
    lastSetupMs = setup / 1000;
    lastTargetsMs = targetsUs / 1000;
    lastBuffersMs = (setup - targetsUs) / 1000;
    lastComputeMs = computeUs / 1000;
    lastRenderMs = (record.elapsedMicroseconds - setup - computeUs) / 1000;
    gpu.Texture? copy;
    final t = present == null ? null : targets[present];
    if (t != null) {
      copy = _presentCopy(t);
      cb.copyTextureToTexture(
        gpu.TextureRegion(t),
        gpu.TextureDestinationRegion(copy),
      );
    }
    if (_passLog case final log?) {
      if (t != null) log.add('blit present');
      File(_passLogPath!).writeAsStringSync('${log.join('\n')}\n');
    }
    final done = Completer<bool>();
    lastRecordMs = record.elapsedMicroseconds / 1000;
    lastLoadMs = assets.loadMs - loadsBefore;
    lastPipelineMs = _pipelineMs;
    final reads = _readBacks(cb, plan);
    // The frame's constant blocks, written once.
    host.flush();
    _store?.flush();
    final submitted = _gpuClock.elapsedMicroseconds;
    lastSubmitAt = Timeline.now;
    cb.submit(
      completionCallback: (ok) {
        final now = _gpuClock.elapsedMicroseconds;
        lastGpuMs = (now - submitted) / 1000;
        final from = submitted > _lastDoneUs ? submitted : _lastDoneUs;
        lastGpuOwnMs = (now - from) / 1000;
        _lastDoneUs = now;
        if (ok && copy != null) presented = copy;
        if (ok && reads != null) unawaited(_deliverReads(reads));
        done.complete(ok);
      },
    );
    return done.future;
  }

  /// The CPU time of the [prepare] that came with the last frame (ms;
  /// profiles), and of its asset loads (shards, meshes, textures) and
  /// pipeline creation.
  double lastPrepareMs = 0, lastPrepareLoadMs = 0, lastPreparePipelineMs = 0;

  /// The last [prepare]'s vertex layouts, failed pipeline creations and
  /// texture creation (ms; profiles).
  double lastPrepareLayoutMs = 0,
      lastPrepareFailedMs = 0,
      lastPrepareTextureMs = 0;

  /// The last [prepare]'s draws left to their frame (a draw that the
  /// assets cannot feed).
  int lastPrepareErrors = 0;

  gpu.Texture _presentCopy(gpu.Texture t) {
    final k = _presentTurn++ % 3;
    if (k < _presented.length) {
      final had = _presented[k];
      if (had.width == t.width && had.height == t.height) return had;
    }
    final copy = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      t.width,
      t.height,
      format: t.format,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true,
    );
    if (k < _presented.length) {
      _presented[k] = copy;
    } else {
      _presented.add(copy);
    }
    return copy;
  }

  void _render(
    gpu.CommandBuffer cb,
    RenderPassPlan r,
    UniformRing host, {
    bool store = true,
  }) {
    _passLog?.add('render ${r.name} ${r.allDraws.length}');
    _uses?.passName = r.name;
    final p = _passOf(r);
    final d = p.depth;
    // Nothing to bind (no colour, no depth to clear or test): the engine
    // can't begin such a pass, and it would draw nothing.
    if (r.colors.isEmpty && d == null) return;
    // A pulled pass's rows and culling go before the pass begins.
    final prepared = pulled?.passes.contains(r.name) ?? false
        ? _pulledPrepare(cb, r.name, r.allDraws, host, r.rows)
        : null;
    if (r.allDraws.length == 1) _stencilDraw(cb, r.allDraws[0], host);
    final pass = cb.createRenderPass(_renderTarget(p, r, store));
    _warm.shape = p.shape;
    final state = _passState..reset();
    final stencil = d == null ? null : _stencilWrites(d);
    var draws = r.allDraws;
    final pulledPass = prepared != null;
    if (prepared != null) {
      // The stencil copy follows every draw of the pass, pulled or not.
      if (stencil != null) {
        for (var i = 0; i < draws.length; i++) {
          stencil.write(draws[i]);
        }
      }
      _pulledRecord(pass, prepared, host);
      draws = prepared.rest;
      // The pulled draws left the pass's bindings and state unknown.
      pass.clearBindings();
      state.reset();
    }
    // By index (perf: an iterator per pass).
    for (var i = 0; i < draws.length; i++) {
      final draw = draws[i];
      if (!pulledPass) stencil?.write(draw);
      if (trace) {
        warn?.call('renderer: draw ${draw.label} ${draw.vertex} ${draw.pixel}');
      }
      try {
        _draw(pass, draw, host, state);
      } on StateError catch (e) {
        // A draw that the assets cannot feed, for a missing shader input
        // or resource, drops out, named once, and the rest of the frame
        // still draws.
        if (_failedDraws.add('${draw.label}: ${e.message}')) {
          warn?.call('renderer: draw skipped: ${draw.label}: ${e.message}');
        }
      }
    }
  }

  /// The one pass state, reset for each pass (_PassState).
  final _passState = _PassState();

  /// The pixel stage of depth-only draw [d]: the depth-clamp one when its
  /// vertex stage asks for it and the assets have it, else the empty one.
  String _depthOnly(DrawPlan d) =>
      (assets.shaderRecord(d.vertex)?.depthClamp ?? false) &&
          assets.hasShader(shaders.depthClampPixel)
      ? shaders.depthClampPixel
      : shaders.nullPixel;

  void _draw(
    gpu.RenderPass pass,
    DrawPlan d,
    UniformRing host,
    _PassState state,
  ) {
    if (_uses case final u? when _cacheOf(d).fixed == null) {
      final at = _clock.elapsedMicroseconds;
      _drawNew(pass, d, host, state);
      u.drawUs += _clock.elapsedMicroseconds - at;
      return;
    }
    _drawNew(pass, d, host, state);
  }

  void _drawNew(
    gpu.RenderPass pass,
    DrawPlan d,
    UniformRing host,
    _PassState state,
  ) {
    // A draw recorded before (the builder keeps a still batch's draw, and
    // the codec reads it back as the same object) keeps its shaders,
    // pipeline and vertex buffers.
    if (_cacheOf(d).setup case final s?) {
      return _record(pass, d, host, s, state);
    }
    final vs = assets.shader(d.vertex);
    final fs = d.pixel == null ? null : assets.shader(d.pixel!);
    final g = d.geometry;
    _drawWith(pass, d, host, vs, fs, g, state);
  }

  /// Records [d] into [pass]; with no pass, only makes its pipeline and
  /// vertex buffers ([prepare]). Its setup.
  _DrawSetup _drawWith(
    gpu.RenderPass? pass,
    DrawPlan d,
    UniformRing host,
    gpu.Shader vs,
    gpu.Shader? fs,
    DrawGeometry g, [
    _PassState? state,
  ]) {
    gpu.VertexLayout layout;
    List<gpu.DeviceBuffer> slots = const [];
    RenderMesh? mesh;
    Uint8List? inlineVertices;
    // The pipeline's key: the shaders and what feeds the vertex stage (the
    // mesh and the registers fed from frame buffers, or the inline layout).
    final Object key;
    if (g is DrawMeshGeometry) {
      mesh = assets.mesh(g.mesh);
      final info = assets.shaderRecord(d.vertex)!;
      final at = _clock.elapsedMicroseconds;
      (layout, slots) = mesh.layoutFor(d.vertex, info, skip: g.streams.keys);
      final streams = g.streams.isEmpty ? '' : g.streams.keys.join(',');
      key = (d.vertex, d.pixel, g.mesh, streams);
      if (g.streams.isNotEmpty && !_pipelines.containsKey(key)) {
        layout = _withStreams(layout, info, g);
      }
      _layoutMs += (_clock.elapsedMicroseconds - at) / 1000;
    } else if (g is InlineGeometry) {
      final dropped = assets.droppedInputs[d.vertex] ?? const <String>{};
      final registers = _registersKey[g.registers] ??= g.registers.entries
          .map((e) => '${e.key}=${e.value}')
          .join(',');
      // The same vertices (the screen quad) repack once per shader, so their
      // device buffer is made once too.
      final Uint8List packed;
      (layout, packed) =
          (_packed[g.bytes] ??= {})[(
            d.vertex,
            dropped.length,
            g.stride,
            registers,
          )] ??= _inlinePacked(
            assets.shaderRecord(d.vertex)!,
            g,
            dropped,
          );
      inlineVertices = packed;
      key = (d.vertex, d.pixel, g.stride, registers);
    } else {
      layout = const gpu.VertexLayout(buffers: []);
      key = (d.vertex, d.pixel);
    }
    gpu.RenderPipeline pipeline;
    final tried = _clock.elapsedMicroseconds;
    try {
      pipeline =
          _pipelines[key] ??
          _tagged.made(this, key, () {
            final sw = Stopwatch()..start();
            final p = gpu.gpuContext.createRenderPipeline(
              vs,
              fs ?? assets.shader(_depthOnly(d)),
              vertexLayout: layout,
            );
            final ms = sw.elapsedMicroseconds / 1000;
            _pipelineMs += ms;
            assets.tally.add(LoadTally.pipeline, ms);
            return p;
          }());
      if (_tagged.any) _tagged.used(this, key);
    } on Exception catch (e) {
      _failedPipelineMs += (_clock.elapsedMicroseconds - tried) / 1000;
      // An input the translation declares but the compiled stage dropped
      // (unread, so spirv-opt removed it): leave it out of the layout.
      final m = RegExp(
        r"VertexAttribute name '(\w+)' does not match",
      ).firstMatch('$e');
      if (m == null) rethrow;
      if (!assets.dropInput(d.vertex, m[1]!)) rethrow;
      return _drawWith(pass, d, host, vs, fs, g, state);
    }
    final setup = (
      vs: vs,
      fs: fs,
      pipeline: pipeline,
      mesh: mesh,
      slots: slots,
      inlineVertices: inlineVertices,
    );
    if (pass == null || state == null) return setup;
    _record(pass, d, host, _cacheOf(d).setup = setup, state);
    return setup;
  }

  /// Binds [res] to [shader]'s interface; [bound] holds what this pass
  /// bound last to each of its blocks, textures and samplers (in that
  /// order), which is not sent again.
  void _bind(
    gpu.RenderPass pass,
    gpu.Shader shader,
    String id,
    StageResources res,
    UniformRing host,
    _Bound bound,
  ) {
    var c = res.runnerState;
    if (c is! _StageInputs ||
        !identical(c.runner, this) ||
        !(identical(c.id, id) || c.id == id)) {
      c = _StageInputs(this, id, assets.shaderRecord(id)!, res);
      res.runnerState = c;
    }
    final info = c.info;
    var slots = c.slots;
    if (slots == null || !identical(slots.shader, shader)) {
      slots = c.slots = _slotsOf(shader, info);
    }
    // The stage's textures as this runner resolves them, again only when
    // a target, twin or stencil copy is made since (_texGen).
    final resolved = c.resolved;
    final fresh = c.gen == _texGen;
    final last = bound.of(info);
    final blocks = c.blocks.length, textures = c.textures.length;
    for (var i = 0; i < blocks; i++) {
      // The declared rows only: a plan's blocks may be longer.
      final view = _stageUniform(host, c, i);
      if (identical(last[i], view)) continue;
      pass.bindUniform(
        slots.uniforms[i] ??= _uniformSlot(shader, info.blocks[i].name),
        view,
      );
      last[i] = view;
    }
    for (var i = 0; i < textures; i++) {
      final t = info.textures[i];
      final ref = c.textures[i];
      if (c.texel[i]) {
        // Two locals, not a record (one per texel bind; perf).
        final gpu.BufferView view;
        final String format;
        if (ref is BufferTexture) {
          final b = ref.bytes;
          view = _inline(b.isEmpty ? _frameBlocks[b] ?? b : b);
          format = ref.format;
        } else if (ref is BufferTextureRef) {
          // The slot's record checked before a view is made (perf: a view
          // per texel bind a frame, most binding what they bound).
          final r = ref.ref;
          format = r.format ?? 'R32G32B32A32_FLOAT';
          final had = last[blocks + i];
          final buf = _current[r.buffer];
          if (had is _TexelBound &&
              buf != null &&
              identical(had.buffer, buf) &&
              had.offset == r.offset &&
              had.length == (r.size ?? buf.sizeInBytes - r.offset) &&
              had.format == format) {
            continue;
          }
          view = _bufferView(r);
        } else {
          view = _inline(_zeroTexel);
          format = 'R32G32B32A32_FLOAT';
        }
        final had = last[blocks + i];
        if (had is _TexelBound &&
            identical(had.buffer, view.buffer) &&
            had.offset == view.offsetInBytes &&
            had.length == view.lengthInBytes &&
            had.format == format) {
          continue;
        }
        pass.bindTexelBuffer(
          slots.textures[i] ??= _texelSlot(shader, t.name),
          view,
          _formatOf(format),
        );
        // The slot's own record changed in place (perf: one per bind).
        if (had is _TexelBound) {
          had
            ..buffer = view.buffer
            ..offset = view.offsetInBytes
            ..length = view.lengthInBytes
            ..format = format;
        } else {
          last[blocks + i] = _TexelBound(
            view.buffer,
            view.offsetInBytes,
            view.lengthInBytes,
            format,
          );
        }
        continue;
      }
      final texture = fresh
          ? resolved[i]!
          : resolved[i] = _texture(ref, t.type);
      if (!fresh) _uses?.use(texture);
      if (identical(last[blocks + i], texture)) continue;
      pass.bindSeparateTexture(
        slots.textures[i] ??= _textureSlot(shader, t.name),
        texture,
      );
      last[blocks + i] = texture;
    }
    c.gen = _texGen;
    for (var i = 0; i < c.samplers.length; i++) {
      final sampler = c.samplers[i];
      if (identical(last[blocks + textures + i], sampler)) continue;
      pass.bindSeparateSampler(
        slots.samplers[i] ??= _samplerSlot(shader, info.samplers[i].$1),
        sampler,
      );
      last[blocks + textures + i] = sampler;
    }
  }

  final _computePipelines = <String, gpu.ComputePipeline>{};
  final _computeSetups = <String, _ComputeSetup>{};

  /// What the open compute pass's dispatches read and wrote since its last
  /// barrier (runner_compute.dart).
  final _sinceBarrier = _Access();

  /// What this runner keeps with draw [d] (DrawPlan.runnerState).
  _DrawCache _cacheOf(DrawPlan d) {
    final c = d.runnerState;
    if (c is _DrawCache && identical(c.runner, this)) return c;
    final made = _DrawCache(this);
    d.runnerState = made;
    return made;
  }

  // Whole-buffer views by bytes object, each holding its buffer (perf: a
  // view per binding a frame), let go once unbound for a while.
  final _inlineBuffers = Map<Uint8List, _InlineBuffer>.identity();
  final _vertexBuffers = Map<Uint8List, _InlineBuffer>.identity();

  /// The run in which a draw's inline bytes were first bound
  /// (runner_resources.dart _drawBytes).
  final _firstRun = Expando<int>('inline bytes first run');

  /// Each dispatch input's per-frame buffers (_frameInline), and the runs
  /// recorded so far (which run bound one last).
  final _inlineSlots = <String, Map<String, _InlineSlot>>{};
  int _runs = 0;

  /// With `PRISMARINE_FRAME_LOG` set, what each run did for the first time
  /// (runner_first_uses.dart).
  static final firstUses = envVar('FRAME_LOG') != null;
  final _uses = firstUses ? _FirstUses() : null;

  /// What draws listed ahead make before their first frame
  /// (runner_warm.dart).
  final _warm = _Warm();

  /// Copies recorded so far (runner_stencil.dart): a dispatch after one
  /// opens a compute pass of its own.
  int _copies = 0;
}

/// What a runner keeps with a draw: its setup once recorded and the
/// targets it reads.
final class _DrawCache {
  _DrawCache(this.runner);
  final FrameRunner runner;
  _DrawSetup? setup;

  /// The targets it samples, by name (runner_stores.dart).
  List<String>? reads;

  /// Its state and geometry as the engine binds them (runner_record.dart).
  _DrawFixed? fixed;

  /// Whether a run loaded its shaders and textures (FrameRunner._newLoads).
  bool loaded = false;

  /// As the first draw of a pulled bucket: its setup and fixed state
  /// (runner_pulled.dart).
  _DrawSetup? pulled;
  _DrawFixed? pulledFixed;
}

/// A recorded draw's shaders, pipeline and vertex sources: functions of
/// its shaders and geometry alone once its pipeline is made.
typedef _DrawSetup = ({
  gpu.Shader vs,
  gpu.Shader? fs,
  gpu.RenderPipeline pipeline,
  RenderMesh? mesh,
  List<gpu.DeviceBuffer> slots,
  Uint8List? inlineVertices,
});

/// The texel buffer an input the plan leaves out reads (zeros).
final _zeroTexel = Uint8List(16);
