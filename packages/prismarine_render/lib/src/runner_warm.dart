// Takes the first-use work out of the first frame of a scene. A draw listed
// ahead of the open of its scene makes its first-record work over the frames
// before. FrameRunner.prepareSome queues the draw and warmSome makes its work.
// The work is the cooked data of its pulled form and the pipeline state objects
// of the engine for its future passes.
part of 'frame_runner.dart';

/// The parts of a pass that its pipeline state objects depend on beyond
/// the draw, the formats and sample count of its attachments. They form the
/// pipeline key of flutter_gpu.
final class _PassShape {
  _PassShape(this.colors, this.depth, this.samples)
    : key = '${colors.map((f) => f.index).join(',')}|${depth?.index}|$samples';
  final List<gpu.PixelFormat> colors;
  final gpu.PixelFormat? depth;
  final int samples;
  final String key;

  @override
  bool operator ==(Object other) => other is _PassShape && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// A draw listed ahead and made ready ([FrameRunner.prepareSome]) that waits
/// for its first-frame work, with its setup when made by record and its
/// scene.
typedef _Listed = (DrawPlan, _DrawSetup?, String?);

/// A draw that waits for its pipeline states, with its setup and a flag for
/// the pulled form.
typedef _WarmItem = (DrawPlan, _DrawSetup, bool);

/// The passes that each program effect draws in, learned by the runner from the
/// frames that it records, with the draws that wait to have their states made.
final class _Warm {
  /// The mode of PRISMARINE_FIRST_FRAME. `off` gives listed draws no pulled
  /// form or pipeline states ahead. `pulled` or `states` gives only the one.
  static final _mode = envVar('FIRST_FRAME') ?? 'on';
  static final on = _mode != 'off';
  static final pulledOn = on && _mode != 'states';

  /// Pipeline states are made ahead on Metal only. Its draw of nothing reads
  /// no binding. On Vulkan the draw binds a descriptor set that the warm draw
  /// did not fill, which its rules allow only for descriptors that no stage
  /// uses.
  static final statesOn = on && _mode != 'pulled' && Platform.isMacOS;

  /// The shape of the pass that is being recorded (FrameRunner._render).
  _PassShape? shape;

  /// The shapes of the passes that the draws of each effect were recorded
  /// in, by record and in pulled form. The effect is the folder of a shader
  /// id.
  final _shapes = <String, Set<_PassShape>>{};
  final _pulledShapes = <String, Set<_PassShape>>{};
  final _effects = <String, String>{};

  /// The draws made ready that wait for their pulled form, then in [ready]
  /// those that wait for their states. [busy] is true while a
  /// [RunnerWarm.warmSome] runs.
  final queue = Queue<_Listed>();
  final ready = Queue<_WarmItem>();
  bool busy = false;

  /// The compute shaders that the frames of coming scenes will dispatch,
  /// made ready first.
  final computes = Queue<String>();

  /// The cooked scenes read ahead whole (RunnerWarm.cookedAhead) and a flag
  /// for a running step.
  final _cooked = <String>{};
  bool cookedBusy = false;

  /// The scene whose draws are being made ready now, if not the one shown.
  /// Their pulled forms take their meshes from its cooked scene
  /// (Pulled.batch).
  String? pulledScene;

  /// The pipeline states made so far by pipeline, shape and state, with a tiny
  /// target per shape for making them.
  final _made = <String>{};
  final _targets = <_PassShape, gpu.RenderTarget>{};
  gpu.BufferView? _zeroArgs;

  /// The number of states made and of those that the engine could not make,
  /// with the time in ms to make them.
  int states = 0, failed = 0;
  double ms = 0;

  // alloc: once per shader id.
  String effectOf(String id) => _effects[id] ??= _effectOf(id);

  static String _effectOf(String id) {
    final i = id.indexOf('/');
    return i < 0 ? id : id.substring(0, i);
  }

  /// Learns the shape of the pass being recorded for the effect of [vertex],
  /// whose draw is recorded there for the first time, by record or in
  /// [pulled] form.
  void learn(String vertex, {required bool pulled}) {
    final s = shape;
    if (s == null) return;
    final m = pulled ? _pulledShapes : _shapes;
    // alloc: once per effect.
    (m[effectOf(vertex)] ??= <_PassShape>{}).add(s);
  }

