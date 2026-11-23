// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

part of flutter_gpu;

// Lazily registers the Flutter GPU service extensions the first time a
// shader library is loaded in debug mode. Mirrors `_setupHooks` in
// `lib/ui/natives.dart` but is driven on demand because the `flutter_gpu`
// library is loaded only when the embedder imports it. Calling more than
// once is safe.
bool _hooksRegistered = false;
void _ensureHooksRegistered() {
  if (_hooksRegistered) {
    return;
  }
  _hooksRegistered = true;
  developer.registerExtension(
    'ext.ui.gpu.reinitializeShaderLibrary',
    _reinitializeShaderLibrary,
  );
}

Future<developer.ServiceExtensionResponse> _reinitializeShaderLibrary(
  String method,
  Map<String, String> parameters,
) async {
  final String? assetKey = parameters['assetKey'];
  if (assetKey != null) {
    ShaderLibrary.reinitialize(assetKey);
  }
  return developer.ServiceExtensionResponse.result(
    json.encode(<String, String>{'type': 'Success'}),
  );
}

// mcsm G1: whether the engine has the perf E exports (resolved-slot binds and
// the cached draw; third_party/flutter_engine/patches). With Flutter's
// prebuilt engine every call takes the stock path.
final bool _mcsmEngineE3 = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_RenderPass_BindUniformIndexed',
);

// mcsm G7: whether the engine draws from a first instance itself
// (third_party/flutter_engine patch 0012, mcsm7).
final bool _mcsmDrawInstanced = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_RenderPass_McsmDrawInstanced',
);

// mcsm G9: whether the engine has the additions of release mcsm9: layered
// textures, the added formats, storage buffers and compute.
final bool _mcsmEngineS2 = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_ComputePass_McsmDispatch',
);

// mcsm G15: whether the engine detaches wrappers from their native objects
// and collects at the caller's idle point (third_party/flutter_engine patch
// 0028, mcsm11).
final bool _mcsmEngine11 = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_McsmDetach',
);

@Native<Void Function(Handle)>(symbol: 'InternalFlutterGpu_McsmDetach')
external void _mcsmDetach(Object wrapper);

@Native<Int64 Function(Int64, Int64, Int64)>(
  symbol: 'InternalFlutterGpu_McsmGcIdle',
)
external int _mcsmGcIdle(int budgetMicros, int minNewBytes, int maxNewBytes);

/// mcsm G15: whether [mcsmGcIdle] reaches the VM (an mcsm11 engine).
bool get mcsmGcIdleSupported => _mcsmEngine11;

/// mcsm G15: the Dart VM's collections at the caller's idle point, every
/// isolate of the group with it. A young collection runs when new space
/// holds at least [minNewBytes] and the VM expects it to end within
/// [budgetMicros], or when it holds [maxNewBytes]; a finished old-space mark
/// is finalized and a due one started. Returns what ran (1 a young
/// collection, 2 a mark started, 4 a mark finalized); 0 on other engines.
int mcsmGcIdle(int budgetMicros, int minNewBytes, int maxNewBytes) =>
    _mcsmEngine11 ? _mcsmGcIdle(budgetMicros, minNewBytes, maxNewBytes) : 0;

// mcsm G16: whether the engine compacts the old space when asked and gives
// the heap's figures (third_party/flutter_engine patch 0029 and the Dart
// patch dart/0003, mcsm12).
final bool _mcsmEngine12 = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_McsmOldSpace',
);

@Native<Int64 Function(Int64)>(symbol: 'InternalFlutterGpu_McsmOldSpace')
external int _mcsmOldSpace(int request);

@Native<Int64 Function(Int64)>(symbol: 'InternalFlutterGpu_McsmHeap')
external int _mcsmHeap(int which);

/// mcsm G16: whether [mcsmOldSpace] and [mcsmHeap] reach the VM (an mcsm12
/// engine).
bool get mcsmOldSpaceSupported => _mcsmEngine12;

/// mcsm G16: old-space work now, every isolate of the group stopped for a
/// compaction: [request] 1 starts a concurrent mark, 2 runs a young
/// collection and a mark-compact and empties the VM's page cache. Returns
/// what ran (1 a mark started, 2 a compaction); 0 on other engines.
int mcsmOldSpace(int request) => _mcsmEngine12 ? _mcsmOldSpace(request) : 0;

/// mcsm G16: one of the isolate group's heap figures in bytes: [which] 0
/// old space used, 1 its capacity, 2 its external, 3 new space used, 4 its
/// capacity; -1 on other engines.
int mcsmHeap(int which) => _mcsmEngine12 ? _mcsmHeap(which) : -1;

/// mcsm G11: [o]'s native pointer (libc `memmove(p, p, 0)` returns p; the
/// FFI passes a wrapper as its native field). Read once per object
/// ([_mcsmSelf]): a wrapper passed to a native call becomes a new Pointer
/// object each call when the generated call isn't inlined, which the
/// AOT build of an app doesn't: ~27,000 a frame in a heavy scene.
Pointer<Void> _mcsmPointerOf(NativeFieldWrapperClass1 o) =>
    _mcsmMemmove(o, o, 0);

@Native<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Size)>(
  symbol: 'memmove',
  isLeaf: true,
)
external Pointer<Void> _mcsmMemmove(
  NativeFieldWrapperClass1 a,
  NativeFieldWrapperClass1 b,
  int n,
);
