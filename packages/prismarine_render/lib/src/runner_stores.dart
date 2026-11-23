part of 'frame_runner.dart';

/// Returns the target textures of a draw, those of its vertex stage and then
/// those of its pixel stage in binding order.
List<TargetTexture> _targetTexturesOf(DrawPlan d) => [
  for (final res in [d.vertexResources, d.pixelResources])
    for (final t in res.textures.values)
      if (t is TargetTexture) t,
];

/// The targets each dispatch reads, by dispatch.
final _dispatchReads = Expando<List<String>>('dispatch target reads');

/// Finds the depth attachments that a frame need not write back. On the
/// tiles of Metal a stored attachment is written out to memory at the end
/// of each pass. A full-window D32S8 depth target is about 36 MB at
/// 3600 × 2025. Its last pass in a frame stores it for nothing when no later
/// pass reads it and the next frame clears it before any read. Dropping that
/// store changes no pixel.
extension _RunnerStores on FrameRunner {
  /// Returns the render passes of [plan] whose depth target needs no store. No
  /// later pass of the plan reads or attaches it. The first use of it in the
  /// plan clears its depth and stencil. The next frame of the same passes then
  /// does not read what this frame leaves. Empty with [keepStores].
  Set<RenderPassPlan> _depthUnstored(FramePlan plan) {
    // The sets, lists and maps of the walk belong to the runner and are
    // cleared.
    final dropped = _unstored..clear();
    if (keepStores) return dropped;
    final later = _later..clear();
    final lastTarget = _lastTarget..clear(), lastPass = _lastPass..clear();
    final lastSeen = _lastSeen..clear();
    // The first use of each target in the plan and if that use clears it.
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
          // Read once per dispatch, since a kept dispatch is the same object
          // from frame to frame.
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

  /// Returns the targets that the draw [d] samples, kept with the draw. The
  /// draws of a plan do not change once made.
  List<String> _targetsRead(DrawPlan d) {
    final cache = _cacheOf(d);
    return cache.reads ??= [for (final t in _targetTexturesOf(d)) t.target];
  }
}
