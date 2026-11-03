// ignore_for_file: public_member_api_docs

part of flutter_gpu;

// mcsm G9: S2's additions on the mcsm9 engine (Metal and Vulkan): storage
// buffers in render passes, compute pipelines and compute passes with
// storage buffers and images (third_party/flutter_engine patch 0019 and
// on).

/// Whether the running engine and backend have S2's additions: layered
/// textures, the added formats and 2x MSAA, storage buffers and compute.
bool get mcsmEngineSupportsS2 =>
    _mcsmEngineS2 && (_mcsmFeaturesNative() & 2048) != 0;

@Native<Int64 Function()>(symbol: 'InternalFlutterGpu_McsmFeatures')
external int _mcsmFeaturesNative();

/// The border colours Metal and Vulkan both offer.
enum McsmBorderColor { transparentBlack, opaqueBlack, opaqueWhite }

/// A whole sampler state, as Direct3D 11's (Metal and Vulkan): the depth
/// address mode, a comparison function (for `sampler2DShadow` and kin), the
/// border colour [SamplerAddressMode.clampToBorder] reads, LOD clamps and a
/// LOD bias (Vulkan only: Metal has no sampler bias).
base class McsmSampler extends SamplerOptions {
  McsmSampler({
    super.minFilter,
    super.magFilter,
    super.mipFilter,
    super.widthAddressMode,
    super.heightAddressMode,
    super.maxAnisotropy,
    this.depthAddressMode = SamplerAddressMode.clampToEdge,
    this.compare,
    this.borderColor = McsmBorderColor.transparentBlack,
    this.minLod = 0,
    this.maxLod = 1000,
    this.lodBias = 0,
  });

  SamplerAddressMode depthAddressMode;
  CompareFunction? compare;
  McsmBorderColor borderColor;
  double minLod;
  double maxLod;
  double lodBias;

  /// The packed fields `McsmSamplerFromPacked` (engine) reads.
  int get _packed =>
      minFilter.index |
      magFilter.index << 4 |
      mipFilter.index << 8 |
      widthAddressMode.index << 12 |
      heightAddressMode.index << 16 |
      depthAddressMode.index << 20 |
      (maxAnisotropy.clamp(1, 255)) << 24 |
      (compare == null ? 0 : compare!.index + 1) << 32 |
      borderColor.index << 36;
}

void _mcsmBindTextureSampler(
  RenderPass pass,
  UniformSlot slot,
  Texture texture,
  McsmSampler sampler,
) {
  final index = slot._resolvedTextureIndex;
  if (index < 0 ||
      !_renderPassBindTextureSampler(
        pass,
        slot.shader,
        index,
        texture,
        sampler._packed,
        sampler.minLod,
        sampler.maxLod,
        sampler.lodBias,
      )) {
    throw Exception('Failed to bind texture ${slot.uniformName}');
  }
  // The G5 memo no longer holds what this slot has.
  final bound = slot.shader._mcsmBound;
  if (2 * index + 1 < bound.length) {
    bound[2 * index] = null;
    bound[2 * index + 1] = null;
  }
}

/// A shader's storage buffer or storage image, by name: a storage buffer by
/// its block's type name (`buffer Lights { … } lights;` is `Lights`), a
/// storage image by its variable name. Resolved once, until the shader is
/// reloaded.
base class StorageSlot {
  StorageSlot._(this.shader, this.name, this._kind);

  final Shader shader;
  final String name;

  /// 0 a storage buffer, 1 a storage image, 2 a texel buffer, 3 a texture
  /// and 4 a sampler declared apart (the engine's kinds).
  final int _kind;
  bool get _image => _kind == 1;
  int _index = -2;

  int get _resolved => _index != -2
      ? _index
      : (_index = switch (_kind) {
          0 => _resolveStorageBuffer(shader, name),
          1 => _resolveStorageImage(shader, name),
          _ => _resolveBinding(shader, _kind, name),
        });
}

extension McsmShaderStorage on Shader {
  StorageSlot getStorageBufferSlot(String name) => StorageSlot._(this, name, 0);

  StorageSlot getStorageImageSlot(String name) => StorageSlot._(this, name, 1);

  /// A texel buffer (`samplerBuffer`, `imageBuffer`) by its variable name.
  StorageSlot getTexelBufferSlot(String name) => StorageSlot._(this, name, 2);

  /// A texture declared apart from its sampler (`texture2D` and kin).
  StorageSlot getSeparateTextureSlot(String name) =>
      StorageSlot._(this, name, 3);

  /// A sampler declared apart (`sampler`, `samplerShadow`).
  StorageSlot getSeparateSamplerSlot(String name) =>
      StorageSlot._(this, name, 4);
}

