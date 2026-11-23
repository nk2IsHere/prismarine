part of 'frame_runner.dart';

/// The part of a recorded draw that follows from its plan alone, set on its
/// pass. It holds the state as values of the engine and the own vertex and
/// index views of its mesh geometry, made once.
final class _DrawFixed {
  _DrawFixed(DrawPlan d, _DrawSetup setup)
    : cull = cullMode(d.state.cull),
      // The front faces of D3D wind clockwise unless FrontCounterClockwise.
      // The winding of the engine has the opposite sense, since the NDC of
      // Impeller has y up where the window y of D3D runs down. D3D clockwise
      // is counter-clockwise in the engine.
      winding = d.state.frontCounterClockwise
          ? gpu.WindingOrder.clockwise
          : gpu.WindingOrder.counterClockwise,
      primitive = d.state.topology == 'triangleStrip'
          ? gpu.PrimitiveType.triangleStrip
          : gpu.PrimitiveType.triangle,
      depthWrite = d.state.depthTest && d.state.depthWrite,
      compare = d.state.depthTest
          ? compareFunction(d.state.depthFunc)
          : gpu.CompareFunction.always,
      stencilConfig = d.state.stencil == null
          ? noStencil
          : stencilConfigOf(d.state.stencil!),
      blends = [for (final b in d.state.blends) _fixedBlend(maskedBlend(b))],
      viewport = _viewportOf(d.viewport),
      slotViews = [
        for (final b in setup.slots)
          gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: b.sizeInBytes),
      ],
      indexView = _indexView(d.geometry, setup.mesh);

  final gpu.CullMode cull;
  final gpu.WindingOrder winding;
  final gpu.PrimitiveType primitive;
  final bool depthWrite;
  final gpu.CompareFunction compare;
  final gpu.StencilConfig stencilConfig;
  final List<_FixedBlend> blends;

  /// The viewport of the draw as the engine sets it, one object per distinct
  /// viewport. A pass compares the viewport it set last by identity.
  final gpu.Viewport viewport;

  /// The views of the own vertex buffers of the mesh, by slot.
  final List<gpu.BufferView> slotViews;

  /// The index view of the mesh geometry with the indices of its batch. An
  /// indirect draw gets the whole buffer, since the first index of its
  /// arguments counts from the start of the buffer, as Direct3D binds the
  /// whole index buffer.
  final gpu.BufferView? indexView;

  /// The views of the streams of the geometry in the plan buffers of each of
  /// the three frames of the runner. They are made once per frame slot while
  /// the buffers stand (FrameRunner._bufferGen). The streams of a skinned
  /// mesh are bound every frame.
  final _streamViews = List<List<gpu.BufferView>?>.filled(3, null);
  int _streamGen = -1;

  List<gpu.BufferView> streamViewsFor(FrameRunner r, DrawMeshGeometry g) {
    if (_streamGen != r._bufferGen) {
      _streamViews.fillRange(0, 3, null);
      _streamGen = r._bufferGen;
    }
    return _streamViews[r._frame] ??= [
      for (final (ref, _, _) in g.streams.values) r._bufferView(ref),
    ];
  }

  static gpu.BufferView? _indexView(DrawGeometry g, RenderMesh? mesh) {
    if (g is! DrawMeshGeometry || mesh == null) return null;
    final ib = mesh.indexBuffers[g.ibuffer];
    return g.indirect != null
        ? gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes)
        : gpu.BufferView(
            ib,
            offsetInBytes: g.firstIndex * 2,
            lengthInBytes: g.indexCount * 2,
          );
  }
}

/// Returns [v] as a viewport of the engine, one object per distinct value
/// list. A frame has a few, which are searched in turn.
gpu.Viewport _viewportOf(List<double> v) {
  for (var n = 0; n < _viewports.length; n++) {
    final (k, viewport) = _viewports[n];
    if (k.length != v.length) continue;
    var same = true;
    for (var i = 0; i < v.length && same; i++) {
      same = k[i] == v[i];
    }
    if (same) return viewport;
  }
  final viewport = gpu.Viewport(
    x: v[0].round(),
    y: v[1].round(),
    width: v[2].round(),
    height: v[3].round(),
    depthRange: gpu.DepthRange(
      zNear: v.length > 4 ? v[4] : 0,
      zFar: v.length > 5 ? v[5] : 1,
    ),
  );
  _viewports.add((List.of(v), viewport));
  return viewport;
}

final _viewports = <(List<double>, gpu.Viewport)>[];

/// Returns [b] as the engine sets it, one object per distinct blend with its
/// switch, factors and operations. A pass compares the blend it set last by
/// identity. A frame has a few, which are searched in turn.
_FixedBlend _fixedBlend(Blend b) {
  for (var n = 0; n < _blendsByValue.length; n++) {
    final f = _blendsByValue[n];
    final k = f.blend;
    if (k.enabled == b.enabled &&
        _sameOps(k.color, b.color) &&
        _sameOps(k.alpha, b.alpha)) {
      return f;
    }
  }
  final f = _FixedBlend(b);
  _blendsByValue.add(f);
  return f;
}

final _blendsByValue = <_FixedBlend>[];

bool _sameOps(List<String> a, List<String> b) =>
    a.length == b.length && a[0] == b[0] && a[1] == b[1] && a[2] == b[2];

