// The state that the runner keeps with a render pass from frame to frame. A
// pass that the codec keeps is the same object. Its attachments are made once.
part of 'frame_runner.dart';

extension _RunnerPasses on FrameRunner {
  /// Returns the range [r] of its frame buffer as a view, one object per
  /// buffer, offset and length.
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

  /// Returns the state that this runner keeps with the pass [r]
  /// (RenderPassPlan.runnerState).
  _PassCache _passOf(RenderPassPlan r) {
    final c = r.runnerState;
    if (c is _PassCache && identical(c.runner, this)) {
      if (c.version != r.version) {
        // The codec edited the draws. Their loads and the depth choice are
        // made again, the target only when the choice changes.
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

  /// A plan may keep its depth target bound through passes that do not test it
  /// while post passes read it as a texture. Metal's tiles make a texture read
  /// while it is also an attachment undefined. Such a pass therefore gets no
  /// depth attachment. A pass that clears its depth keeps it, since a shadow
  /// map's face with no casters is only that clear.
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

  /// Returns the render target of [p] for [r] with the depth [store]. It is
  /// made again only after a new target (_texGen) or a change of the depth
  /// store.
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

/// The state that a runner keeps with a render pass. It holds whether the
/// pass binds its depth target and the render target as made in the texture
/// generation [gen].
final class _PassCache {
  _PassCache(this.runner, this.depth);
  final FrameRunner runner;
  Attachment? depth;

  /// The version of the pass for this state (RenderPassPlan.version).
  int version = 0;
  gpu.RenderTarget? target;
  int gen = -1;
  bool store = true;

  /// True when a run loaded the needs of its draws (FrameRunner._newLoads).
  bool loaded = false;

  /// The formats of the attachments, as made with [target]
  /// (runner_warm.dart).
  _PassShape? shape;
}
