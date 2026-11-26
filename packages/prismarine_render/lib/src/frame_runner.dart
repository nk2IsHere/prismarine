import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_kept/prismarine_kept.dart';
import 'package:vector_math/vector_math.dart';

import 'env.dart';
import 'gpu_state.dart';
import 'gpu_submit.dart';
import 'load_tally.dart';
import 'loose_map.dart';
import 'render_assets.dart';
import 'uniform_ring.dart';

part 'runner_cascades.dart';
part 'runner_compute.dart';
part 'runner_first_uses.dart';
part 'runner_kept.dart';
part 'runner_passes.dart';
part 'runner_present.dart';
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
part 'runner_targets.dart';
part 'runner_timing.dart';
part 'runner_warm.dart';

/// Runs a [FramePlan] on the GPU. Creates its targets, then records each
/// pass in order on one command buffer. The constant buffers of each shader
/// are bound by block and its textures, samplers and texel buffers apart, as
/// Direct3D 11 binds them.
class FrameRunner {
  FrameRunner(this.assets, this.shaders) {
    assets.onOwners = _pipelinesOwned;
  }

  final RenderAssets assets;
  final RunnerShaders shaders;

  /// The shaders of the stencil copy when the assets have them, else none.
  /// A read of a stencil then gets a stand-in (runner_resources.dart).
  late final List<String> _stencilCopyShaders =
      assets.hasShader(shaders.stencilCopyVertex) &&
          assets.hasShader(shaders.stencilCopyPixel)
      ? List.unmodifiable([shaders.stencilCopyVertex, shaders.stencilCopyPixel])
      : const <String>[];

  /// Receives the problems worth a log line.
  void Function(String)? warn;

  /// The draws skipped so far, each reported once.
  final _failedDraws = <String>{};
  final _failed = <String>{};

  /// True when every attachment is written back, for reading targets after
  /// a frame. Otherwise the last use of a depth target that no later pass
  /// reads stores nothing (runner_stores.dart).
  bool keepStores = false;

  /// The cooked data. With it set, the pulled passes draw what they can in
  /// pulled form (runner_pulled.dart).
  Pulled? pulled;

  /// The frame of each pulled pass (runner_pulled.dart).
  final _pulledFrames = <String, _PulledFrame>{};

  /// Prints each draw as it is recorded (`PRISMARINE_RENDER_TRACE=1`).
  static final trace = envVar('RENDER_TRACE') == '1';
  final targets = <String, gpu.Texture>{};
  final _specs = <String, TargetSpec>{};

  /// The pipelines by shaders and vertex feed, one per mesh and shader pair
  /// for the own feed of a mesh. They are let go with the scenes that asked
  /// for them, as the textures and meshes are (RunnerRelease.release).
  final _pipelines = LooseMap<Object, gpu.RenderPipeline>();
  void _pipelinesOwned(int owners) => _pipelines.owners = owners;
  final _tagged = _PipelineTags();

  /// The register map of an inline geometry in the form of its pipeline key,
  /// per map object.
  final _registersKey = Expando<String>('inline registers');
  final _constants = <String, gpu.Texture>{};
  final _views = <String, gpu.Texture>{};

  /// The sRGB view of each target, with the texture that it was made of
  /// (runner_srgb.dart).
  final _srgbViews = <String, (gpu.Texture, gpu.Texture)>{};
  final _slots = Expando<_SlotMaps>('shader slots');
  final _fileTextures = Expando<gpu.Texture>('file textures');

  /// The one-layer array views of file textures that no cooked array holds,
  /// for the pulled draws (runner_pulled.dart).
  final _fileArrays = Expando<gpu.Texture>('file arrays');
  final _packed = Expando<Map<Object, (gpu.VertexLayout, Uint8List)>>(
    'packed inline vertices',
  );
  final _samplers = <String, gpu.PrismarineSampler>{};
  final _samplerObjects = Expando<gpu.PrismarineSampler>('samplers by state');
  final _constantObjects = Expando<Map<String, gpu.Texture>>(
    'constant textures by texel object',
  );

