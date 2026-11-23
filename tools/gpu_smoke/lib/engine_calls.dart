// The calls of the engine fork that the checks use, found by symbol. The
// app then builds and runs on the engine of Flutter too. RenderPass and
// PrismarineDrawList pass as native pointers. They extend
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
/// `PRISMARINE_ENGINE_FEATURES=<mask>` keeps only the bits of the mask. The
/// old form `MCSM_ENGINE_FEATURES` is read too.
int get prismarineEngineFeatures {
  final known = _prismarineFeaturesKnown;
  if (known != null) return known;
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol('InternalFlutterGpu_PrismarineFeatures')) {
    return _prismarineFeaturesKnown = 0;
  }
  final bits = lib.lookupFunction<Int64 Function(), int Function()>(
    'InternalFlutterGpu_PrismarineFeatures',
    isLeaf: true,
  )();
  final mask = int.tryParse(
    io.Platform.environment['PRISMARINE_ENGINE_FEATURES'] ??
        io.Platform.environment['MCSM_ENGINE_FEATURES'] ??
        '',
  );
  final features = mask == null ? bits : bits & mask;
  // An engine without bit 1024 has final bits.
  if ((bits & 1024) != 0 ||
      !lib.providesSymbol('InternalFlutterGpu_PrismarineBackend')) {
    _prismarineFeaturesKnown = features;
  }
  return features;
}

int? _prismarineFeaturesKnown;

/// The backend of Flutter GPU, `metal`, `gles` or `vulkan`. Null before
/// Flutter GPU has made its context and on other engines.
String? get prismarineBackend {
  final lib = DynamicLibrary.process();
  if (!lib.providesSymbol('InternalFlutterGpu_PrismarineBackend')) return null;
  final b = lib.lookupFunction<Int32 Function(), int Function()>(
    'InternalFlutterGpu_PrismarineBackend',
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
bool get prismarineMixedColorAttachmentFormats =>
    (prismarineEngineFeatures & 1) != 0;

/// Returns true when [prismarineSetColorWriteMask] is available.
bool get prismarineColorWriteMask => (prismarineEngineFeatures & 2) != 0;

/// Sets the channels that the draws of [pass] write to colour attachment
/// [colorAttachmentIndex]. Bits 0 to 3 are red, green, blue and alpha. The
/// mask is part of the pipeline state. Needs [prismarineColorWriteMask].
void prismarineSetColorWriteMask(
  RenderPass pass,
  int mask, {
  int colorAttachmentIndex = 0,
}) {
  if (!prismarineColorWriteMask) {
    throw UnsupportedError(
      'prismarineSetColorWriteMask needs an engine with feature bit 2',
    );
  }
  _prismarineSetColorWriteMask(pass, colorAttachmentIndex, mask & 0xF);
}

@Native<Void Function(Pointer<Void>, Int, Int)>(
  symbol: 'InternalFlutterGpu_RenderPass_SetColorWriteMask',
)
external void _prismarineSetColorWriteMask(
  RenderPass pass,
  int colorAttachmentIndex,
  int writeMask,
);

/// Returns true when [PrismarineDrawList] is available.
bool get prismarineRetainedDraws => (prismarineEngineFeatures & 8) != 0;

/// Draws recorded from a render pass with [prismarineBeginRecording]. A draw
/// keeps all that it sent, the pipeline, the bindings, the vertex and index
/// buffers and the counts. [prismarineReplay] sends it again in a later pass
/// with targets of the same formats. The buffers and textures stay alive and
/// their contents may change between replays. Needs [prismarineRetainedDraws].
base class PrismarineDrawList extends NativeFieldWrapperClass1 {
  PrismarineDrawList() {
    if (!prismarineRetainedDraws) {
      throw UnsupportedError(
        'PrismarineDrawList needs an engine with feature bit 8',
      );
    }
    _initialize(this);
  }

  /// The draws recorded so far.
  int get length => _length();

  void clear() => _clear();

  @Native<Void Function(Handle)>(
    symbol: 'InternalFlutterGpu_DrawList_Initialize',
  )
  external static void _initialize(PrismarineDrawList wrapper);

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
void prismarineBeginRecording(RenderPass pass, PrismarineDrawList list) =>
    _prismarineBeginRecording(pass, list);

void prismarineEndRecording(RenderPass pass) => _prismarineEndRecording(pass);

/// Sends the draws of [list] at the first [count] of [indices] on [pass],
/// in that order. The pass sends its own bindings again with its next draw.
/// Returns false when an index is out of range or a draw failed.
bool prismarineReplay(
  RenderPass pass,
  PrismarineDrawList list,
  Int32List indices,
  int count,
) {
  RangeError.checkValueInInterval(count, 0, indices.length, 'count');
  return _prismarineReplay(pass, list, indices, count);
}

@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_RenderPass_BeginRecording',
  isLeaf: true,
)
external void _prismarineBeginRecording(
  RenderPass pass,
  PrismarineDrawList list,
);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_RenderPass_EndRecording',
  isLeaf: true,
)
external void _prismarineEndRecording(RenderPass pass);

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Handle, Int)>(
  symbol: 'InternalFlutterGpu_RenderPass_Replay',
)
external bool _prismarineReplay(
  RenderPass pass,
  PrismarineDrawList list,
  Int32List indices,
  int count,
);

