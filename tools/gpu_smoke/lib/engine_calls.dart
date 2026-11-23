// P23: the mcsm6 engine's capabilities (prismarine's third_party/flutter_engine
// patch 0006), found by symbol so this package still builds and runs on
// Flutter's own engine (and against its flutter_gpu, which has none of this).
// RenderPass and McsmDrawList pass as native pointers below (they extend
// NativeFieldWrapperClass1, as flutter_gpu's own exports take them); Flutter's
// analyzer can't resolve dart:nativewrappers and doesn't see that (the
// compiler does).
// ignore_for_file: ffi_native_only_classes_extending_nativefieldwrapperclass1_can_be_pointer, must_be_a_subtype, extends_non_class

import 'dart:ffi';
import 'dart:io' as io;
import 'dart:nativewrappers';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';

/// The patched engine's feature bits (`InternalFlutterGpu_McsmFeatures`; 0
/// on Flutter's prebuilt engine and on mcsm5):
/// 1 = per-attachment colour formats in pipelines, 2 = colour write masks,
/// 4 = release builds take GC sizing Dart flags, 8 = retained draws
/// ([McsmDrawList]); mcsm7: 16, 64, 128, 256, 512 (see the getters below);
/// mcsm8: 1024 = the bits are the running backend's (asked again until the
/// engine knows it, i.e. until Flutter GPU made its context).
/// `MCSM_ENGINE_FEATURES=<mask>` in the environment keeps only those bits
/// (0: every caller takes the paths it takes on other engines; A/B runs in
/// one build).
int get mcsmEngineFeatures {
  final known = _mcsmFeaturesKnown;
  if (known != null) return known;
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol('InternalFlutterGpu_McsmFeatures')) {
    return _mcsmFeaturesKnown = 0;
  }
  final bits = lib.lookupFunction<Int64 Function(), int Function()>(
    'InternalFlutterGpu_McsmFeatures',
    isLeaf: true,
  )();
  final mask = int.tryParse(
    io.Platform.environment['MCSM_ENGINE_FEATURES'] ?? '',
  );
  final features = mask == null ? bits : bits & mask;
  // An mcsm7 engine has no 1024 and never will: its bits are final too.
  if ((bits & 1024) != 0 ||
      !lib.providesSymbol('InternalFlutterGpu_McsmBackend')) {
    _mcsmFeaturesKnown = features;
  }
  return features;
}

int? _mcsmFeaturesKnown;

/// The backend Flutter GPU runs on (mcsm8 engines; null before its context
/// exists or on other engines): 'metal', 'gles' or 'vulkan'.
String? get mcsmBackend {
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol('InternalFlutterGpu_McsmBackend')) return null;
  final b = lib.lookupFunction<Int32 Function(), int Function()>(
    'InternalFlutterGpu_McsmBackend',
    isLeaf: true,
  )();
  return switch (b) {
    0 => 'metal',
    1 => 'gles',
    2 => 'vulkan',
    _ => null,
  };
}

/// Whether a render pass's pipelines take each colour attachment's own
/// format. Flutter's engine builds every attachment with attachment 0's
/// format, so a pass whose attachments differ in format needs this (and a
/// backend that binds more than one attachment: Metal, not Impeller's GLES).
bool get mcsmMixedColorAttachmentFormats => (mcsmEngineFeatures & 1) != 0;

/// Whether [mcsmSetColorWriteMask] is available.
bool get mcsmColorWriteMask => (mcsmEngineFeatures & 2) != 0;

/// Which channels [pass]'s draws write to colour attachment
/// [colorAttachmentIndex] (bits 0..3 = r, g, b, a; 0 writes none), part of
/// the pipeline state like the blend. Needs [mcsmColorWriteMask].
void mcsmSetColorWriteMask(
  RenderPass pass,
  int mask, {
  int colorAttachmentIndex = 0,
}) {
  if (!mcsmColorWriteMask) {
    throw UnsupportedError('mcsmSetColorWriteMask needs the mcsm6 engine');
  }
  _mcsmSetColorWriteMask(pass, colorAttachmentIndex, mask & 0xF);
}

@Native<Void Function(Pointer<Void>, Int, Int)>(
  symbol: 'InternalFlutterGpu_RenderPass_SetColorWriteMask',
)
external void _mcsmSetColorWriteMask(
  RenderPass pass,
  int colorAttachmentIndex,
  int writeMask,
);