  /// The stencil copy of each depth target, the values that its stencil can
  /// hold and the draws of the copy by value (runner_stencil.dart).
  final _stencilCopies = <String, gpu.Texture>{};
  final _stencilValues = <String, StencilValues>{};
  final _stencilDraws = <int, DrawPlan>{};

  /// The stamps of the retained passes as run (runner_retained.dart) and
  /// the number of passes that the last run left out.
  final _retained = _Retained();
  int get lastRetained => _retained.left;

  /// The uint textures that each pixel shader declares, by id. These are the
  /// stencil views that a one-draw pass may read (runner_stencil.dart).
  final _stencilReaders = <String, List<String>>{};

  /// The constant textures standing in for an unreadable or missing input,
  /// by kind and shader type.
  final _standIns = <String, gpu.Texture>{};
  final _shaderSlots = Expando<_ShaderSlots>('shader slots by interface');

  /// Raised when a new target, twin or stencil copy may change the textures
  /// of draw inputs, which _StageInputs.resolved holds until then.
  int _texGen = 0;

  /// The constant blocks bound in recent runs, by identity and size, with
  /// their place in the uniform ring of the run that last wrote them.
  final _uniformViews = HashMap<Uint8List, _UniformView>.identity();

  /// The role blocks of the frame being recorded (FramePlan.frameBlocks).
  Map<Uint8List, Uint8List> _frameBlocks = const {};

  /// The view of each frame role in the run that last bound it, by block.
  final _roleViews = HashMap<Uint8List, _RoleView>.identity();

  /// True when the byte blocks of the plans do not change once made, as in
  /// plans read through the plan codec. A block bound in two runs in a row
  /// then goes once into the block store (runner_slots.dart _uniform). Plans
  /// that change blocks in place between frames must leave this false.
  bool get keepBlocks => _store != null;
  set keepBlocks(bool on) {
    if (on == keepBlocks) return;
    _store = on ? BlockStore() : null;
  }

  BlockStore? _store;
  UniformRing? _host;

