// The calls of the engine fork that the checks use, found by symbol. The
// app then builds and runs on the engine of Flutter too. RenderPass and
// McsmDrawList pass as native pointers. They extend
// NativeFieldWrapperClass1 as the exports of flutter_gpu take them. The
// analyzer does not resolve dart:nativewrappers and does not see that.
// ignore_for_file: ffi_native_only_classes_extending_nativefieldwrapperclass1_can_be_pointer, must_be_a_subtype, extends_non_class

import 'dart:ffi';
import 'dart:io' as io;
import 'dart:nativewrappers';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart';

/// The feature bits of the engine fork, 0 on the engine of Flutter. Bit 1
/// is colour formats per attachment, 2 colour write masks, 4 the GC flags
/// of release builds and 8 retained draws. Bits 16 to 512 are described
/// at their getters. Bit 1024 marks bits of the running backend, which are
/// read again until Flutter GPU has made its context.
/// `MCSM_ENGINE_FEATURES=<mask>` keeps only the bits of the mask.
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
  // An engine without bit 1024 has final bits.
  if ((bits & 1024) != 0 ||
      !lib.providesSymbol('InternalFlutterGpu_McsmBackend')) {
    _mcsmFeaturesKnown = features;
  }
  return features;
}

int? _mcsmFeaturesKnown;

/// The backend of Flutter GPU, `metal`, `gles` or `vulkan`. Null before
/// Flutter GPU has made its context and on other engines.
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

/// Returns true when the pipelines of a pass take the own format of each
/// colour attachment. The engine of Flutter builds every attachment with
/// the format of attachment 0.
bool get mcsmMixedColorAttachmentFormats => (mcsmEngineFeatures & 1) != 0;

/// Returns true when [mcsmSetColorWriteMask] is available.
bool get mcsmColorWriteMask => (mcsmEngineFeatures & 2) != 0;

/// Sets the channels that the draws of [pass] write to colour attachment
/// [colorAttachmentIndex]. Bits 0 to 3 are red, green, blue and alpha. The
/// mask is part of the pipeline state. Needs [mcsmColorWriteMask].
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

/// Returns true when [McsmDrawList] is available.
bool get mcsmRetainedDraws => (mcsmEngineFeatures & 8) != 0;

/// Draws recorded from a render pass with [mcsmBeginRecording]. A draw keeps
/// all that it sent, the pipeline, the bindings, the vertex and index
/// buffers and the counts. [mcsmReplay] sends it again in a later pass with
/// targets of the same formats. The buffers and textures stay alive and
/// their contents may change between replays. Needs [mcsmRetainedDraws].
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

/// Appends every later draw on [pass] to [list].
void mcsmBeginRecording(RenderPass pass, McsmDrawList list) =>
    _mcsmBeginRecording(pass, list);

void mcsmEndRecording(RenderPass pass) => _mcsmEndRecording(pass);

/// Sends the draws of [list] at the first [count] of [indices] on [pass],
/// in that order. The pass sends its own bindings again with its next draw.
/// Returns false when an index is out of range or a draw failed.
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

/// Returns true when [mcsmWriteTextureDirect] can write. Bit 16, on Metal
/// only.
bool get mcsmDirectTextureWrites =>
    (mcsmEngineFeatures & 16) != 0 &&
    (io.Platform.isMacOS || io.Platform.isIOS);

/// Writes [bytes], the whole base level, into the memory of [texture] with
/// no staging buffer and no command buffer. The write happens now on the
/// CPU, so the caller makes sure that no submitted work still reads
/// [texture]. Returns false and writes nothing on another backend, for a
/// texture that is not host-visible or for a size that is not the one of
/// the base level.
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

/// Returns true when a command buffer may hold several render passes in
/// turn. Bit 64. Making a pass ends the encoder of the previous one.
bool get mcsmPassesPerCommandBuffer => (mcsmEngineFeatures & 64) != 0;

/// Returns true when [mcsmSetViewports] can set several viewports. Bit 256,
/// on Metal and on Vulkan devices with multiViewport.
bool get mcsmViewportArrays {
  final bits = mcsmEngineFeatures;
  if ((bits & 256) == 0) return false;
  // Without bit 1024 the bit 256 is the one of Metal.
  return (bits & 1024) != 0 || io.Platform.isMacOS || io.Platform.isIOS;
}

/// Returns true when a render pass binds every colour attachment. Metal
/// always does, Vulkan with bit 1024 and OpenGL ES with bit 128.
bool get mcsmMultipleColorAttachments {
  if (io.Platform.isMacOS || io.Platform.isIOS) return true;
  final bits = mcsmEngineFeatures;
  if ((bits & 1024) != 0 && mcsmBackend == 'vulkan') return true;
  return (bits & 128) != 0;
}

/// Returns true when a uniform block may hold a large array that the
/// backend binds as one buffer, on Metal and Vulkan.
bool get mcsmUniformArraysInBlocks {
  // MCSM_UNIFORM_ARRAYS=0 answers as OpenGL ES does.
  if (io.Platform.environment['MCSM_UNIFORM_ARRAYS'] == '0') return false;
  if (io.Platform.isMacOS || io.Platform.isIOS) return true;
  final bits = mcsmEngineFeatures;
  return (bits & 1024) != 0 && mcsmBackend == 'vulkan';
}

/// Returns true when the engine draws from a first instance in one call.
/// Bit 512. Another engine binds the instance buffers again at the offset.
bool get mcsmFirstInstanceDraws => (mcsmEngineFeatures & 512) != 0;

/// Sets up to 16 [viewports] and a scissor rect for each for the later
/// draws on [pass]. A primitive goes to the viewport that its vertex stage
/// writes to a `flat out uint mcsm_viewport_index` output. On Vulkan the
/// stage also writes `gl_ViewportIndex`. An empty list goes back to one
/// viewport. Returns false where the engine or backend has no viewport
/// arrays. The caller then draws tile by tile.
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