/// The blend of one attachment as the engine sets it.
final class _FixedBlend {
  _FixedBlend(this.blend)
    : equation = blend.enabled
          ? gpu.ColorBlendEquation(
              sourceColorBlendFactor: blendFactor(blend.color[0]),
              destinationColorBlendFactor: blendFactor(blend.color[1]),
              colorBlendOperation: blendOp(blend.color[2]),
              sourceAlphaBlendFactor: blendFactor(blend.alpha[0]),
              destinationAlphaBlendFactor: blendFactor(blend.alpha[1]),
              alphaBlendOperation: blendOp(blend.alpha[2]),
            )
          : _Warm.on
          ? _unblended
          : null;
  final Blend blend;
  final gpu.ColorBlendEquation? equation;
}

/// The factors that a blend which is off sets all the same. The engine keys a
/// pipeline state on the factors of an attachment whether or not it blends. A
/// pass keeps the factors that the last draw set. Without these factors the
/// state of a draw would follow the draws before it in its pass. The states
/// made ahead on passes of their own (runner_warm.dart) would miss. The GPU
/// reads no factor of a blend that is off. PRISMARINE_FIRST_FRAME=off leaves
/// them unset.
final _unblended = gpu.ColorBlendEquation();

extension _RunnerRecord on FrameRunner {
  /// Records [d] into [pass] with its [setup].
  void _record(
    gpu.RenderPass pass,
    DrawPlan d,
    UniformRing host,
    _DrawSetup setup,
    _PassState state,
  ) {
    final (:vs, :fs, :pipeline, :mesh, :slots, :inlineVertices) = setup;
    final cache = _cacheOf(d);
    if (cache.fixed == null && _Warm.on) _warm.learn(d.vertex, pulled: false);
    final newState = cache.fixed == null
        ? _uses?.draw(d, pipeline, mesh, _clock) ?? -1
        : -1;
    final fixed = cache.fixed ??= _DrawFixed(d, setup);
    final g = d.geometry;
    // The engine keeps the bindings of a pass until they are cleared. A draw
    // with the shaders and vertex slots of the last draw binds again only
    // what changed (state.bound). Any other draw starts from none.
    final vertexSlots = switch (g) {
      DrawMeshGeometry() => slots.length + g.streams.length,
      InlineGeometry() => 1,
      _ => 0,
    };
    if (!state.sameShaders(vs, fs, vertexSlots)) pass.clearBindings();
    pass
      ..bindPipeline(pipeline)
      ..setCullMode(fixed.cull)
      ..setWindingOrder(fixed.winding)
      ..setPrimitiveType(fixed.primitive);
    // Depth, viewport and blends stay set on the pass until changed.
    if (fixed.depthWrite != state.depthWrite) {
      pass.setDepthWriteEnable(state.depthWrite = fixed.depthWrite);
    }
    if (fixed.compare != state.compare) {
      pass.setDepthCompareOperation(state.compare = fixed.compare);
    }
    final stencil = d.state.stencil;
    if (state.newStencil(stencil)) pass.setStencilConfig(fixed.stencilConfig);
    if (stencil != null && d.stencilRef != state.stencilRef) {
      pass.setStencilReference(state.stencilRef = d.stencilRef);
    }
    if (state.newViewport(fixed.viewport)) pass.setViewport(fixed.viewport);
    final blends = fixed.blends;
    for (var i = 0; i < blends.length; i++) {
      final b = blends[i];
      if (!state.newBlend(i, b)) continue;
      pass.setColorBlendEnable(b.blend.enabled, colorAttachmentIndex: i);
      if (b.equation case final e?) {
        pass.setColorBlendEquation(e, colorAttachmentIndex: i);
      }
    }
    _bind(pass, vs, d.vertex, d.vertexResources, host, state.vertex);
    if (fs != null) {
      _bind(pass, fs, d.pixel!, d.pixelResources, host, state.pixel);
    }
    if (g is DrawMeshGeometry) {
      // A vertex or index view that the pass holds already is not sent
      // again. The batches of one mesh share its buffers.
      final views = fixed.slotViews;
      for (var k = 0; k < views.length; k++) {
        if (state.newVertex(k, views[k])) {
          pass.bindVertexBuffer(views[k], slot: k);
        }
      }
      var k = views.length;
      if (g.streams.isNotEmpty) {
        // By index, without an iterator.
        final streams = fixed.streamViewsFor(this, g);
        for (var n = 0; n < streams.length; n++) {
          final view = streams[n];
          if (state.newVertex(k, view)) pass.bindVertexBuffer(view, slot: k);
          k++;
        }
      }
      final ib = fixed.indexView!;
      if (state.newIndex(ib)) pass.bindIndexBuffer(ib, gpu.IndexType.int16);
      if (g.indirect case final args?) {
        pass.drawIndirect(_bufferView(args), indexed: true);
      } else {
        pass.drawIndexed(g.indexCount, instanceCount: g.instances);
      }
    } else if (g is InlineGeometry) {
      state.forgetVertex();
      pass.bindVertexBuffer(
        _drawBytes(inlineVertices!, host, vertex: true),
        slot: 0,
      );
      if (g.indices case final idx?) {
        pass.bindIndexBuffer(
          _drawBytes(idx, host, vertex: false),
          gpu.IndexType.int16,
        );
        pass.drawIndexed(g.vertexCount, instanceCount: g.instances);
      } else {
        pass.draw(g.vertexCount, instanceCount: g.instances);
      }
    } else if (g is ScreenGeometry) {
      pass.draw(g.vertexCount, instanceCount: g.instances);
    }
    if (newState >= 0) {
      final us = _clock.elapsedMicroseconds - newState;
      _uses!.stateUs += us;
      // A draw long enough to have made a pipeline state records the reason
      // that none was made ahead.
      if (us > _FirstUses.stateMadeUs) _uses.missed(_warm.missOf(d), d, us);
    }
  }
}