  /// Returns the loads that [plan] needs and that no run made before, or null
  /// when there are none. These are the shaders and PNG textures of the draws
  /// not recorded yet in passes that this runner has not loaded for and the
  /// shaders of the dispatches. Shards and textures stay loaded.
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
            // A draw recorded or loaded for before is skipped. A pulled row
            // is not recorded and relies on the loaded flag.
            if (c.setup != null || c.loaded) continue;
            loaded.add(c);
            shaders
              ..add(d.vertex)
              ..add(d.pixel ?? _depthOnly(d));
            // alloc: a draw's first run
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
    // alloc: a run with shaders or textures to load
    return _load({...shaders}, {...pngs}, [...passes], [...loaded]);
  }

  // alloc-cold: a run with shaders or textures to load.
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

  /// The walk of _depthUnstored (runner_stores.dart), kept from run to run.
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

  /// The shaders loaded by a run. The shaders of dispatches are looked up
  /// here.
  final _shadersLoaded = <String>{};
  bool _stencilShadersLoaded = false;

  Map<String, TargetSpec>? _ensured;

  /// The scene-close epoch (RunnerRelease.closed) in which a plan last used
  /// each target.
  final _namedAt = <String, int>{};
  int _targetEpoch = 0;

  final _buffers = <String, List<gpu.DeviceBuffer>>{};

  /// The targets filled from the CPU (TargetSpec.initial) of the target map
  /// [_uploadsOf] of the plan, with the bytes and target that each last took
  /// (runner_resources.dart _uploadTargets).
  final _uploadNames = <String>[];
  Map<String, TargetSpec>? _uploadsOf;
  final _uploaded = <String, (Uint8List, gpu.Texture)>{};

  /// Receives the bytes of each read-back buffer (BufferSpec.readBack) once
  /// its frame is done on the GPU.
  void Function(String name, Uint8List bytes)? onReadBack;
  final _readNames = <String>[];
  Map<String, BufferSpec>? _readsOf;

  /// Raised whenever a plan buffer is made again. Views of the buffers kept
  /// with a draw (_DrawFixed.streamViews) hold until then.
  int _bufferGen = 0;
  final _bufferSizes = <String, int>{}, _bufferRun = <String, int>{};
  var _frame = 0;

  /// The copy of each plan buffer for this frame. Three copies take turns. The
  /// CPU fills one while the GPU work of earlier frames may still read the
  /// others.
  final _current = <String, gpu.DeviceBuffer>{};

  /// The views into the frame buffers by buffer, offset and length from
  /// [_bufferView]. They do not change and are dropped when buffers are made
  /// again ([_viewsGen]).
  final _bufferViews =
      HashMap<gpu.DeviceBuffer, Map<int, gpu.BufferView>>.identity();
  int _viewsGen = -1;

  void _ensureBuffers(FramePlan plan) {
    _frame = (_frame + 1) % 3;
    for (final name in plan.buffers.keys) {
      final spec = plan.buffers[name]!;
      if (_bufferSizes[name] != spec.size) {
        _bufferGen++;
        // The copies of the old size go now (G17). Kept views see the new
        // generation.
        _buffers[name]?.forEach(_release);
        gpu.GpuMemory.tag = 'buffer.plan';
        // alloc: a plan buffer of a new size
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

  /// The presentation copies that [run] made of its `present` target, in
  /// turn. A picture on screen is then not the one that the next frame draws
  /// into.
  final _presented = <gpu.Texture>[];
  int _presentTurn = 0;

  /// The copy of the `present` target of the last finished frame.
  gpu.Texture? presented;

  /// The CPU time in ms of the last frame to record its commands and the
  /// time from its submission to the completion on the GPU.
  double lastRecordMs = 0, lastGpuMs = 0;

  /// The own GPU time in ms of the last frame, from its submission or the
  /// completion of the previous frame, whichever is later, to its completion.
  double lastGpuOwnMs = 0;

  /// The passes that start a timed part of the frame. Each part is recorded
  /// into a command buffer of its own. Empty for one command buffer.
  List<String> timedParts = const [];

  /// The GPU time in ms of each part of the last finished frame. The part
  /// before the first pass of [timedParts] comes first.
  final lastPartGpuMs = Float64List(maxTimedParts);
  late final _timing = _Timing(_gpuClock);
  final _gpuClock = Stopwatch()..start();
  int _lastDoneUs = 0;

  /// The CPU time in ms of the last frame to load assets with their shards and
  /// to create pipelines. It is the first-use work in its record.
  double lastLoadMs = 0, lastPipelineMs = 0;

  /// The record of the last frame in ms, split into targets and buffers,
  /// render passes and dispatches.
  double lastSetupMs = 0, lastRenderMs = 0, lastComputeMs = 0;

  /// The submit of the last run on the timeline clock.
  int lastSubmitAt = 0;
  double lastTargetsMs = 0, lastBuffersMs = 0;
  int lastDraws = 0, lastDispatches = 0;
  double _pipelineMs = 0;

  /// The CPU time in ms to make vertex layouts with padded stream copies and
  /// the time in pipeline creations that failed and were retried.
  double _layoutMs = 0, _failedPipelineMs = 0;
  final _clock = Stopwatch()..start();

  /// The file of `PRISMARINE_RENDER_PASS_LOG`, which receives the GPU work
  /// of the last frame in order, one encoder per line. It matches the
  /// encoders of a Metal System Trace.
  static final _passLogPath = envVar('RENDER_PASS_LOG');
  List<String>? _passLog;

  /// Records [plan] and submits it. Completes when the GPU is done. With
  /// [present] the frame ends by copying that target into the next of three
  /// presentation textures, which is [presented] once the GPU is done.
  Future<bool> run(FramePlan plan, {String? present}) async {
    final loadsBefore = assets.loadMs;
    _pipelineMs = 0;
    // A prepare for this frame runs after this point and sets it.
    lastPrepareMs = 0;
    // Only draws not recorded before load. A recorded draw is the same
    // object with the same textures, which were loaded when it was new and
    // stay loaded.
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
    // alloc: the first run of the runner
    final host = _host ??= UniformRing();
    host.reset();
    // Blocks that the last runs bound and this run has not are forgotten
    // now and then. The map keeps the views of each block from run to run.
    if (_runs % 64 == 0) {
      // alloc: every 64 runs
      _uniformViews.removeWhere((_, v) => v.run < _runs - 2);
      _dropUnnamed();
    }
    _frameBlocks = plan.frameBlocks;
    _runs++;
    _store?.begin();
    var cb = gpu.gpuContext.createCommandBuffer();
    _uploadTargets(cb, plan, host);
    // alloc: PRISMARINE_RENDER_PASS_LOG runs only
    _passLog = _passLogPath == null ? null : [];
    final setup = record.elapsedMicroseconds;
    var computeUs = 0;
    // Consecutive dispatches share one compute pass until anything else is
    // recorded. An encoder per dispatch would cost more than the dispatch.
    gpu.ComputePass? compute;
    var draws = 0, dispatches = 0;
    final unstored = _depthUnstored(plan);
    final retained = _retained..begin(plan, _texGen);
    final timing = _timing..begin(timedParts);
    for (final p in plan.passes) {
      if (timedParts.isNotEmpty && timing.starts(p.name)) {
        cb = timing.cut(cb);
        compute = null;
      }
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
          // alloc: PRISMARINE_RENDER_TRACE runs only
          if (trace) warn?.call('renderer: dispatch ${c.name} ${c.shader}');
          final copies = _copies;
          _stencilCompute(cb, c, host);
          if (_copies != copies) compute = null;
          compute = _dispatch(cb, c, host, compute);
          dispatches++;
          // alloc: PRISMARINE_RENDER_PASS_LOG runs only
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
      // alloc: PRISMARINE_RENDER_PASS_LOG runs only
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
    timing.submit();
    final cuts = timing.cuts;
    gpuSubmitted();
    cb.submit(
      completionCallback: (ok) {
        final now = _gpuClock.elapsedMicroseconds;
        lastGpuMs = (now - submitted) / 1000;
        final from = submitted > _lastDoneUs ? submitted : _lastDoneUs;
        lastGpuOwnMs = (now - from) / 1000;
        _timing.read(lastPartGpuMs, cuts, from, now);
        _lastDoneUs = now;
        if (ok && copy != null) presented = copy;
        if (ok && reads != null) unawaited(_deliverReads(reads));
        done.complete(ok);
      },
    );
    return done.future;
  }

  /// The CPU time in ms of the [prepare] that came with the last frame, of
  /// its asset loads of shards, meshes and textures and of its pipeline
  /// creation.
  double lastPrepareMs = 0, lastPrepareLoadMs = 0, lastPreparePipelineMs = 0;

  /// The time in ms of the vertex layouts, failed pipeline creations and
  /// texture creation of the last [prepare].
  double lastPrepareLayoutMs = 0,
      lastPrepareFailedMs = 0,
      lastPrepareTextureMs = 0;

  /// The draws of the last [prepare] that the assets cannot feed, left to
  /// their frame.
  int lastPrepareErrors = 0;

  void _render(
    gpu.CommandBuffer cb,
    RenderPassPlan r,
    UniformRing host, {
    bool store = true,
  }) {
    // alloc: PRISMARINE_RENDER_PASS_LOG runs only
    _passLog?.add('render ${r.name} ${r.allDraws.length}');
    _uses?.passName = r.name;
    final p = _passOf(r);
    final d = p.depth;
    // A pass without colour and without depth to clear or test draws
    // nothing. The engine cannot begin it.
    if (r.colors.isEmpty && d == null) return;
    // The rows and culling of a pulled pass go before the pass begins.
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
      if (prepared.restAfter case final after?) {
        // The plan's order kept: each draw left to its record goes between
        // the buckets made before and after it.
        final rest = prepared.rest;
        var r = 0;
        for (var b = 0; b <= prepared.ranges.length; b++) {
          if (r < rest.length && after[r] <= b) {
            // A bucket left the bindings and state of the pass unknown.
            pass.clearBindings();
            state.reset();
            while (r < rest.length && after[r] <= b) {
              _drawOne(pass, rest[r++], host, state);
            }
          }
          if (b < prepared.ranges.length) {
            _pulledRecordOne(pass, prepared, b, host);
          }
        }
        return;
      }
      _pulledRecord(pass, prepared, host);
      draws = prepared.rest;
      // The pulled draws left the bindings and state of the pass unknown.
      pass.clearBindings();
      state.reset();
    }
    // By index, without an iterator.
    for (var i = 0; i < draws.length; i++) {
      final draw = draws[i];
      if (!pulledPass) stencil?.write(draw);
      _drawOne(pass, draw, host, state);
    }
  }

  /// Records [draw] into [pass]: a draw that the assets cannot feed, for a
  /// missing shader input or resource, drops out and is reported once. The
  /// rest of the frame still draws.
  void _drawOne(
    gpu.RenderPass pass,
    DrawPlan draw,
    UniformRing host,
    _PassState state,
  ) {
    if (trace) {
      // alloc: PRISMARINE_RENDER_TRACE runs only
      warn?.call('renderer: draw ${draw.label} ${draw.vertex} ${draw.pixel}');
    }
    try {
      _draw(pass, draw, host, state);
    } on StateError catch (e) {
      // alloc: a draw that the assets cannot feed
      if (_failedDraws.add('${draw.label}: ${e.message}')) {
        // alloc: once per draw that the assets cannot feed
        warn?.call('renderer: draw skipped: ${draw.label}: ${e.message}');
      }
    }
  }

  /// The one pass state (_PassState), reset for each pass.
  final _passState = _PassState();

  /// Returns the pixel stage of the depth-only draw [d]. It is the
  /// depth-clamp stage when the vertex stage of [d] asks for it and the
  /// assets have it, else the empty stage.
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
    // A draw recorded before keeps its shaders, pipeline and vertex buffers.
    // The builder keeps the draw of a still batch and the codec reads it back
    // as the same object.
    if (_cacheOf(d).setup case final s?) {
      return _record(pass, d, host, s, state);
    }
    final vs = assets.shader(d.vertex);
    final fs = d.pixel == null ? null : assets.shader(d.pixel!);
    final g = d.geometry;
    _drawWith(pass, d, host, vs, fs, g, state);
  }

  // alloc-cold: a draw's first record, which makes its setup.
  /// Records [d] into [pass] and returns its setup. Without a pass it only
  /// makes the pipeline and vertex buffers of [d] for [prepare].
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
    // The key of the pipeline is the shaders and the feed of the vertex
    // stage, the mesh and the registers fed from frame buffers or the inline
    // layout.
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
      // The same vertices, such as the screen quad, repack once per shader.
      // Their device buffer is then made once too.
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
      // An input that the source declares but the compiled stage dropped,
      // since spirv-opt removed it as unread, stays out of the layout.
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

  /// Binds [res] to the interface of [shader]. [bound] holds what this pass
  /// bound last to each of its blocks, textures and samplers, in that order.
  /// A binding that is the same is not sent again.
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
      // alloc: the first bind of the resources of a stage on this runner
      c = _StageInputs(this, id, assets.shaderRecord(id)!, res);
      res.runnerState = c;
    }
    final info = c.info;
    var slots = c.slots;
    if (slots == null || !identical(slots.shader, shader)) {
      slots = c.slots = _slotsOf(shader, info);
    }
    // The textures of the stage as this runner resolves them. They resolve
    // again only after a new target, twin or stencil copy (_texGen).
    final resolved = c.resolved;
    final fresh = c.gen == _texGen;
    final last = bound.of(info);
    final blocks = c.blocks.length, textures = c.textures.length;
    for (var i = 0; i < blocks; i++) {
      // Only the declared rows are bound. The blocks of a plan may be longer.
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
        // Two locals, not a record per texel bind.
        final gpu.BufferView view;
        final String format;
        if (ref is BufferTexture) {
          final b = ref.bytes;
          view = _inline(b.isEmpty ? _frameBlocks[b] ?? b : b);
          format = ref.format;
        } else if (ref is BufferTextureRef) {
          // The record of the slot is checked before a view is made. Most
          // texel binds bind what they bound before.
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
        // The record of the slot changes in place.
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

  /// The reads and writes of the dispatches of the open compute pass since
  /// its last barrier (runner_compute.dart).
  final _sinceBarrier = _Access();

  /// Returns the state that this runner keeps with the draw [d]
  /// (DrawPlan.runnerState).
  _DrawCache _cacheOf(DrawPlan d) {
    final c = d.runnerState;
    if (c is _DrawCache && identical(c.runner, this)) return c;
    // alloc: a draw's first run on this runner
    final made = _DrawCache(this);
    d.runnerState = made;
    return made;
  }

  // Whole-buffer views by bytes object, each holding its buffer. They are let
  // go once unbound for a while.
  final _inlineBuffers = Map<Uint8List, _InlineBuffer>.identity();
  final _vertexBuffers = Map<Uint8List, _InlineBuffer>.identity();

  /// The run in which the inline bytes of a draw were first bound
  /// (runner_resources.dart _drawBytes).
  final _firstRun = Expando<int>('inline bytes first run');

  /// The per-frame buffers of each dispatch input (_frameInline) and the
  /// runs recorded so far, which tell the run that last bound one.
  final _inlineSlots = <String, Map<String, _InlineSlot>>{};
  int _runs = 0;

  /// True with `PRISMARINE_FRAME_LOG` set. Each run then logs its first uses
  /// (runner_first_uses.dart).
  static final firstUses = envVar('FRAME_LOG') != null;
  final _uses = firstUses ? _FirstUses() : null;

  /// The work that draws listed ahead do before their first frame
  /// (runner_warm.dart).
  final _warm = _Warm();

  /// The copies recorded so far (runner_stencil.dart). A dispatch after a
  /// copy opens a compute pass of its own.
  int _copies = 0;
}

/// The state that a runner keeps with a draw, its setup once recorded and
/// the targets that it reads.
final class _DrawCache {
  _DrawCache(this.runner);
  final FrameRunner runner;
  _DrawSetup? setup;

  /// The targets that it samples, by name (runner_stores.dart).
  List<String>? reads;

  /// The state and geometry of the draw as the engine binds them
  /// (runner_record.dart).
  _DrawFixed? fixed;

  /// True when a run loaded its shaders and textures (FrameRunner._newLoads).
  bool loaded = false;

  /// The setup and fixed state of the draw as the first draw of a pulled
  /// bucket (runner_pulled.dart).
  _DrawSetup? pulled;
  _DrawFixed? pulledFixed;
}

/// The shaders, pipeline and vertex sources of a recorded draw. Once its
/// pipeline is made they depend on its shaders and geometry alone.
typedef _DrawSetup = ({
  gpu.Shader vs,
  gpu.Shader? fs,
  gpu.RenderPipeline pipeline,
  RenderMesh? mesh,
  List<gpu.DeviceBuffer> slots,
  Uint8List? inlineVertices,
});

/// The texel buffer of zeros for an input that the plan leaves out.
final _zeroTexel = Uint8List(16);
