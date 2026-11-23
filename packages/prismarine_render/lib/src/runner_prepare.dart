// Making a frame's new draws ready ahead of their record: a frame's
// potential draws ([prepare]) and a background warm-up's, a few at a time
// ([prepareSome]).
part of 'frame_runner.dart';

extension RunnerPrepare on FrameRunner {
  /// Makes ready what [draws] need before a frame records them: their
  /// shaders' shards, pipelines, meshes and slice textures (the builder's
  /// potential draws, FrameBuilder.potentialDraws), so the frame that
  /// first records one (a cut) does not stall on them. A draw the slice
  /// can't feed is left to the frame, which names the problem.
  Future<void> prepare(List<DrawPlan> draws) async {
    if (draws.isEmpty) {
      lastPrepareMs = lastPrepareLoadMs = lastPreparePipelineMs = 0;
      lastPrepareLayoutMs = lastPrepareFailedMs = lastPrepareTextureMs = 0;
      lastPrepareErrors = 0;
      return;
    }
    final sw = Stopwatch()..start();
    final loads0 = assets.loadMs;
    await assets.loadShaders({
      for (final d in draws)
        if (_bundled(d)) ...[d.vertex, d.pixel ?? _depthOnly(d)],
    });
    final pipelines0 = _pipelineMs;
    final layouts0 = _layoutMs, failed0 = _failedPipelineMs;
    var textureUs = 0, errors = 0;
    assets.phase = 'prepare';
    for (final d in draws) {
      final (us, ok, _) = _prepareOne(d, sw);
      textureUs += us;
      if (!ok) errors++;
    }
    assets.phase = 'record';
    lastPrepareErrors = errors;
    lastPrepareMs = sw.elapsedMicroseconds / 1000;
    lastPrepareLoadMs = assets.loadMs - loads0;
    lastPreparePipelineMs = _pipelineMs - pipelines0;
    lastPrepareLayoutMs = _layoutMs - layouts0;
    lastPrepareFailedMs = _failedPipelineMs - failed0;
    lastPrepareTextureMs = textureUs / 1000;
  }

  bool _bundled(DrawPlan d) {
    bool bundled(String id) => assets.shaderRecord(id)?.shard != null;
    return bundled(d.vertex) && bundled(d.pixel ?? _depthOnly(d));
  }

  /// Makes [d]'s pipeline, mesh and slice textures ready (its shards
  /// loaded); the texture time ([sw]'s microseconds), whether the slice
  /// could feed it, and its setup when made.
  (int, bool, _DrawSetup?) _prepareOne(DrawPlan d, Stopwatch sw) {
    if (!_bundled(d)) return (0, true, null);
    final from = sw.elapsedMicroseconds;
    try {
      final vs = assets.shader(d.vertex);
      final fs = d.pixel == null ? null : assets.shader(d.pixel!);
      final setup = _drawWith(
        null,
        d,
        _host ??= UniformRing(),
        vs,
        fs,
        d.geometry,
      );
      final at = sw.elapsedMicroseconds;
      for (final (id, res) in [
        (d.vertex, d.vertexResources),
        (d.pixel, d.pixelResources),
      ]) {
        if (id == null) continue;
        for (final t in assets.shaderRecord(id)!.textures) {
          if (res.textures[t.name] case final FileTexture f) {
            _texture(f, t.type);
          }
        }
      }
      final us = sw.elapsedMicroseconds;
      if (us - from > slowLoadMs * 1000) {
        assets.onSlow?.call(
          'draw ${d.label}',
          (us - from) / 1000,
          0,
          assets.phase,
        );
      }
      return (us - at, true, setup);
    } on StateError {
      return (0, false, null);
    } on Exception {
      return (0, false, null);
    }
  }

  /// [prepare] of the first of [draws] until [budgetMs] has passed (at
  /// least one): a scene added in the background is made ready a little
  /// each frame. Returns how many it took.
  /// [tag]: the scene the game has not opened yet that [draws] are for
  /// (RenderAssets.tag), whose loads alone can be forgotten; [owner]: the open
  /// scene they are for (RenderAssets.warmFor), whose loads they are too.
  Future<int> prepareSome(
    List<DrawPlan> draws,
    double budgetMs, {
    String? tag,
    String? owner,
  }) async {
    final sw = Stopwatch()..start();
    var n = 0;
    while (n < draws.length) {
      final d = draws[n++];
      if (_bundled(d)) {
        await assets.loadShaders([d.vertex, d.pixel ?? _depthOnly(d)]);
      }
      // Set around the synchronous part only: a frame's record runs
      // between the awaits.
      assets
        ..tag = tag
        ..warmFor = owner
        ..phase = 'warm';
      _warm.pulledScene = tag ?? owner;
      try {
        final (_, _, setup) = _prepareOne(d, sw);
        // Its first-frame work after the warm-up's (warmSome), newest
        // first: the scene listed last is the one coming (the menu's own
        // draws wait behind a new game's first scene).
        if (_Warm.on) _warm.queue.addFirst((d, setup, tag ?? owner));
      } finally {
        assets
          ..tag = null
          ..warmFor = null
          ..phase = 'record';
        _warm.pulledScene = null;
      }
      if (sw.elapsedMicroseconds >= budgetMs * 1000) break;
    }
    return n;
  }
}
