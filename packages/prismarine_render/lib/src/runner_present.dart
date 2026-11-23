part of 'frame_runner.dart';

/// The copies of the present target that a frame ends with, three in turn.
extension _RunnerPresent on FrameRunner {
  gpu.Texture _presentCopy(gpu.Texture t) {
    final k = _presentTurn++ % 3;
    if (k < _presented.length) {
      final had = _presented[k];
      if (had.width == t.width && had.height == t.height) return had;
    }
    final copy = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      t.width,
      t.height,
      format: t.format,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true,
    );
    if (k < _presented.length) {
      _presented[k] = copy;
    } else {
      _presented.add(copy);
    }
    return copy;
  }
}
