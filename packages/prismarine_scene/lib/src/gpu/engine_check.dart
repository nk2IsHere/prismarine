import 'dart:ffi';

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'engine.dart';

/// The engine release of this version of prismarine, the one in
/// `third_party/flutter_engine/RELEASE`.
const prismarineEngineRelease = 'engine-deb287481e3c-prismarine1';

/// Feature bits of the patched engine that code can require.
abstract final class EngineFeatures {
  /// Layered textures, the added formats, storage buffers and compute.
  static const compute = 2048;

  /// Vertex stages without inputs, more bindings per draw, indirect draws
  /// and sRGB texture views.
  static const bindings = 4096;

  /// Collections at an idle point of the caller.
  static const gcIdle = 8192;

  /// Compaction of the old space on request and the figures of the heap.
  static const oldSpace = 16384;

  static const _names = {
    compute: 'compute',
    bindings: 'the added bindings',
    gcIdle: 'the idle collections',
    oldSpace: 'the heap figures',
  };

  /// The words for the bits of [bits], such as `compute and the heap
  /// figures`.
  static String describe(int bits) {
    final names = [
      for (final MapEntry(:key, :value) in _names.entries)
        if (bits & key != 0) value,
    ];
    if (names.length < 2) return names.join();
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
}

/// Returns null when the running engine has every feature bit of [needs],
/// else the one message for the case that happened, with its fix.
String? engineProblem(int needs) {
  gpu.GpuContext? context;
  try {
    context = gpu.gpuContext;
  } on Object {
    context = null;
  }
  if (context == null) {
    return 'The app runs on the engine of Flutter. It needs the patched '
        'engine $prismarineEngineRelease. Build it with `prismarine build`.';
  }
  final have = gpuFeatures;
  if (have == 0) {
    final patched = DynamicLibrary.process().providesSymbol(
      'InternalFlutterGpu_RenderPass_BindUniformIndexed',
    );
    return patched
        ? 'The app runs on a patched engine older than '
              '$prismarineEngineRelease. Run `prismarine engine` and build '
              'again with `prismarine build`.'
        : 'The app runs on the engine of Flutter. It needs the patched '
              'engine $prismarineEngineRelease. Build it with `prismarine '
              'build`.';
  }
  final missing = needs & ~have;
  if (missing == 0) return null;
  return 'The engine lacks ${EngineFeatures.describe(missing)} of release '
      '$prismarineEngineRelease. Run `prismarine engine` and build again '
      'with `prismarine build`.';
}

/// Throws an [EngineMismatch] when the running engine lacks a feature bit
/// of [needs].
void requireEngine(int needs) {
  final problem = engineProblem(needs);
  if (problem != null) throw EngineMismatch(problem);
}

/// The running engine is not the one that the app needs.
class EngineMismatch implements Exception {
  EngineMismatch(this.message);
  final String message;
  @override
  String toString() => message;
}