/// Whether [McsmDrawList] is available (patch 0008).
bool get mcsmRetainedDraws => (mcsmEngineFeatures & 8) != 0;

/// Draws recorded from a render pass ([mcsmBeginRecording]), everything each
/// sent to the GPU (pipeline, bindings, vertex and index buffers, counts),
/// to send again in later passes with the same targets' formats
/// ([mcsmReplay]). The buffers and textures are kept alive; their contents
/// may change between replays (a caller that rewrites a buffer the GPU may
/// still read keeps one per frame in flight). Needs [mcsmRetainedDraws].
base class McsmDrawList extends NativeFieldWrapperClass1 {
  McsmDrawList() {
    if (!mcsmRetainedDraws) {
      throw UnsupportedError('McsmDrawList needs the mcsm6 engine');
    }
    _initialize(this);
  }

  /// The draws recorded so far.
  int get length => _length();

  void clear() => _clear();

  @Native<Void Function(Handle)>(
    symbol: 'InternalFlutterGpu_DrawList_Initialize',
  )
  external static void _initialize(McsmDrawList wrapper);

  @Native<Int Function(Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_DrawList_GetLength',
    isLeaf: true,
  )
  external int _length();

  @Native<Void Function(Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_DrawList_Clear',
    isLeaf: true,
  )
  external void _clear();
}

/// From now on every draw on [pass] is also appended to [list].
void mcsmBeginRecording(RenderPass pass, McsmDrawList list) =>
    _mcsmBeginRecording(pass, list);

void mcsmEndRecording(RenderPass pass) => _mcsmEndRecording(pass);

/// Sends [list]'s draws at `indices[0, count)`, in that order, on [pass];
/// the pass's own bindings are sent again with its next draw. False when an
/// index was out of range or a draw failed.
bool mcsmReplay(
  RenderPass pass,
  McsmDrawList list,
  Int32List indices,
  int count,
) {
  RangeError.checkValueInInterval(count, 0, indices.length, 'count');
  return _mcsmReplay(pass, list, indices, count);
}

@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_RenderPass_BeginRecording',
  isLeaf: true,
)
external void _mcsmBeginRecording(RenderPass pass, McsmDrawList list);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_RenderPass_EndRecording',
  isLeaf: true,
)
external void _mcsmEndRecording(RenderPass pass);

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Handle, Int)>(
  symbol: 'InternalFlutterGpu_RenderPass_Replay',
)
external bool _mcsmReplay(
  RenderPass pass,
  McsmDrawList list,
  Int32List indices,
  int count,
);

/// Whether [mcsmWriteTextureDirect] can write (patch 0009, mcsm7, bit 16):
/// Metal only (macOS, iOS); elsewhere textures upload the usual way.
bool get mcsmDirectTextureWrites =>
    (mcsmEngineFeatures & 16) != 0 &&
    (io.Platform.isMacOS || io.Platform.isIOS);

/// Writes [bytes] (the whole base level) straight into [texture]'s memory:
/// no staging buffer and no command buffer (Metal's replaceRegion on a
/// host-visible texture). The write happens now, on the CPU, so the caller
/// makes sure no submitted GPU work still reads [texture] (a ring of
/// textures gated on [rendererSubmissions]' completion). Returns false, with
/// nothing written, where the engine can't (another backend, a texture that
/// isn't host-visible, a size that isn't the base level's): upload another
/// way then.
bool mcsmWriteTextureDirect(Texture texture, ByteData bytes, {int slice = 0}) {
  if (!mcsmDirectTextureWrites) return false;
  return _mcsmWriteDirect(texture, gpuContext, bytes, slice);
}

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Handle, Int)>(
  symbol: 'InternalFlutterGpu_Texture_McsmWriteDirect',
)
external bool _mcsmWriteDirect(
  Texture texture,
  GpuContext context,
  ByteData bytes,
  int slice,
);

/// Whether a command buffer may hold several render passes in turn (patch
/// 0009, mcsm7): creating a pass ends the encoder of the command buffer's
/// previous one, which then refuses draws. On other engines Metal allows
/// only one pass per command buffer, so each pass needs its own.
bool get mcsmPassesPerCommandBuffer => (mcsmEngineFeatures & 64) != 0;