  Set<_PassShape>? shapesOf(String vertex, {required bool pulled}) =>
      (pulled ? _pulledShapes : _shapes)[effectOf(vertex)];

  /// The pass shapes and states made ahead for the shaders of each draw, in
  /// runs with PRISMARINE_FRAME_LOG.
  final _madeFor = <String, Set<String>>{};

  // alloc-cold: PRISMARINE_FRAME_LOG runs, a draw that made a pipeline state.
  /// Returns the reason that the states made ahead missed the state of [d]
  /// in the pass being recorded. `unlisted` means none made for its shaders
  /// and none waiting. `waiting` means its listing is not made yet. `shape`
  /// means none in the shape of this pass. `state` means others in this
  /// shape. `same` means this state, with a key of the engine that held
  /// more than the state of the draw, such as factors left on the pass.
  String missOf(DrawPlan d) {
    final made = _madeFor['${d.vertex}|${d.pixel}'];
    if (made == null) {
      bool mine(DrawPlan o) => o.vertex == d.vertex && o.pixel == d.pixel;
      return queue.any((e) => mine(e.$1)) || ready.any((e) => mine(e.$1))
          ? 'waiting'
          : 'unlisted';
    }
    final at = '${shape?.key}|';
    if (made.contains('$at${_stateKey(d.state)}')) return 'same';
    return made.any((m) => m.startsWith(at)) ? 'state' : 'shape';
  }
}

extension RunnerWarm on FrameRunner {
  // alloc-cold: once per render target made.
  /// Returns the pass shape of [r] as its render target is made with
  /// [depth].
  _PassShape _shapeOf(RenderPassPlan r, Attachment? depth) {
    final colors = [for (final c in r.colors) _colorTexture(c)];
    final d = depth == null ? null : targets[depth.target];
    return _PassShape(
      [for (final t in colors) t.format],
      d?.format,
      colors.isNotEmpty ? colors.first.sampleCount : d?.sampleCount ?? 1,
    );
  }

  /// The number of draws that wait for their first-frame work ([warmSome]).
  int get statesWaiting =>
      _warm.queue.length + _warm.ready.length + _warm.computes.length;

  /// Queues the compute shaders [ids] that the frames of a coming scene will
  /// dispatch. [warmSome] makes them ready ahead of the frame that
  /// dispatches one first.
  void computesAhead(List<String> ids) {
    if (_Warm.on) _warm.computes.addAll(ids);
  }

  /// Loads the shards and makes the compute pipelines of [ids] now, such as
  /// in the hold of a switch, whose first frame would make them. The
  /// pipelines made before are skipped.
  Future<void> readyComputes(Iterable<String> ids) async {
    if (!_Warm.on) return;
    final want = [
      for (final id in ids)
        if (!_computeSetups.containsKey(id) && assets.hasShader(id)) id,
    ];
    if (want.isEmpty) return;
    await assets.loadShaders(want);
    _shadersLoaded.addAll(want);
    for (final id in want) {
      if (!_computeSetups.containsKey(id)) _computeSetupOf(id);
    }
  }

  /// A log line with the pipeline states made ahead so far and their time.
  String get statesLine =>
      '${_warm.states} made (${_warm.failed} could not be) in '
      '${_warm.ms.toStringAsFixed(1)} ms';

  /// Drops the draws that wait for their first-frame work, such as when a
  /// prediction is given back. They hold its meshes.
  void forgetStates() {
    _warm.queue.clear();
    _warm.ready.clear();
  }

  /// Runs the next step of reading the cooked data of [scene] ahead of its
  /// first frame (Pulled.sceneAhead). The pulled passes of the first frame
  /// of a scene read its cooked scene and every pool and texture array that
  /// its draws use. Returns true when it is all read. A call while one runs
  /// does nothing.
  Future<bool> cookedAhead(String scene) async {
    final p = pulled;
    final w = _warm;
    if (p == null || !_Warm.pulledOn) return true;
    final name = scene.endsWith('.scene')
        ? scene.substring(0, scene.length - 6)
        : scene;
    if (w._cooked.contains(name)) return true;
    if (w.cookedBusy) return false;
    w.cookedBusy = true;
    try {
      final done = await p.sceneAhead(name);
      if (done) w._cooked.add(name);
      return done;
    } finally {
      w.cookedBusy = false;
    }
  }

