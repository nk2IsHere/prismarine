part of 'frame_runner.dart';

/// What a closed scene alone held on the GPU, let go once the scenes open
/// after it have had their frames and warm-ups (RenderHost's release).
extension RunnerRelease on FrameRunner {
  /// A scene closed: what is asked for from now on is the open scenes';
  /// the epoch to give [release].
  int closed() {
    pulled?.closed();
    _targetEpoch++;
    return _pipelines.epoch = assets.closed();
  }

  // alloc-cold: once per scene close.
  /// Lets go of the textures, meshes and cooked scenes nothing asked for
  /// since the close [closed] returned [since] (but what a scene in
  /// [keepOwners] asked for, and the predicted [held] scene's loads), and
  /// the targets no plan named since then; a live draw keeps what it
  /// holds. A line for the log.
  String release(int since, {String? held, int keepOwners = 0}) {
    final loads = assets.release(since, held: held, keepOwners: keepOwners);
    final cooked = pulled?.release(since, keepOwners) ?? 0;
    final gone = pulled?.letGo(_runs - 64) ?? const <String>[];
    if (gone.isNotEmpty) {
      // Kept rows and buckets may name a cooked scene let go.
      for (final f in _pulledFrames.values) {
        f
          ..kept = null
          ..bucketPool.clear();
      }
      gone.forEach(_warm._cooked.remove);
    }
    final pipelines = _pipelines.loosen(since, keepOwners: keepOwners);
    final named = _ensured;
    var dropped = 0, bytes = 0;
    for (final name in [...targets.keys]) {
      if (named != null && named.containsKey(name)) continue;
      if ((_namedAt[name] ?? 0) >= since) continue;
      final s = _specs.remove(name);
      targets.remove(name);
      _namedAt.remove(name);
      _views.removeWhere((k, _) => k.startsWith('$name|'));
      _srgbViews.remove(name);
      _stencilCopies.remove(name);
      if (s != null) bytes += targetBytes(s);
      dropped++;
    }
    if (dropped > 0) _texGen++;
    return '$loads textures and meshes, $pipelines pipelines, $cooked cooked '
        'scenes (${gone.length} let go), $dropped targets (${bytes >> 20} MB)';
  }

  // alloc-cold: once per prediction given back.
  /// A predicted scene given back: its cooked scene, read ahead for it, and
  /// the pipelines made for it alone are let go (a draw that holds one
  /// keeps it), and made again if it opens. How many pipelines went.
  int forgetCooked(String scene) {
    final name = scene.endsWith('.scene')
        ? scene.substring(0, scene.length - 6)
        : scene;
    final pipelines = _tagged.forget(this, scene.toLowerCase());
    pulled
      ?.._scenes.remove(name)
      .._aheadAt.remove(name);
    _warm._cooked.remove(name);
    return pipelines;
  }

  /// The scenes asking now, a bit each (RenderAssets.owners).
  set owners(int m) {
    assets.owners = m;
    pulled?._scenes.owners = m;
  }

  /// The scene shown (a scene file's name): new pulled draws take their
  /// meshes from its cooked scene first (Pulled.batch).
  set shownScene(String? scene) => pulled?.shown = scene;

  // alloc-cold: a diagnostics line now and then.
  /// What the runner keeps, counted (the memory census).
  String get census {
    final (n, bytes) = targetsHeld;
    final gpuBytes = <String>[
      for (final MapEntry(:key, :value) in gpu.GpuMemory.bytes.entries)
        '$key ${value >> 20}',
    ];
    final counts = gpu.GpuMemory.counts;
    return 'targets $n (${bytes >> 20} MB), pipelines ${_pipelines.length} '
        '(+${_pipelines.looseAlive} loose alive), '
        'compute ${_computePipelines.length}/${_computeSetups.length}, plan '
        'buffers ${_buffers.length}, '
        'constants ${_constants.length}, views ${_views.length}, roleViews '
        '${_roleViews.length}, uniformViews ${_uniformViews.length}, inline '
        '${_inlineSlots.length}, stencilDraws ${_stencilDraws.length}, pulled '
        '${pulled?._scenes.length}(+${pulled?._scenes.looseAlive}) scenes '
        '${pulled?._scenes.heldKeys.toList()}; '
        'assets: ${assets.census}; gpu MB '
        '${gpuBytes.join(', ')}; gpu objects $counts';
  }

  /// The render targets held and their bytes (diagnostics).
  (int, int) get targetsHeld {
    var bytes = 0;
    for (final s in _specs.values) {
      bytes += targetBytes(s);
    }
    return (_specs.length, bytes);
  }
}

/// The pipelines made for a scene the game has not opened yet (while
/// RenderAssets.tag names it) and used by nothing else since: given back with
/// the scene's prediction (RunnerRelease.forgetCooked), as its textures
/// and meshes are.
final class _PipelineTags {
  final _scene = <Object, String>{};
  bool get any => _scene.isNotEmpty;

  // alloc-cold: a pipeline's first make.
  /// [p], made now for [key], held, and tagged with the scene being made
  /// ready, if any.
  gpu.RenderPipeline made(FrameRunner r, Object key, gpu.RenderPipeline p) {
    r._pipelines[key] = p;
    if (r.assets.tag case final t?) _scene[key] = t;
    return p;
  }

  /// [key]'s pipeline asked for: outside its scene's making ready, it is
  /// everyone's.
  void used(FrameRunner r, Object key) {
    final t = _scene[key];
    if (t != null && t != r.assets.tag) _scene.remove(key);
  }

  // alloc-cold: once per prediction given back.
  /// Drops the pipelines tagged with [scene] alone; how many.
  int forget(FrameRunner r, String scene) {
    var n = 0;
    _scene.removeWhere((key, s) {
      if (s != scene) return false;
      if (r._pipelines.remove(key) != null) n++;
      return true;
    });
    return n;
  }
}

extension on Pulled {
  /// A scene closed (RunnerRelease.closed).
  void closed() => _scenes.epoch++;

  /// Lets go of the cooked scenes nothing asked for since [since] and no
  /// scene in [keepOwners] asked for.
  int release(int since, int keepOwners) =>
      _scenes.loosen(since, keepOwners: keepOwners);
}

/// [s]'s bytes as allocated, near enough (the driver's padding not
/// counted): texel size by format, layers, samples and a mip chain's third.
int targetBytes(TargetSpec s) {
  final f = s.format;
  final texel = f.startsWith('R32G32B32A32')
      ? 16
      : f.startsWith('R16G16B16A16') || f.startsWith('R32G32_') || f == 'D32S8'
      ? 8
      : f.startsWith('R16_') || f.startsWith('R8G8_') || f.startsWith('D16')
      ? 2
      : f.startsWith('R8_') || f.startsWith('A8')
      ? 1
      : 4;
  final base = s.width * s.height * s.layers * s.samples * texel;
  return s.mips > 1 ? base * 4 ~/ 3 : base;
}