/// Whether [mcsmSetViewports] can set several viewports (feature bit 256):
/// Metal (patch 0011) and, on an mcsm8 engine, Vulkan where the device has
/// multiViewport and the vertex viewport index. GLES draws per tile.
bool get mcsmViewportArrays {
  final bits = mcsmEngineFeatures;
  if ((bits & 256) == 0) return false;
  // mcsm8 engines report the running backend's bits (1024); mcsm7's bit 256
  // was Metal's only.
  return (bits & 1024) != 0 || io.Platform.isMacOS || io.Platform.isIOS;
}

/// Whether a render pass binds every colour attachment (perf3): Metal always
/// (Flutter's own engine too); GLES with the mcsm7+ engine's bit 128
/// (Impeller's GLES binds only the first otherwise); Vulkan (mcsm8). The
/// shadow occlusion pass then writes the exe's layout and is the depth
/// prepass (mcsm_look_scene TtShadows).
bool get mcsmMultipleColorAttachments {
  if (io.Platform.isMacOS || io.Platform.isIOS) return true;
  final bits = mcsmEngineFeatures;
  if ((bits & 1024) != 0 && mcsmBackend == 'vulkan') return true;
  return (bits & 128) != 0;
}

/// Whether a uniform block may hold a large array that the backend binds as
/// one buffer (perf3): Metal and Vulkan. Impeller's GLES sets a block member
/// by member (glUniform*), where a big array runs into the stage's uniform
/// vector limit, so GLES callers keep such data in a texture.
bool get mcsmUniformArraysInBlocks {
  // MCSM_UNIFORM_ARRAYS=0: as on GLES (checks).
  if (io.Platform.environment['MCSM_UNIFORM_ARRAYS'] == '0') return false;
  if (io.Platform.isMacOS || io.Platform.isIOS) return true;
  final bits = mcsmEngineFeatures;
  return (bits & 1024) != 0 && mcsmBackend == 'vulkan';
}

/// Whether the engine draws from a first instance itself (patch 0012,
/// mcsm7, feature bit 512): `RenderPass.draw(…, firstInstance: n)` is one
/// leaf call. flutter_gpu's draw takes `firstInstance` on every engine
/// (others bind the instance buffers again at the offset).
bool get mcsmFirstInstanceDraws => (mcsmEngineFeatures & 512) != 0;

/// Sets [viewports] (at most 16) and a scissor rect for each for the draws
/// that follow on [pass]: each primitive goes to the viewport its vertex
/// stage names in a `flat out uint mcsm_viewport_index` output (P34 makes it
/// Metal's `[[viewport_array_index]]`; for Vulkan the shader also writes
/// `gl_ViewportIndex` under `#ifdef IMPELLER_TARGET_VULKAN`, with
/// `#extension GL_ARB_shader_viewport_layer_array : require` there), so an
/// instanced draw can put each
/// instance in its own atlas tile; the rasterizer maps each viewport exactly
/// as a draw with that one viewport (prismarine's tools/gpu_smoke checks the bytes). An
/// empty list goes back to one viewport (the draws' own, else the whole
/// target). Returns false where the engine or backend can't (GLES): then
/// draw per tile (with the index 0).
bool mcsmSetViewports(
  RenderPass pass,
  List<Viewport> viewports, {
  List<Scissor>? scissors,
}) {
  if (!mcsmViewportArrays || viewports.length > 16) return false;
  final n = viewports.length;
  final v = Float32List(6 * n);
  final s = Int32List(4 * n);
  for (var i = 0; i < n; i++) {
    final p = viewports[i];
    v
      ..[6 * i] = p.x.toDouble()
      ..[6 * i + 1] = p.y.toDouble()
      ..[6 * i + 2] = p.width.toDouble()
      ..[6 * i + 3] = p.height.toDouble()
      ..[6 * i + 4] = p.depthRange.zNear
      ..[6 * i + 5] = p.depthRange.zFar;
    final r = scissors?[i];
    s
      ..[4 * i] = r?.x ?? p.x
      ..[4 * i + 1] = r?.y ?? p.y
      ..[4 * i + 2] = r?.width ?? p.width
      ..[4 * i + 3] = r?.height ?? p.height;
  }
  return _mcsmSetViewports(pass, v, s, n);
}

@Native<Bool Function(Pointer<Void>, Handle, Handle, Int)>(
  symbol: 'InternalFlutterGpu_RenderPass_McsmSetViewports',
)
external bool _mcsmSetViewports(
  RenderPass pass,
  Float32List viewports,
  Int32List scissors,
  int count,
);
