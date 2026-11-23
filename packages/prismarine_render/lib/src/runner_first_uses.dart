// PRISMARINE_FRAME_LOG runs: what a run did for the first time in any run, and
// where a slow run's record went, as log lines on the frame log's clock.
part of 'frame_runner.dart';

/// What the runs used first (textures, meshes, pipelines in a pass and
/// their state variants), the first-recorded draws' time, and each pass's
/// record time in the run.
final class _FirstUses {
  final _usedOnce = Set<Object>.identity();
  final _usedIn = <(Object, String)>{};
  final _variants = <String>{};
  int _newVariants = 0, _textures = 0, _meshes = 0, _pipelines = 0;
  int _draws = 0, _texels = 0;

  /// The first-recorded draws' time, and their engine draw calls' where
  /// the state was new (the pipeline state objects made there; µs).
  int drawUs = 0, stateUs = 0;
  String passName = '';
  final _passes = <(String, int)>[];

  /// A run's record over this long names its slowest passes (µs).
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

  /// [d] recorded for the first time: when its state is new to its
  /// pipeline and pass, the clock's time ([stateUs] runs from it), else -1.
  int draw(
    DrawPlan d,
    gpu.RenderPipeline pipeline,
    RenderMesh? mesh,
    Stopwatch clock,
  ) {
    _draws++;
    if (mesh != null) use(mesh);
    if (_usedIn.add((pipeline, passName))) _pipelines++;
    // The engine's pipeline state object is per pipeline, pass formats
    // and state (blends, depth, stencil): a variant first made here.
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

  /// A first-recorded draw this long in the engine made a pipeline state
  /// (µs): a lookup of one made before takes a few.
  static const stateMadeUs = 300;

  /// The run's draws that made a pipeline state, by why the states made
  /// ahead missed it (_Warm.missOf), and a few of each.
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

  /// The run's lines: its first uses, and its slowest passes when its
  /// record took over [_slowUs].
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
