part of 'frame_runner.dart';

/// sRGB views of 8-bit RGBA targets. A pass that draws or samples a target
/// through an sRGB view uses a view of the same texture in the sRGB format
/// from `Texture.makeView(format:)` of the patched engine. The bytes are
/// those of one texture whichever way they are read or written.
extension _RunnerSrgb on FrameRunner {
  bool _srgbCapable(String target) {
    final f = _specs[target]?.format;
    return f == 'R8G8B8A8_UNORM' || f == 'RGBA8';
  }

  /// Returns the target [target] through an sRGB view, kept while the
  /// texture of the target is the same object.
  gpu.Texture _srgbView(String target) {
    final base = targets[target]!;
    final had = _srgbViews[target];
    if (had != null && had.$1 == base) return had.$2;
    _texGen++;
    final view = base.makeView(
      mipLevelCount: base.mipLevelCount,
      format: gpu.PixelFormat.r8g8b8a8UNormIntSRGB,
    );
    // alloc: a new target viewed as sRGB
    _srgbViews[target] = (base, view);
    return view;
  }

  /// Returns the texture that the colour attachment [c] draws into.
  gpu.Texture _colorTexture(Attachment c) => c.srgb && _srgbCapable(c.target)
      ? _srgbView(c.target)
      : targets[c.target]!;
}
