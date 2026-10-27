// mcsm G4: live GPU memory allocated through Flutter GPU, by kind, for the
// player's memory profile. Not part of Flutter GPU.

part of flutter_gpu;

/// The bytes of the textures and device buffers made through this package
/// that are still alive (a finalizer takes a collected one off), by kind:
/// `buffer`, `rt` (render targets), `tex.private` / `tex.shared` (sampled
/// textures by storage), each with `.compressed` when block-compressed.
/// Excludes what the engine allocates itself (the Flutter surface, Impeller's
/// own render targets and host buffers).
abstract final class GpuMemory {
  static final _bytes = <String, int>{};
  static final _counts = <String, int>{};
  static final Finalizer<(String, int)> _finalizer = Finalizer((e) {
    _bytes[e.$1] = (_bytes[e.$1] ?? 0) - e.$2;
    _counts[e.$1] = (_counts[e.$1] ?? 0) - 1;
    _total -= e.$2;
  });

  static int _total = 0;

  /// [bytes] summed (mcsm G8): what the GPU holds for objects the Dart GC
  /// hasn't finalized yet, live or garbage.
  static int get totalBytes => _total;

  static void _track(Object o, String kind, int bytes) {
    _total += bytes;
    _bytes[kind] = (_bytes[kind] ?? 0) + bytes;
    _counts[kind] = (_counts[kind] ?? 0) + 1;
    _finalizer.attach(o, (kind, bytes));
  }

  static String _textureKind(Texture t) {
    final kind = switch (t.storageMode) {
      StorageMode.hostVisible => 'tex.shared',
      StorageMode.deviceTransient => 'rt.transient',
      StorageMode.devicePrivate =>
        t.enableRenderTargetUsage
            ? (t.sampleCount > 1 ? 'rt.msaa' : 'rt')
            : 'tex.private',
    };
    return t.format.isCompressed ? '$kind.compressed' : kind;
  }

  /// Live bytes by kind.
  static Map<String, int> get bytes => Map.unmodifiable(_bytes);

  /// Live objects by kind.
  static Map<String, int> get counts => Map.unmodifiable(_counts);
}
