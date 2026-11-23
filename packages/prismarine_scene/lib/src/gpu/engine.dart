import 'dart:ffi';

/// The backend of Flutter GPU, `metal`, `vulkan` or `gles`. Null on an
/// engine without the call of the engine fork and before Flutter GPU has
/// made its context.
String? get gpuBackend {
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol(_backend)) return null;
  final b = lib.lookupFunction<Int32 Function(), int Function()>(
    _backend,
    isLeaf: true,
  )();
  return switch (b) {
    0 => 'metal',
    1 => 'gles',
    2 => 'vulkan',
    _ => null,
  };
}

/// The feature bits of the engine fork, 0 on another engine. The README of
/// the engine lists them.
int get gpuFeatures {
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol(_features)) return 0;
  return lib.lookupFunction<Int64 Function(), int Function()>(
    _features,
    isLeaf: true,
  )();
}

const _backend = 'InternalFlutterGpu_McsmBackend';
const _features = 'InternalFlutterGpu_McsmFeatures';
