// Runs with PRISMARINE_FRAME_LOG log the first uses of each run and the
// record time of a slow run by pass, on the clock of the frame log.
part of 'frame_runner.dart';

/// The first uses of the runs, such as textures, meshes, pipelines in a pass
/// and their state variants, with the time of the first-recorded draws and
/// the record time of each pass in the run.
final class _FirstUses {
  final _usedOnce = Set<Object>.identity();
  final _usedIn = <(Object, String)>{};
  final _variants = <String>{};
  int _newVariants = 0, _textures = 0, _meshes = 0, _pipelines = 0;
  int _draws = 0, _texels = 0;

  /// The time in µs of the first-recorded draws and of their draw calls in
  /// the engine where the state was new, which made pipeline state objects.
  int drawUs = 0, stateUs = 0;
  String passName = '';
  final _passes = <(String, int)>[];

  /// The record time in µs past which a run logs its slowest passes.
  static const _slowUs = 30000;

  void use(Object o) {
    if (!_usedOnce.add(o)) return;
    if (o is gpu.Texture) {
      _textures++;
      _texels += o.width * o.height;
    } else {
      _meshes++;
    }
  }

  /// Notes the first record of [d]. Returns the time of the clock when its
  /// state is new to its pipeline and pass, else -1. [stateUs] counts from
  /// that time.
  int draw(
    DrawPlan d,
    gpu.RenderPipeline pipeline,
    RenderMesh? mesh,
    Stopwatch clock,
  ) {
    _draws++;
    if (mesh != null) use(mesh);
    if (_usedIn.add((pipeline, passName))) _pipelines++;
    // The engine has one pipeline state object per pipeline, pass formats
    // and state, such as blends, depth and stencil. A new variant is made
    // here.
    final st = d.state;
    final variant =
        '${identityHashCode(pipeline)}|$passName|${st.depthTest}'
        '${st.depthWrite}${st.depthFunc}|${st.stencil?.func}'
        '${st.stencil?.passOp}|${st.cull}|${st.topology}|'
        '${[for (final b in st.blends) '${b.enabled}${b.color}${b.alpha}${b.writeMask}'].join(',')}';
    if (!_variants.add(variant)) return -1;
    _newVariants++;
    return clock.elapsedMicroseconds;
  }

  void pass(String name, int us) => _passes.add((name, us));

  /// The time in µs past which a first-recorded draw in the engine counts
  /// as one that made a pipeline state. A lookup of a state made before
  /// takes a few µs.
  static const stateMadeUs = 300;

  /// The draws of the run that made a pipeline state, by the reason that
  /// the states made ahead missed them (_Warm.missOf), with a few of each.
  final _missed = <String, (int, int)>{};
  final _missedSome = <String>[];

  void missed(String why, DrawPlan d, int us) {
    final (n, total) = _missed[why] ?? (0, 0);
    _missed[why] = (n + 1, total + us);
    if (_missedSome.length < 16) {
      _missedSome.add(
        '$why $passName ${(us / 1000).toStringAsFixed(1)} ms ${d.vertex} '
        '${d.pixel} ${_stateKey(d.state)}',
      );
    }
  }

  /// Logs the first uses of the run to [warn] and its slowest passes when
  /// its record of [recordUs] took over [_slowUs].
  void ran(void Function(String)? warn, int recordUs) {
    final now = Timeline.now;
    if (_draws > 0) {
      warn?.call(
        'first uses $now $_draws draws first recorded: $_pipelines '
        'pipelines in a pass ($_newVariants with new state), $_meshes '
        'meshes, $_textures textures (${_texels >> 20} Mtexels) first used; '
        '${(drawUs / 1000).toStringAsFixed(1)} ms recording them, '
        '${(stateUs / 1000).toStringAsFixed(1)} ms in the engine draws '
        'with new state',
      );
    }
    if (_missed.isNotEmpty) {
      warn?.call(
        'states missed $now: ${[for (final MapEntry(:key, value: (n, us)) in _missed.entries) '$key $n (${(us / 1000).toStringAsFixed(1)} ms)'].join(', ')}',
      );
      for (final m in _missedSome) {
        warn?.call('state missed $now $m');
      }
      _missed.clear();
      _missedSome.clear();
    }
    if (recordUs > _slowUs) {
      _passes.sort((a, b) => b.$2.compareTo(a.$2));
      warn?.call(
        'slow record $now ${(recordUs / 1000).toStringAsFixed(1)} ms: '
        '${_passes.take(8).map((p) => '${p.$1} ${(p.$2 / 1000).toStringAsFixed(1)}').join(', ')}',
      );
    }
    _passes.clear();
    _draws = _pipelines = _meshes = _textures = _newVariants = 0;
    drawUs = stateUs = _texels = 0;
  }
}
