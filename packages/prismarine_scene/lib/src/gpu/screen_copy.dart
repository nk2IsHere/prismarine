import 'package:flutter_gpu/gpu.dart' as gpu;

/// A copy of a texture over the whole render target. The vertex stage takes
/// two triangles of 2D clip-space positions in a buffer of `vec2`. The
/// fragment stage samples [source] at the matching point of the texture,
/// with the origin at the top left.
class ScreenCopy {
  ScreenCopy._(this.vertex, this.fragment)
    : pipeline = gpu.gpuContext.createRenderPipeline(vertex, fragment),
      source = fragment.getUniformSlot('source_texture');

  /// Loads the copy from the shader bundle of the package once. Later calls
  /// return the same copy.
  static Future<ScreenCopy> load() async {
    if (loaded case final c?) return c;
    final library =
        await gpu.ShaderLibrary.fromAsset(_bundle) ??
        (throw StateError('$_bundle is not in the app. Build the app again.'));
    return loaded ??= ScreenCopy._(
      library['ScreenCopyVertex']!,
      library['ScreenCopyFragment']!,
    );
  }

  /// The copy after [load] completed, else null.
  static ScreenCopy? loaded;

  static const _bundle =
      'packages/prismarine_scene/build/shaderbundles/screen_copy.shaderbundle';

  final gpu.Shader vertex, fragment;
  final gpu.RenderPipeline pipeline;
  final gpu.UniformSlot source;
}
