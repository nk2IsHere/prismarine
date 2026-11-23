part of 'frame_runner.dart';

/// A draw's target textures, its vertex stage's then its pixel stage's in
/// binding order (a plan's draws are not changed once made).
List<TargetTexture> _targetTexturesOf(DrawPlan d) => [
  for (final res in [d.vertexResources, d.pixelResources])
    for (final t in res.textures.values)
      if (t is TargetTexture) t,
];

/// The targets each dispatch reads, by dispatch.
final _dispatchReads = Expando<List<String>>('dispatch target reads');

/// Which depth attachments a frame need not write back. On Metal's tiles a
/// stored attachment is written out to memory at the end of each pass; the
/// scene depth and the back buffer's depth are full-window D32S8 targets
/// (about 36 MB each at 3600 × 2025) whose last pass in a frame stored them
/// for nothing: no later pass reads them, and the next frame clears them
/// before any read. Dropping that store changes no pixel.
extension _RunnerStores on FrameRunner {
  /// The render passes of [plan] whose depth target needs no store: no
  /// later pass of the plan reads or attaches it, and the plan's first use
  /// of it clears its depth and stencil (so no next frame of the same
  /// passes reads what this one leaves). Empty with [keepStores].
  Set<RenderPassPlan> _depthUnstored(FramePlan plan) {
    // The walk's sets, lists and maps are the runner's, cleared (perf: five
    // collections and an iterator per pass each frame).
    final dropped = _unstored..clear();
    if (keepStores) return dropped;
    final later = _later..clear();
    final lastTarget = _lastTarget..clear(), lastPass = _lastPass..clear();
    final lastSeen = _lastSeen..clear();
    // Each target's first use in the plan, and whether that use clears it.
    final firstClears = _firstClears..clear();
    final passes = plan.passes;
    final used = _used, order = _usedOrder;
    for (var i = passes.length - 1; i >= 0; i--) {
      used.clear();
      order.clear();
      switch (passes[i]) {
        case final RenderPassPlan r:
          final colors = r.colors;
          for (var k = 0; k < colors.length; k++) {
            if (used.add(colors[k].target)) order.add(colors[k].target);
          }
          final draws = r.allDraws;
          for (var n = 0; n < draws.length; n++) {
            final reads = _targetsRead(draws[n]);
            for (var k = 0; k < reads.length; k++) {
              if (used.add(reads[k])) order.add(reads[k]);
            }
          }
          final d = r.depth;
          if (d != null) {
            if (!later.contains(d.target) && lastSeen.add(d.target)) {
              lastTarget.add(d.target);
              lastPass.add(r);
            }
            firstClears[d.target] =
                d.clearDepth != null &&
                d.clearStencil != null &&
                !used.contains(d.target);
            if (used.add(d.target)) order.add(d.target);
          }
          for (var k = 0; k < order.length; k++) {
            final t = order[k];
            if (t != d?.target) firstClears[t] = false;
          }
        case final DispatchPlan c:
          // Read once per dispatch (a kept one is the same object from
          // frame to frame): two map walks per dispatch were a frame's
          // garbage (perf).
          final reads = _dispatchReads[c] ??= [
            for (final t in c.resources.textures.values)
              if (t is TargetTexture) t.target,
            for (final s in c.resources.storage.values)
              if (s is ImageRef) s.target,
          ];
          for (var k = 0; k < reads.length; k++) {
            if (used.add(reads[k])) order.add(reads[k]);
          }
          for (var k = 0; k < order.length; k++) {
            firstClears[order[k]] = false;
          }
      }
      for (var k = 0; k < order.length; k++) {
        later.add(order[k]);
      }
    }
    for (var k = 0; k < lastTarget.length; k++) {
      if (firstClears[lastTarget[k]] ?? false) dropped.add(lastPass[k]);
    }
    return dropped;
  }

  /// The targets draw [d] samples, kept with the draw (a plan's draws are
  /// not changed once made).
  List<String> _targetsRead(DrawPlan d) {
    final cache = _cacheOf(d);
    return cache.reads ??= [for (final t in _targetTexturesOf(d)) t.target];
  }
}
