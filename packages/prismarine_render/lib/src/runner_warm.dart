// A scene's first frame without its first-use work: what a draw listed
// ahead of its scene's open will make at its first record, made over the
// frames before (FrameRunner.prepareSome queues it, warmSome makes it):
// its pulled form's cooked data, and the engine's pipeline state objects
// for the passes it will draw in.
part of 'frame_runner.dart';

/// What a pass's pipeline state objects depend on beyond the draw: its
/// attachments' formats and sample count (flutter_gpu's pipeline key).
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

/// A draw listed ahead and made ready ([FrameRunner.prepareSome]), waiting
/// for its first-frame work: its setup when made by record, and the scene
/// it is for.
typedef _Listed = (DrawPlan, _DrawSetup?, String?);

/// A draw waiting for its pipeline states: its setup, and whether it draws
/// in pulled form.
typedef _WarmItem = (DrawPlan, _DrawSetup, bool);

/// The runner's knowledge of which passes each program effect draws in,
/// learned from the frames it records, and the draws waiting to have
/// their states made.
final class _Warm {
  /// MCSM_FIRST_FRAME: `off` gives listed draws no pulled form or
  /// pipeline states ahead (the before, to compare); `pulled` or `states`
  /// only the one.
  static final _mode = Platform.environment['MCSM_FIRST_FRAME'] ?? 'on';
  static final on = _mode != 'off';
  static final pulledOn = on && _mode != 'states';

  /// Pipeline states ahead on Metal only: its draw of nothing reads no
  /// binding, where Vulkan's binds a descriptor set the warm draw never
  /// wrote, which its rules allow only for descriptors no stage uses.
  static final statesOn = on && _mode != 'pulled' && Platform.isMacOS;

  /// The shape of the pass being recorded (FrameRunner._render).
  _PassShape? shape;

  /// By effect (a shader id's folder, `SceneGBuffer`, `Mesh`,
  /// `SceneShadowMap`, `FX_PostColor`): the shapes of the passes its draws
  /// were recorded in, by record and in pulled form.
  final _shapes = <String, Set<_PassShape>>{};
  final _pulledShapes = <String, Set<_PassShape>>{};
  final _effects = <String, String>{};

  /// The draws made ready waiting for their pulled form, then those
  /// waiting for their states; whether a [RunnerWarm.warmSome] runs.
  final queue = Queue<_Listed>();
  final ready = Queue<_WarmItem>();
  bool busy = false;

  /// The compute shaders coming scenes' frames will dispatch
  /// (SceneWarm.takeComputes), made ready first.
  final computes = Queue<String>();

  /// The cooked scenes read ahead whole (RunnerWarm.cookedAhead), and
  /// whether a step runs.
  final _cooked = <String>{};
  bool cookedBusy = false;

  /// The scene whose draws are being made ready now, if not the one shown:
  /// their pulled forms take their meshes from its cooked scene
  /// (Pulled.batch).
  String? pulledScene;

  /// The pipeline states made so far (pipeline, shape and state), and a
  /// tiny target per shape to make them in.
  final _made = <String>{};
  final _targets = <_PassShape, gpu.RenderTarget>{};
  gpu.BufferView? _zeroArgs;

  /// States made, those the engine could not make, and the time making
  /// them (ms; the log's line).
  int states = 0, failed = 0;
  double ms = 0;

  // alloc: once per shader id.
  String effectOf(String id) => _effects[id] ??= _effectOf(id);

  static String _effectOf(String id) {
    final i = id.indexOf('/');
    return i < 0 ? id : id.substring(0, i);
  }

  /// [vertex]'s draw recorded for the first time in the pass being
  /// recorded, by record or in pulled form.
  void learn(String vertex, {required bool pulled}) {
    final s = shape;
    if (s == null) return;
    final m = pulled ? _pulledShapes : _shapes;
    // alloc: once per effect.
    (m[effectOf(vertex)] ??= <_PassShape>{}).add(s);
  }

  Set<_PassShape>? shapesOf(String vertex, {required bool pulled}) =>
      (pulled ? _pulledShapes : _shapes)[effectOf(vertex)];

  /// MCSM_FRAME_LOG runs: by a draw's shaders, the pass shapes and states
  /// made for them ahead.
  final _madeFor = <String, Set<String>>{};

