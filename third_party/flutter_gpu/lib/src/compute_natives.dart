// The engine calls behind compute.dart's binds, copies and dispatches (mcsm
// G9-G11).
part of flutter_gpu;

@Native<Int Function(Pointer<Void>, Handle)>(
  symbol: 'InternalFlutterGpu_Shader_McsmResolveStorageBuffer',
)
external int _resolveStorageBuffer(Shader shader, String name);

@Native<Int Function(Pointer<Void>, Handle)>(
  symbol: 'InternalFlutterGpu_Shader_McsmResolveStorageImage',
)
external int _resolveStorageImage(Shader shader, String name);

@Native<
  Bool Function(Pointer<Void>, Pointer<Void>, Int, Pointer<Void>, Int, Int)
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindStorageBuffer', isLeaf: true)
external bool _renderPassBindStorageBufferP(
  Pointer<Void> pass,
  Pointer<Void> shader,
  int index,
  Pointer<Void> buffer,
  int offsetInBytes,
  int lengthInBytes,
);
bool _renderPassBindStorageBuffer(
  RenderPass pass,
  Shader shader,
  int index,
  DeviceBuffer buffer,
  int offsetInBytes,
  int lengthInBytes,
) => _renderPassBindStorageBufferP(
  pass._mcsmSelf,
  shader._mcsmSelf,
  index,
  buffer._mcsmSelf,
  offsetInBytes,
  lengthInBytes,
);

// mcsm10: whether the engine answers an indirect draw as a leaf call.
final bool _mcsmIndirectLeaf = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_RenderPass_McsmDrawIndirectCached',
);

@Native<Int Function(Pointer<Void>, Pointer<Void>, Int, Bool)>(
  symbol: 'InternalFlutterGpu_RenderPass_McsmDrawIndirectCached',
  isLeaf: true,
)
external int _renderPassDrawIndirectCachedP(
  Pointer<Void> pass,
  Pointer<Void> args,
  int offsetInBytes,
  bool indexed,
);
int _renderPassDrawIndirectCached(
  RenderPass pass,
  DeviceBuffer args,
  int offsetInBytes,
  bool indexed,
) => _renderPassDrawIndirectCachedP(
  pass._mcsmSelf,
  args._mcsmSelf,
  offsetInBytes,
  indexed,
);

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Int, Bool)>(
  symbol: 'InternalFlutterGpu_RenderPass_McsmDrawIndirect',
)
external bool _renderPassDrawIndirect(
  RenderPass pass,
  DeviceBuffer args,
  int offsetInBytes,
  bool indexed,
);

@Native<
  Bool Function(
    Pointer<Void>,
    Pointer<Void>,
    Int,
    Pointer<Void>,
    Int64,
    Double,
    Double,
    Double,
  )
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindTextureSampler', isLeaf: true)
external bool _renderPassBindTextureSamplerP(
  Pointer<Void> pass,
  Pointer<Void> shader,
  int index,
  Pointer<Void> texture,
  int packed,
  double minLod,
  double maxLod,
  double lodBias,
);
bool _renderPassBindTextureSampler(
  RenderPass pass,
  Shader shader,
  int index,
  Texture texture,
  int packed,
  double minLod,
  double maxLod,
  double lodBias,
) => _renderPassBindTextureSamplerP(
  pass._mcsmSelf,
  shader._mcsmSelf,
  index,
  texture._mcsmSelf,
  packed,
  minLod,
  maxLod,
  lodBias,
);

@Native<
  Handle Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
  )
>(symbol: 'InternalFlutterGpu_CommandBuffer_McsmCopyTextureToTexture')
external String? _copyTextureToTexture(
  CommandBuffer commandBuffer,
  Texture source,
  Texture destination,
  int x,
  int y,
  int width,
  int height,
  int destinationX,
  int destinationY,
  int sourceMip,
  int sourceSlice,
  int destinationMip,
  int destinationSlice,
);

@Native<
  Handle Function(
    Pointer<Void>,
    Pointer<Void>,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Pointer<Void>,
    Int,
  )
>(symbol: 'InternalFlutterGpu_CommandBuffer_McsmCopyTextureToBuffer')
external String? _copyTextureToBuffer(
  CommandBuffer commandBuffer,
  Texture source,
  int x,
  int y,
  int width,
  int height,
  int mip,
  int slice,
  DeviceBuffer destination,
  int destinationOffset,
);

@Native<Handle Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_CommandBuffer_McsmGenerateMipmap',
)
external String? _generateMipmap(CommandBuffer commandBuffer, Texture texture);

@Native<Int Function(Pointer<Void>, Int, Handle)>(
  symbol: 'InternalFlutterGpu_Shader_McsmResolveBinding',
)
external int _resolveBinding(Shader shader, int kind, String name);

@Native<
  Bool Function(Pointer<Void>, Pointer<Void>, Int, Pointer<Void>, Int, Int, Int)
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindTexelBuffer', isLeaf: true)
external bool _renderPassBindTexelBufferP(
  Pointer<Void> pass,
  Pointer<Void> shader,
  int index,
  Pointer<Void> buffer,
  int offsetInBytes,
  int lengthInBytes,
  int format,
);
bool _renderPassBindTexelBuffer(
  RenderPass pass,
  Shader shader,
  int index,
  DeviceBuffer buffer,
  int offsetInBytes,
  int lengthInBytes,
  int format,
) => _renderPassBindTexelBufferP(
  pass._mcsmSelf,
  shader._mcsmSelf,
  index,
  buffer._mcsmSelf,
  offsetInBytes,
  lengthInBytes,
  format,
);

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Int, Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_RenderPass_McsmBindSeparateTexture',
  isLeaf: true,
)
external bool _renderPassBindSeparateTextureP(
  Pointer<Void> pass,
  Pointer<Void> shader,
  int index,
  Pointer<Void> texture,
);
bool _renderPassBindSeparateTexture(
  RenderPass pass,
  Shader shader,
  int index,
  Texture texture,
) => _renderPassBindSeparateTextureP(
  pass._mcsmSelf,
  shader._mcsmSelf,
  index,
  texture._mcsmSelf,
);

@Native<
  Bool Function(
    Pointer<Void>,
    Pointer<Void>,
    Int,
    Int64,
    Double,
    Double,
    Double,
  )
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindSeparateSampler', isLeaf: true)
external bool _renderPassBindSeparateSamplerP(
  Pointer<Void> pass,
  Pointer<Void> shader,
  int index,
  int packed,
  double minLod,
  double maxLod,
  double lodBias,
);
bool _renderPassBindSeparateSampler(
  RenderPass pass,
  Shader shader,
  int index,
  int packed,
  double minLod,
  double maxLod,
  double lodBias,
) => _renderPassBindSeparateSamplerP(
  pass._mcsmSelf,
  shader._mcsmSelf,
  index,
  packed,
  minLod,
  maxLod,
  lodBias,
);