/// Returns true when [prismarineWriteTextureDirect] can write. Bit 16, on Metal
/// only.
bool get prismarineDirectTextureWrites =>
    (prismarineEngineFeatures & 16) != 0 &&
    (io.Platform.isMacOS || io.Platform.isIOS);

/// Writes [bytes], the whole base level, into the memory of [texture] with
/// no staging buffer and no command buffer. The write happens now on the
/// CPU, so the caller makes sure that no submitted work still reads
/// [texture]. Returns false and writes nothing on another backend, for a
/// texture that is not host-visible or for a size that is not the one of
/// the base level.
bool prismarineWriteTextureDirect(
  Texture texture,
  ByteData bytes, {
  int slice = 0,
}) {
  if (!prismarineDirectTextureWrites) return false;
  return _prismarineWriteDirect(texture, gpuContext, bytes, slice);
}

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Handle, Int)>(
  symbol: 'InternalFlutterGpu_Texture_PrismarineWriteDirect',
)
external bool _prismarineWriteDirect(
  Texture texture,
  GpuContext context,
  ByteData bytes,
  int slice,
);

/// Returns true when a command buffer may hold several render passes in
/// turn. Bit 64. Making a pass ends the encoder of the previous one.
bool get prismarinePassesPerCommandBuffer =>
    (prismarineEngineFeatures & 64) != 0;

/// Returns true when [prismarineSetViewports] can set several viewports. Bit
/// 256, on Metal and on Vulkan devices with multiViewport.
bool get prismarineViewportArrays {
  final bits = prismarineEngineFeatures;
  if ((bits & 256) == 0) return false;
  // Without bit 1024 the bit 256 is the one of Metal.
  return (bits & 1024) != 0 || io.Platform.isMacOS || io.Platform.isIOS;
}

/// Returns true when a render pass binds every colour attachment. Metal
/// always does, Vulkan with bit 1024 and OpenGL ES with bit 128.
bool get prismarineMultipleColorAttachments {
  if (io.Platform.isMacOS || io.Platform.isIOS) return true;
  final bits = prismarineEngineFeatures;
  if ((bits & 1024) != 0 && prismarineBackend == 'vulkan') return true;
  return (bits & 128) != 0;
}

/// Returns true when a uniform block may hold a large array that the
/// backend binds as one buffer, on Metal and Vulkan.
bool get prismarineUniformArraysInBlocks {
  // PRISMARINE_UNIFORM_ARRAYS=0 answers as OpenGL ES does.
  final env = io.Platform.environment;
  if ((env['PRISMARINE_UNIFORM_ARRAYS'] ?? env['MCSM_UNIFORM_ARRAYS']) == '0') {
    return false;
  }
  if (io.Platform.isMacOS || io.Platform.isIOS) return true;
  final bits = prismarineEngineFeatures;
  return (bits & 1024) != 0 && prismarineBackend == 'vulkan';
}

/// Returns true when the engine draws from a first instance in one call.
/// Bit 512. Another engine binds the instance buffers again at the offset.
bool get prismarineFirstInstanceDraws => (prismarineEngineFeatures & 512) != 0;

/// Sets up to 16 [viewports] and a scissor rect for each for the later
/// draws on [pass]. A primitive goes to the viewport that its vertex stage
/// writes to a `flat out uint viewport_index` output. On Vulkan the
/// stage also writes `gl_ViewportIndex`. An empty list goes back to one
/// viewport. Returns false where the engine or backend has no viewport
/// arrays. The caller then draws tile by tile.
bool prismarineSetViewports(
  RenderPass pass,
  List<Viewport> viewports, {
  List<Scissor>? scissors,
}) {
  if (!prismarineViewportArrays || viewports.length > 16) return false;
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
  return _prismarineSetViewports(pass, v, s, n);
}

@Native<Bool Function(Pointer<Void>, Handle, Handle, Int)>(
  symbol: 'InternalFlutterGpu_RenderPass_PrismarineSetViewports',
)
external bool _prismarineSetViewports(
  RenderPass pass,
  Float32List viewports,
  Int32List scissors,
  int count,
);
