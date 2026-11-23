part of 'frame_runner.dart';

/// Stencil reads. A plan may read a depth target's stencil through a uint
/// view, such as a depth reduction that counts drawn pixels. The engine
/// cannot make that view. Before a dispatch reads one, the runner therefore
/// copies the stencil into an R8G8_UINT texture, the value in .y as
/// Direct3D's view of D32S8 has it. A uint read gives the same values as
/// Direct3D's 32-bit view, at a quarter of the bytes that a full-window copy
/// writes. The copy is one full-screen draw per value the stencil can hold,
/// each testing for its value and writing it. The values it can hold follow
/// from the passes since the stencil's clear (StencilValues).
extension _RunnerStencil on FrameRunner {
  /// The stencil writes of a render pass with depth attachment [d] go here;
  /// a stencil clear starts them over.
  StencilValues _stencilWrites(Attachment d) {
    final v = _stencilValues[d.target] ??= StencilValues();
    if (d.clearStencil case final clear?) v.reset(clear);
    return v;
  }

  /// Before a pass of one draw [c] (a full-screen pass of ours: the depth
  /// reduction's first step): the stencil copies of the depth targets its
  /// pixel stage reads through a uint view, when their stencil changed
  /// since the last copy. The answer per shader is kept: most read none.
  void _stencilDraw(gpu.CommandBuffer cb, DrawPlan c, UniformRing host) {
    final shader = c.pixel;
    if (shader == null) return;
    var reads = _stencilReaders[shader];
    if (reads == null) {
      reads = const [];
      final info = assets.shaderRecord(shader);
      if (info != null) {
        for (final t in info.textures) {
          if (t.type.startsWith('utexture2D')) reads = [...reads!, t.name];
        }
      }
      _stencilReaders[shader] = reads!;
    }
    for (var i = 0; i < reads.length; i++) {
      final ref = c.pixelResources.textures[reads[i]];
      if (ref is! TargetTexture) continue;
      final values = _stencilValues[ref.target];
      if (values == null || !values.stale) continue;
      _stencilCopy(cb, ref.target, values, host);
    }
  }

  /// Before dispatch [c]: the stencil copies of the depth targets it reads
  /// through a uint view, when their stencil changed since the last copy.
  void _stencilCompute(gpu.CommandBuffer cb, DispatchPlan c, UniformRing host) {
    final info = assets.shaderRecord(c.shader);
    if (info == null) return;
    for (final t in info.textures) {
      if (!t.type.startsWith('utexture2D')) continue;
      final ref = c.resources.textures[t.name];
      if (ref is! TargetTexture) continue;
      final values = _stencilValues[ref.target];
      if (values == null || !values.stale) continue;
      _stencilCopy(cb, ref.target, values, host);
    }
  }

  void _stencilCopy(
    gpu.CommandBuffer cb,
    String target,
    StencilValues values,
    UniformRing host,
  ) {
    if (_stencilCopyShaders.isEmpty) return;
    values.stale = false;
    final depth = targets[target]!;
    final w = depth.width, h = depth.height;
    var copy = _stencilCopies[target];
    if (copy == null || copy.width != w || copy.height != h) {
      _texGen++;
      copy = _stencilCopies[target] = gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        w,
        h,
        format: gpu.PixelFormat.r8g8UInt,
        enableRenderTargetUsage: true,
        enableShaderReadUsage: true,
      );
    }
    // Recorded between dispatches: the next one opens its own compute pass.
    _copies++;
    _passLog?.add('render stencilCopy $target');
    final pass = cb.createRenderPass(
      gpu.RenderTarget(
        colorAttachments: [
          gpu.ColorAttachment(
            texture: copy,
            loadAction: gpu.LoadAction.clear,
            clearValue: Vector4.zero(),
          ),
        ],
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: depth,
          depthLoadAction: gpu.LoadAction.load,
          depthStoreAction: gpu.StoreAction.store,
          stencilLoadAction: gpu.LoadAction.load,
          stencilStoreAction: gpu.StoreAction.store,
        ),
      ),
    );
    final state = _PassState();
    final held = values.held();
    // Zero is the copy's clear.
    for (var v = 1; v < 256; v++) {
      if (held[v] == 0) continue;
      _draw(pass, _stencilCopyDraw(v, w, h), host, state);
    }
  }

  /// The copy's draw of stencil value [v] over a [w] × [h] target.
  DrawPlan _stencilCopyDraw(int v, int w, int h) {
    final had = _stencilDraws[v];
    if (had != null && had.viewport[2] == w && had.viewport[3] == h) {
      return had;
    }
    return _stencilDraws[v] = DrawPlan(
      label: 'stencilCopy $v',
      vertex: shaders.stencilCopyVertex,
      pixel: shaders.stencilCopyPixel,
      geometry: _copyTriangle,
      state: const DrawState(
        cull: 'none',
        depthTest: false,
        depthWrite: false,
        stencil: Stencil(func: 'equal', writeMask: 0),
      ),
      stencilRef: v,
      viewport: [0, 0, w.toDouble(), h.toDouble(), 0, 1],
      vertexResources: StageResources(),
      pixelResources: StageResources(
        blocks: {
          'StencilCopy': Uint8List(16)
            ..buffer.asByteData().setUint32(0, v, Endian.little),
        },
      ),
    );
  }
}

/// The copy's triangle: clip-space corners that cover the target.
final _copyTriangle = InlineGeometry(
  Float32List.fromList([-1, -1, 3, -1, -1, 3]).buffer.asUint8List(),
  8,
  const {0: ('R32G32_FLOAT', 0)},
  3,
);