  // alloc-cold: MCSM_FRAME_LOG runs, a draw that made a pipeline state.
  /// Why the states made ahead missed [d]'s, recorded in the pass being
  /// recorded: `unlisted` (none made for its shaders, none waiting),
  /// `waiting` (its listing's not made yet), `shape` (none in this pass's
  /// shape), `state` (others in this shape), `same` (this one: the engine's
  /// key held what the draw's state does not, as factors left on the pass).
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
  /// [r]'s pass shape, as its render target is made with [depth].
  _PassShape _shapeOf(RenderPassPlan r, Attachment? depth) {
    final colors = [for (final c in r.colors) _colorTexture(c)];
    final d = depth == null ? null : targets[depth.target];
    return _PassShape(
      [for (final t in colors) t.format],
      d?.format,
      colors.isNotEmpty ? colors.first.sampleCount : d?.sampleCount ?? 1,
    );
  }

  /// How many draws wait for their first-frame work ([warmSome]).
  int get statesWaiting =>
      _warm.queue.length + _warm.ready.length + _warm.computes.length;

  /// Compute shaders a coming scene's frames will dispatch: made ready by
  /// [warmSome], ahead of the frame that dispatches one first.
  void computesAhead(List<String> ids) {
    if (_Warm.on) _warm.computes.addAll(ids);
  }

  /// [ids]' shards loaded and compute pipelines made now (a switch's hold:
  /// its first frame would make them); the ones made before are skipped.
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

  /// The pipeline states made ahead so far and their time (a log line).
  String get statesLine =>
      '${_warm.states} made (${_warm.failed} could not be) in '
      '${_warm.ms.toStringAsFixed(1)} ms';

  /// The draws waiting for their first-frame work dropped (a prediction
  /// given back: they hold its meshes).
  void forgetStates() {
    _warm.queue.clear();
    _warm.ready.clear();
  }

  /// The next step of reading [scene]'s cooked data ahead of its first
  /// frame (Pulled.sceneAhead): the pulled G-buffer of a scene's first
  /// frame reads its cooked scene, every pool and texture array its draws
  /// use. Whether it is all read; a call while one runs does nothing.
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

  /// Some of the waiting draws' first-frame work, for about [budgetMs] of
  /// the UI's time: the next draws' pulled forms (their reads on the I/O
  /// thread), or, while drawn forms wait, their pipeline states
  /// ([_warmStates]). A call while one runs does nothing.
  Future<void> warmSome(double budgetMs) async {
    final w = _warm;
    if (w.busy) return;
    if (w.computes.isNotEmpty) {
      // One a step: a shard's load and a compute pipeline are a few ms.
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
      // The UI's own time: an awaited read is not the frame's.
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

  /// What [d], listed ahead and made ready by [prepareSome], draws in
  /// pulled form at its first frame, made now: its pulled shaders, cooked
  /// scene, pool and arrays (read off the frame where they can be). Null
  /// when it draws by record (its effect never drew pulled, or its form
  /// is refused).
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
  /// Makes the pipeline states of the waiting draws ([warmSome]) for
  /// about [budgetMs] (at least one draw's): each in every pass shape its
  /// effect was recorded in, as an indirect draw of nothing in a tiny
  /// target of that shape, on a command buffer of its own. The engine
  /// makes a pipeline state object at a draw's first use of a pipeline,
  /// pass formats and state (blends, depth, stencil, cull), and keeps it
  /// with the pipeline: the scene's first frame finds them made.
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
          // A pass of another attachment count is not the draw's (the
          // builder gives a draw a blend per attachment): `Mesh` draws in
          // the main pass and in the UI views.
          if (shape.colors.length != d.state.blends.length) continue;
          final made =
              '${identityHashCode(setup.pipeline)}|${shape.key}|'
              '${_stateKey(d.state)}';
          if (!w._made.add(made)) continue;
          // A pulled draw sets its stencil always, a recorded one only with
          // a test: apart, so no draw finds another's left on the pass.
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
              // alloc: MCSM_FRAME_LOG runs only.
              (w._madeFor['${d.vertex}|${d.pixel}'] ??= {}).add(
                '${shape.key}|${_stateKey(d.state)}',
              );
            }
          } on Exception catch (e) {
            // The engine could not make that state (a pass shape this draw
            // never draws in): its first frame makes what it uses.
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

  /// [d]'s state set on [pass] as its record sets it ([_record], or
  /// [_pulledBucket] in pulled form), then a draw of nothing.
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
    // Counts of zero: the GPU draws nothing and reads no binding.
    pass.drawIndirect(
      _warm._zeroArgs ??= () {
        final b = gpu.gpuContext.createDeviceBufferWithCopy(ByteData(16));
        return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: 16);
      }(),
    );
  }

  /// A 4 × 4 target of [shape]'s formats, made once.
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