McsmSampler _asMcsmSampler(SamplerOptions s) => s is McsmSampler
    ? s
    : McsmSampler(
        minFilter: s.minFilter,
        magFilter: s.magFilter,
        mipFilter: s.mipFilter,
        widthAddressMode: s.widthAddressMode,
        heightAddressMode: s.heightAddressMode,
        maxAnisotropy: s.maxAnisotropy,
      );

extension McsmRenderPassBindings on RenderPass {
  /// Binds a buffer range read (or written, for an `imageBuffer`) as texels
  /// of [format] (Metal texture buffers, Vulkan texel buffers).
  void bindTexelBuffer(StorageSlot slot, BufferView view, PixelFormat format) {
    final index = slot._resolved;
    if (slot._kind != 2 ||
        index < 0 ||
        !_renderPassBindTexelBuffer(
          this,
          slot.shader,
          index,
          view.buffer,
          view.offsetInBytes,
          view.lengthInBytes,
          format.index,
        )) {
      throw Exception('Failed to bind texel buffer ${slot.name}');
    }
  }

  void bindSeparateTexture(StorageSlot slot, Texture texture) {
    final index = slot._resolved;
    if (slot._kind != 3 ||
        index < 0 ||
        !_renderPassBindSeparateTexture(this, slot.shader, index, texture)) {
      throw Exception('Failed to bind texture ${slot.name}');
    }
  }

  void bindSeparateSampler(StorageSlot slot, SamplerOptions sampler) {
    final s = _asMcsmSampler(sampler);
    final index = slot._resolved;
    if (slot._kind != 4 ||
        index < 0 ||
        !_renderPassBindSeparateSampler(
          this,
          slot.shader,
          index,
          s._packed,
          s.minLod,
          s.maxLod,
          s.lodBias,
        )) {
      throw Exception('Failed to bind sampler ${slot.name}');
    }
  }
}

extension McsmRenderPassStorage on RenderPass {
  /// Binds a storage buffer for this pass's following draws (until
  /// [RenderPass.clearBindings]); draw lists don't record it.
  void bindStorageBuffer(StorageSlot slot, BufferView view) {
    final index = slot._resolved;
    if (index < 0 ||
        !_renderPassBindStorageBuffer(
          this,
          slot.shader,
          index,
          view.buffer,
          view.offsetInBytes,
          view.lengthInBytes,
        )) {
      throw Exception('Failed to bind storage buffer ${slot.name}');
    }
  }
}

extension McsmRenderPassIndirect on RenderPass {
  /// A draw whose counts the GPU reads from [args] at draw time: indexed, 5
  /// uint32s (index count, instance count, first index, base vertex, first
  /// instance), else 4 (vertex count, instance count, first vertex, first
  /// instance), as Direct3D 11, Metal and Vulkan lay them out. Draw lists
  /// don't record it.
  void drawIndirect(BufferView args, {bool indexed = false}) {
    if (!_renderPassDrawIndirect(
      this,
      args.buffer,
      args.offsetInBytes,
      indexed,
    )) {
      throw Exception('Indirect draw failed');
    }
  }
}

extension McsmCommandBufferCopies on CommandBuffer {
  /// Copies a region of [source]'s mip level and slice (a 3D texture's depth
  /// slice) to [destination]'s, which may be another level or slice of the
  /// same texture; same format. Not on views.
  void copyTextureRegion(
    Texture source,
    Texture destination, {
    required int x,
    required int y,
    required int width,
    required int height,
    int destinationX = 0,
    int destinationY = 0,
    int sourceMipLevel = 0,
    int sourceSlice = 0,
    int destinationMipLevel = 0,
    int destinationSlice = 0,
  }) {
    final error = _copyTextureToTexture(
      this,
      source,
      destination,
      x,
      y,
      width,
      height,
      destinationX,
      destinationY,
      sourceMipLevel,
      sourceSlice,
      destinationMipLevel,
      destinationSlice,
    );
    if (error != null) throw Exception(error);
  }

  /// Copies a region of [source]'s mip level and slice into [destination]
  /// at [destinationOffset], rows tightly packed.
  void copyTextureRegionToBuffer(
    Texture source,
    DeviceBuffer destination, {
    required int x,
    required int y,
    required int width,
    required int height,
    int mipLevel = 0,
    int slice = 0,
    int destinationOffset = 0,
  }) {
    final error = _copyTextureToBuffer(
      this,
      source,
      x,
      y,
      width,
      height,
      mipLevel,
      slice,
      destination,
      destinationOffset,
    );
    if (error != null) throw Exception(error);
  }

