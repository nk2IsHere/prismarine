// The render targets of the plans of a runner, made again when their specs
// change.
part of 'frame_runner.dart';

extension _RunnerTargets on FrameRunner {
  void _ensureTargets(FramePlan plan) {
    // The same map as in the last run has nothing to make. The codec gives it
    // again while the targets hold.
    if (identical(plan.targets, _ensured)) return;
    _ensured = plan.targets;
    _makeTargets(plan);
  }

  // alloc-cold: a plan with another map of targets.
  /// Makes the targets of [plan] that are new or changed.
  void _makeTargets(FramePlan plan) {
    for (final name in plan.targets.keys) {
      final s = plan.targets[name]!;
      if (_namedAt[name] != _targetEpoch) _namedAt[name] = _targetEpoch;
      final had = _specs[name];
      if (had != null &&
          had.width == s.width &&
          had.height == s.height &&
          had.format == s.format &&
          had.layers == s.layers &&
          had.mips == s.mips &&
          had.samples == s.samples &&
          had.storage == s.storage &&
          had.volume == s.volume) {
        continue;
      }
      final f = pixelFormat(s.format);
      try {
        targets[name] = _create(s, f);
      } catch (e) {
        throw StateError(
          'target $name (${s.width}x${s.height} ${s.format}, ${s.layers} '
          'layers, ${s.mips} mips, ${s.samples} samples'
          '${s.storage ? ', storage' : ''}${s.volume ? ', 3D' : ''}): $e',
        );
      }
      _specs[name] = s;
      if (FrameRunner.firstUses) {
        warn?.call(
          'target made ${Timeline.now} $name ${s.width}x${s.height} '
          '${s.format} ${s.layers} layers ${s.mips} mips ${s.samples} samples',
        );
      }
      _views.removeWhere((k, _) => k.startsWith('$name|'));
      _texGen++;
    }
  }

  gpu.Texture _create(TargetSpec s, gpu.PixelFormat f) =>
      gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        s.width,
        s.height,
        format: f,
        sampleCount: s.samples,
        textureType: s.samples > 1
            ? gpu.TextureType.texture2DMultisample
            : s.volume
            ? gpu.TextureType.texture3D
            : (s.layers > 1 ? gpu.TextureType.texture2DArray : null),
        layers: s.volume ? 1 : s.layers,
        depth: s.volume ? s.layers : 1,
        mipLevelCount: s.mips,
        enableShaderWriteUsage: s.storage,
        // Only compute writes a 3D texture.
        enableRenderTargetUsage: !s.volume,
      );
}