  /// Does some of the first-frame work of the waiting draws, for about
  /// [budgetMs] of the time of the UI. The work is the pulled forms of the
  /// next draws, with their reads on the I/O thread, or their pipeline states
  /// ([_warmStates]) while drawn forms wait. A call while one runs does
  /// nothing.
  Future<void> warmSome(double budgetMs) async {
    final w = _warm;
    if (w.busy) return;
    if (w.computes.isNotEmpty) {
      // One per step, since the load of a shard and a compute pipeline take
      // a few ms.
      w.busy = true;
      try {
        await readyComputes([w.computes.removeFirst()]);
      } finally {
        w.busy = false;
      }
      return;
    }
    if (w.ready.isNotEmpty || !_Warm.pulledOn) {
      _warmStates(budgetMs);
      return;
    }
    w.busy = true;
    final sw = Stopwatch()..start();
    try {
      // The own time of the UI. An awaited read does not count for the frame.
      var spentUs = 0;
      while (w.queue.isNotEmpty && spentUs < budgetMs * 1000) {
        final (d, setup, scene) = w.queue.removeFirst();
        if (setup != null && _Warm.statesOn) w.ready.add((d, setup, false));
        final at = sw.elapsedMicroseconds;
        final pulledSetup = await _pulledAhead(d, scene);
        spentUs += sw.elapsedMicroseconds - at;
        if (pulledSetup != null && _Warm.statesOn) {
          w.ready.add((d, pulledSetup, true));
        }
      }
    } finally {
      w.busy = false;
    }
  }

  /// Makes now the pulled form in which [d], listed ahead and made ready by
  /// [prepareSome], draws at its first frame. The form has the pulled
  /// shaders, the cooked scene of [scene], the pool and the arrays, read
  /// away from the frame where they can be. Returns null when [d] draws by
  /// record, since its effect did not draw pulled or its form is refused.
  Future<_DrawSetup?> _pulledAhead(DrawPlan d, String? scene) async {
    final p = pulled;
    final g = d.geometry;
    if (p == null || g is! DrawMeshGeometry) return null;
    if (_warm.shapesOf(d.vertex, pulled: true) == null) return null;
    final shaders = p.shaders;
    if (!shaders.hasShader(d.vertex)) return null;
    if (d.pixel case final px? when !shaders.hasShader(px)) return null;
    await p.shaders.loadShaders([d.vertex, ?d.pixel]);
    await p.readAhead(
      g.mesh,
      g.firstIndex,
      g.indexCount,
      shadow: g.ibuffer == 1,
      scene: scene,
    );
    _warm.pulledScene = scene;
    final _PulledDraw form;
    try {
      form = _pulledOf(d);
    } finally {
      _warm.pulledScene = null;
    }
    if (form.reason != null) return null;
    return _pulledSetup(p, d);
  }