  /// Fills [texture]'s mip levels from its base level (every layer of an
  /// array or cube), as the backend's blit does.
  void generateMipmaps(Texture texture) {
    final error = _generateMipmap(this, texture);
    if (error != null) throw Exception(error);
  }
}

extension McsmGpuContextCompute on GpuContext {
  /// A compute pipeline from a compute shader of a shader bundle.
  ComputePipeline createComputePipeline(Shader shader) =>
      ComputePipeline._(this, shader);
}

extension McsmCommandBufferCompute on CommandBuffer {
  /// A compute pass, encoded in turn with this command buffer's other passes.
  ComputePass createComputePass() => ComputePass._(this);
}

base class ComputePipeline extends NativeFieldWrapperClass1 {
  ComputePipeline._(GpuContext gpuContext, this.shader) {
    final String? error = _initialize(gpuContext, shader);
    if (error != null) {
      throw Exception(error);
    }
  }

  final Shader shader;

  @Native<Handle Function(Handle, Pointer<Void>, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePipeline_McsmInitialize',
  )
  external String? _initialize(GpuContext gpuContext, Shader shader);
}

/// Binds a pipeline's resources and dispatches workgroups. Bind every
/// resource again after each [dispatch]. Dispatches may overlap: put a
/// [barrier] between one that writes and one that reads.
base class ComputePass extends NativeFieldWrapperClass1 {
  ComputePass._(CommandBuffer commandBuffer) {
    _initialize();
    final String? error = _begin(commandBuffer);
    if (error != null) {
      throw Exception(error);
    }
  }

  void bindPipeline(ComputePipeline pipeline) {
    if (!_bindPipeline(pipeline)) {
      throw Exception('Failed to bind compute pipeline');
    }
  }

  void bindUniform(UniformSlot slot, BufferView view) {
    final index = slot._resolvedStructIndex;
    if (index < 0 ||
        !_bindUniform(
          index,
          view.buffer,
          view.offsetInBytes,
          view.lengthInBytes,
        )) {
      throw Exception('Failed to bind uniform ${slot.uniformName}');
    }
  }

  void bindStorageBuffer(StorageSlot slot, BufferView view) {
    final index = slot._resolved;
    if (slot._image ||
        index < 0 ||
        !_bindStorageBuffer(
          index,
          view.buffer,
          view.offsetInBytes,
          view.lengthInBytes,
        )) {
      throw Exception('Failed to bind storage buffer ${slot.name}');
    }
  }

  void bindTexture(
    UniformSlot slot,
    Texture texture, {
    SamplerOptions? sampler,
  }) {
    final s = sampler ?? SamplerOptions();
    final index = slot._resolvedTextureIndex;
    if (s is McsmSampler) {
      if (index < 0 ||
          !_bindTextureSampler(
            index,
            texture,
            s._packed,
            s.minLod,
            s.maxLod,
            s.lodBias,
          )) {
        throw Exception('Failed to bind texture ${slot.uniformName}');
      }
      return;
    }
    if (index < 0 ||
        !_bindTexture(
          index,
          texture,
          s.minFilter.index,
          s.magFilter.index,
          s.mipFilter.index,
          s.widthAddressMode.index,
          s.heightAddressMode.index,
        )) {
      throw Exception('Failed to bind texture ${slot.uniformName}');
    }
  }

  /// Binds a texture made with `enableShaderWriteUsage` as a storage image.
  void bindStorageImage(StorageSlot slot, Texture texture) {
    final index = slot._resolved;
    if (!slot._image || index < 0 || !_bindStorageImage(index, texture)) {
      throw Exception('Failed to bind storage image ${slot.name}');
    }
  }

  void bindTexelBuffer(StorageSlot slot, BufferView view, PixelFormat format) {
    final index = slot._resolved;
    if (slot._kind != 2 ||
        index < 0 ||
        !_bindTexelBuffer(
          index,
          view.buffer,
          view.offsetInBytes,
          view.lengthInBytes,
          format.index,
        )) {
      throw Exception('Failed to bind texel buffer ${slot.name}');
    }
  }

  void bindSeparateTexture(StorageSlot slot, Texture texture) {
    final index = slot._resolved;
    if (slot._kind != 3 || index < 0 || !_bindSeparateTexture(index, texture)) {
      throw Exception('Failed to bind texture ${slot.name}');
    }
  }

  void bindSeparateSampler(StorageSlot slot, SamplerOptions sampler) {
    final s = _asMcsmSampler(sampler);
    final index = slot._resolved;
    if (slot._kind != 4 ||
        index < 0 ||
        !_bindSeparateSampler(
          index,
          s._packed,
          s.minLod,
          s.maxLod,
          s.lodBias,
        )) {
      throw Exception('Failed to bind sampler ${slot.name}');
    }
  }

  /// Runs `x · y · z` workgroups of the pipeline's shader.
  void dispatch(int x, [int y = 1, int z = 1]) {
    if (!_dispatch(x, y, z)) {
      throw Exception('Compute dispatch failed');
    }
  }

  /// Runs the workgroup counts the GPU reads from [args] (three uint32s).
  void dispatchIndirect(BufferView args) {
    if (!_dispatchIndirect(args.buffer, args.offsetInBytes)) {
      throw Exception('Indirect compute dispatch failed');
    }
  }

  /// Orders earlier dispatches' writes before later dispatches' reads.
  void barrier() => _barrier();

  @Native<Void Function(Handle)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmInitialize',
  )
  external void _initialize();

  @Native<Handle Function(Pointer<Void>, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBegin',
  )
  external String? _begin(CommandBuffer commandBuffer);

  @Native<Bool Function(Pointer<Void>, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindPipeline',
  )
  external bool _bindPipeline(ComputePipeline pipeline);

  @Native<Bool Function(Pointer<Void>, Int, Pointer<Void>, Int, Int)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindUniform',
  )
  external bool _bindUniform(
    int index,
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  );

  @Native<Bool Function(Pointer<Void>, Int, Pointer<Void>, Int, Int)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindStorageBuffer',
  )
  external bool _bindStorageBuffer(
    int index,
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  );

  @Native<
    Bool Function(Pointer<Void>, Int, Pointer<Void>, Int, Int, Int, Int, Int)
  >(symbol: 'InternalFlutterGpu_ComputePass_McsmBindTexture')
  external bool _bindTexture(
    int index,
    Texture texture,
    int minFilter,
    int magFilter,
    int mipFilter,
    int widthAddressMode,
    int heightAddressMode,
  );

  @Native<
    Bool Function(
      Pointer<Void>,
      Int,
      Pointer<Void>,
      Int64,
      Double,
      Double,
      Double,
    )
  >(symbol: 'InternalFlutterGpu_ComputePass_McsmBindTextureSampler')
  external bool _bindTextureSampler(
    int index,
    Texture texture,
    int packed,
    double minLod,
    double maxLod,
    double lodBias,
  );

  @Native<Bool Function(Pointer<Void>, Int, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindStorageImage',
  )
  external bool _bindStorageImage(int index, Texture texture);

  @Native<Bool Function(Pointer<Void>, Int, Pointer<Void>, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindTexelBuffer',
  )
  external bool _bindTexelBuffer(
    int index,
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
    int format,
  );

  @Native<Bool Function(Pointer<Void>, Int, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindSeparateTexture',
  )
  external bool _bindSeparateTexture(int index, Texture texture);

  @Native<Bool Function(Pointer<Void>, Int, Int64, Double, Double, Double)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindSeparateSampler',
  )
  external bool _bindSeparateSampler(
    int index,
    int packed,
    double minLod,
    double maxLod,
    double lodBias,
  );

  @Native<Bool Function(Pointer<Void>, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmDispatch',
  )
  external bool _dispatch(int x, int y, int z);

  @Native<Bool Function(Pointer<Void>, Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmDispatchIndirect',
  )
  external bool _dispatchIndirect(DeviceBuffer args, int offsetInBytes);

  @Native<Void Function(Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBarrier',
  )
  external void _barrier();
}

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
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindStorageBuffer')
external bool _renderPassBindStorageBuffer(
  RenderPass pass,
  Shader shader,
  int index,
  DeviceBuffer buffer,
  int offsetInBytes,
  int lengthInBytes,
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
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindTextureSampler')
external bool _renderPassBindTextureSampler(
  RenderPass pass,
  Shader shader,
  int index,
  Texture texture,
  int packed,
  double minLod,
  double maxLod,
  double lodBias,
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
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindTexelBuffer')
external bool _renderPassBindTexelBuffer(
  RenderPass pass,
  Shader shader,
  int index,
  DeviceBuffer buffer,
  int offsetInBytes,
  int lengthInBytes,
  int format,
);

@Native<Bool Function(Pointer<Void>, Pointer<Void>, Int, Pointer<Void>)>(
  symbol: 'InternalFlutterGpu_RenderPass_McsmBindSeparateTexture',
)
external bool _renderPassBindSeparateTexture(
  RenderPass pass,
  Shader shader,
  int index,
  Texture texture,
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
>(symbol: 'InternalFlutterGpu_RenderPass_McsmBindSeparateSampler')
external bool _renderPassBindSeparateSampler(
  RenderPass pass,
  Shader shader,
  int index,
  int packed,
  double minLod,
  double maxLod,
  double lodBias,
);
