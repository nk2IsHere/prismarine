// What the runner keeps with a render pass from frame to frame: a pass the
// codec keeps is the same object, so its attachments are made once.
part of 'frame_runner.dart';

extension _RunnerPasses on FrameRunner {
  /// Range [r] of its frame buffer, as a view.
  /// One object per buffer, offset and length (perf: a view per binding
  /// a frame).
  gpu.BufferView _bufferView(BufferRef r) {
    final b = _current[r.buffer] ?? (throw StateError('no buffer ${r.buffer}'));
    if (_viewsGen != _bufferGen) {
      _bufferViews.clear();
      _viewsGen = _bufferGen;
    }
    final length = r.size ?? b.sizeInBytes - r.offset;
    return (_bufferViews[b] ??= {})[r.offset * 0x100000000 + length] ??=
        gpu.BufferView(b, offsetInBytes: r.offset, lengthInBytes: length);
  }

  /// What this runner keeps with pass [r] (RenderPassPlan.runnerState).
  _PassCache _passOf(RenderPassPlan r) {
    final c = r.runnerState;
    if (c is _PassCache && identical(c.runner, this)) {
      if (c.version != r.version) {
        // The codec edited its draws: their loads and the depth choice
        // again (the target only when that changes).
        c
          ..version = r.version
          ..loaded = false;
        final d = _depthOf(r);
        if (!identical(d, c.depth)) {
          c
            ..depth = d
            ..target = null;
        }
      }
      return c;
    }
    final made = _PassCache(this, _depthOf(r))..version = r.version;
    r.runnerState = made;
    return made;
  }

  /// The exe keeps its depth target bound through passes that never test
  /// it (post passes read it as a texture meanwhile); Metal's tiles make a
  /// texture read while it is also an attachment undefined, so such a
  /// pass gets no depth attachment. A pass that clears its depth keeps it:
  /// a shadow map's face with no casters is only that clear.
  Attachment? _depthOf(RenderPassPlan r) {
    var depthUsed =
        r.depth?.clearDepth != null || r.depth?.clearStencil != null;
    final draws = r.allDraws;
    for (var i = 0; !depthUsed && i < draws.length; i++) {
      final s = draws[i].state;
      depthUsed = s.depthTest || s.depthWrite || s.stencil != null;
    }
    return depthUsed ? r.depth : null;
  }

  /// [p]'s render target, made again only when a target is made since
  /// (_texGen) or the depth store changes.
  gpu.RenderTarget _renderTarget(_PassCache p, RenderPassPlan r, bool store) {
    final had = p.target;
    if (had != null && p.gen == _texGen && p.store == store) return had;
    final d = p.depth;
    p
      ..gen = _texGen
      ..store = store
      ..shape = _shapeOf(r, d);
    return p.target = gpu.RenderTarget(
      colorAttachments: [
        for (final c in r.colors)
          gpu.ColorAttachment(
            texture: _colorTexture(c),
            mipLevel: c.mip,
            slice: c.layer,
            loadAction: c.clear != null
                ? gpu.LoadAction.clear
                : gpu.LoadAction.load,
            clearValue: c.clear == null
                ? null
                : Vector4(c.clear![0], c.clear![1], c.clear![2], c.clear![3]),
          ),
      ],
      depthStencilAttachment: d == null
          ? null
          : gpu.DepthStencilAttachment(
              texture: targets[d.target]!,
              mipLevel: d.mip,
              slice: d.layer,
              depthLoadAction: d.clearDepth != null
                  ? gpu.LoadAction.clear
                  : gpu.LoadAction.load,
              depthStoreAction: store
                  ? gpu.StoreAction.store
                  : gpu.StoreAction.dontCare,
              depthClearValue: d.clearDepth ?? 0,
              stencilLoadAction: d.clearStencil != null
                  ? gpu.LoadAction.clear
                  : gpu.LoadAction.load,
              stencilStoreAction: store
                  ? gpu.StoreAction.store
                  : gpu.StoreAction.dontCare,
              stencilClearValue: d.clearStencil ?? 0,
            ),
    );
  }
}

/// What a runner keeps with a render pass: whether it binds its depth
/// target, and its render target as made in texture generation [gen].
final class _PassCache {
  _PassCache(this.runner, this.depth);
  final FrameRunner runner;
  Attachment? depth;

  /// The pass's version this was made for (RenderPassPlan.version).
  int version = 0;
  gpu.RenderTarget? target;
  int gen = -1;
  bool store = true;

  /// Whether a run loaded what its draws need (FrameRunner._newLoads).
  bool loaded = false;

  /// Its attachments' formats, as made with [target] (runner_warm.dart).
  _PassShape? shape;
}
