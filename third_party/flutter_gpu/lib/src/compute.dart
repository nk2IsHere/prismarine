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

/// A shader's storage buffer or storage image, by name: a storage buffer by
/// its block's type name (`buffer Lights { … } lights;` is `Lights`), a
/// storage image by its variable name. Resolved once, until the shader is
/// reloaded.
base class StorageSlot {
  StorageSlot._(this.shader, this.name, this._image);

  final Shader shader;
  final String name;
  final bool _image;
  int _index = -2;

  int get _resolved => _index != -2
      ? _index
      : (_index = _image
            ? _resolveStorageImage(shader, name)
            : _resolveStorageBuffer(shader, name));
}

extension McsmShaderStorage on Shader {
  StorageSlot getStorageBufferSlot(String name) =>
      StorageSlot._(this, name, false);

  StorageSlot getStorageImageSlot(String name) =>
      StorageSlot._(this, name, true);
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

  @Native<Bool Function(Pointer<Void>, Int, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_ComputePass_McsmBindStorageImage',
  )
  external bool _bindStorageImage(int index, Texture texture);

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