  // alloc-cold: while a scene is predicted, not in a steady frame.
  /// Makes the pipeline states of the waiting draws ([warmSome]) for about
  /// [budgetMs], at least those of one draw. Each state is made in every
  /// pass shape that its effect was recorded in, as an indirect draw of
  /// nothing in a tiny target of that shape on a command buffer of its own.
  /// The engine makes a pipeline state object at the first use of a
  /// pipeline, pass formats and state by a draw and keeps it with the
  /// pipeline. The state covers blends, depth, stencil and cull. The first
  /// frame of the scene then finds them made. Returns the number of draws
  /// done.
  int _warmStates(double budgetMs) {
    final w = _warm;
    if (w.ready.isEmpty) return 0;
    final sw = Stopwatch()..start();
    gpu.CommandBuffer? cb;
    final passes = <String, gpu.RenderPass>{};
    var n = 0;
    try {
      while (w.ready.isNotEmpty &&
          (n == 0 || sw.elapsedMicroseconds < budgetMs * 1000)) {
        final (d, setup, pulledForm) = w.ready.removeFirst();
        n++;
        final shapes = w.shapesOf(d.vertex, pulled: pulledForm);
        if (shapes == null) continue;
        for (final shape in shapes) {
          // A pass of another attachment count is not one of the draw, since
          // the builder gives a draw a blend per attachment.
          if (shape.colors.length != d.state.blends.length) continue;
          final made =
              '${identityHashCode(setup.pipeline)}|${shape.key}|'
              '${_stateKey(d.state)}';
          if (!w._made.add(made)) continue;
          // A pulled draw always sets its stencil and a recorded draw only with
          // a test. They are kept apart. No draw then finds the stencil of
          // another left on the pass.
          final stencil = pulledForm || d.state.stencil != null;
          final at = '${shape.key}|$stencil';
          final pass = passes[at] ??=
              (cb ??= gpu.gpuContext.createCommandBuffer()).createRenderPass(
                _warmTarget(shape),
              );
          final from = sw.elapsedMicroseconds;
          try {
            _warmDraw(pass, d, setup, pulledForm);
            w.states++;
            assets.tally.add(
              LoadTally.state,
              (sw.elapsedMicroseconds - from) / 1000,
            );
            if (FrameRunner.firstUses) {
              // alloc: PRISMARINE_FRAME_LOG runs only.
              (w._madeFor['${d.vertex}|${d.pixel}'] ??= {}).add(
                '${shape.key}|${_stateKey(d.state)}',
              );
            }
          } on Exception catch (e) {
            // The engine could not make that state, for a pass shape outside
            // the passes of this draw. Its first frame makes what it uses.
            w.failed++;
            if (FrameRunner.firstUses && w.failed <= 3) {
              warn?.call('state not made: $e ${d.vertex} ${shape.key}');
            }
          }
          final us = sw.elapsedMicroseconds - from;
          if (FrameRunner.firstUses && us > 8000) {
            warn?.call(
              'slow state ${Timeline.now} ${(us / 1000).toStringAsFixed(1)} '
              'ms ${d.vertex} ${d.pixel} ${shape.key}'
              '${pulledForm ? ' pulled' : ''}',
            );
          }
        }
      }
    } finally {
      cb?.submit();
      w.ms += sw.elapsedMicroseconds / 1000;
    }
    return n;
  }

  /// Sets the state of [d] on [pass] as its record sets it, by [_record] or by
  /// [_pulledBucket] in pulled form. Then records a draw of nothing.
  void _warmDraw(
    gpu.RenderPass pass,
    DrawPlan d,
    _DrawSetup setup,
    bool pulledForm,
  ) {
    final fixed = _DrawFixed(d, setup);
    pass
      ..bindPipeline(setup.pipeline)
      ..setCullMode(fixed.cull)
      ..setWindingOrder(fixed.winding)
      ..setPrimitiveType(
        pulledForm ? gpu.PrimitiveType.triangle : fixed.primitive,
      )
      ..setDepthWriteEnable(fixed.depthWrite)
      ..setDepthCompareOperation(fixed.compare);
    if (pulledForm || d.state.stencil != null) {
      pass.setStencilConfig(fixed.stencilConfig);
    }
    for (var i = 0; i < fixed.blends.length; i++) {
      final b = fixed.blends[i];
      pass.setColorBlendEnable(b.blend.enabled, colorAttachmentIndex: i);
      if (b.equation case final e?) {
        pass.setColorBlendEquation(e, colorAttachmentIndex: i);
      }
    }
    // With counts of zero the GPU draws nothing and reads no binding.
    pass.drawIndirect(
      _warm._zeroArgs ??= () {
        final b = gpu.gpuContext.createDeviceBufferWithCopy(ByteData(16));
        return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: 16);
      }(),
    );
  }

  /// Returns a 4 × 4 target of the formats of [shape], made once.
  gpu.RenderTarget _warmTarget(_PassShape shape) =>
      _warm._targets[shape] ??= () {
        gpu.Texture make(gpu.PixelFormat f) => gpu.gpuContext.createTexture(
          gpu.StorageMode.devicePrivate,
          4,
          4,
          format: f,
          sampleCount: shape.samples,
          textureType: shape.samples > 1
              ? gpu.TextureType.texture2DMultisample
              : null,
          enableRenderTargetUsage: true,
        );
        final depth = shape.depth;
        return gpu.RenderTarget(
          colorAttachments: [
            for (final f in shape.colors)
              gpu.ColorAttachment(
                texture: make(f),
                storeAction: gpu.StoreAction.dontCare,
              ),
          ],
          depthStencilAttachment: depth == null
              ? null
              : gpu.DepthStencilAttachment(texture: make(depth)),
        );
      }();
}
