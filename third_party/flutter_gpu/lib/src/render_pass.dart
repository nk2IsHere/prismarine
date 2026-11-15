// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

part of flutter_gpu;

base class ColorAttachment {
  ColorAttachment({
    this.loadAction = LoadAction.clear,
    this.storeAction = StoreAction.store,
    vm.Vector4? clearValue = null,
    required this.texture,
    this.resolveTexture = null,
    this.mipLevel = 0,
    this.slice = 0,
  }) : clearValue = clearValue ?? vm.Vector4.zero();

  LoadAction loadAction;
  StoreAction storeAction;
  vm.Vector4 clearValue;

  Texture texture;
  Texture? resolveTexture;

  /// The mip level of [texture] to render into. Must be in the range
  /// `[0, texture.mipLevelCount)`.
  ///
  /// Rendering into a non-zero mip level is supported on Metal and Vulkan but
  /// not currently on the GLES backend. See
  /// [GpuContext.doesSupportFramebufferRenderMipmap].
  int mipLevel;

  /// The slice of [texture] to render into. For cubemap textures this selects
  /// the face in the order `+X, -X, +Y, -Y, +Z, -Z`. Must be in the range
  /// `[0, texture.sliceCount)` (always 0 for non-cubemap textures).
  int slice;

  void _validate() {
    if (resolveTexture != null) {
      if (resolveTexture!.format != texture.format) {
        throw Exception(
          "ColorAttachment MSAA resolve texture must have the same format as the texture",
        );
      }
      if (resolveTexture!.width != texture.width ||
          resolveTexture!.height != texture.height) {
        throw Exception(
          "ColorAttachment MSAA resolve texture must have the same dimensions as the texture",
        );
      }
      if (resolveTexture!.sampleCount != 1) {
        throw Exception(
          "ColorAttachment MSAA resolve texture must have a sample count of 1",
        );
      }
      if (texture.sampleCount <= 1) {
        throw Exception(
          "ColorAttachment must have a sample count greater than 1 when a MSAA resolve texture is set",
        );
      }
      if (storeAction != StoreAction.multisampleResolve &&
          storeAction != StoreAction.storeAndMultisampleResolve) {
        throw Exception(
          "ColorAttachment StoreAction must be multisampleResolve or storeAndMultisampleResolve when a resolve texture is set",
        );
      }
      if (resolveTexture!.storageMode == StorageMode.deviceTransient) {
        throw Exception(
          "ColorAttachment MSAA resolve texture must not have a storage mode of deviceTransient",
        );
      }
    }
  }
}

base class DepthStencilAttachment {
  DepthStencilAttachment({
    this.depthLoadAction = LoadAction.clear,
    this.depthStoreAction = StoreAction.dontCare,
    this.depthClearValue = 0.0,
    this.stencilLoadAction = LoadAction.clear,
    this.stencilStoreAction = StoreAction.dontCare,
    this.stencilClearValue = 0,
    required this.texture,
    this.mipLevel = 0,
    this.slice = 0,
  });

  LoadAction depthLoadAction;
  StoreAction depthStoreAction;
  double depthClearValue;

  LoadAction stencilLoadAction;
  StoreAction stencilStoreAction;
  int stencilClearValue;

  Texture texture;

  /// The mip level of [texture] to render into. Must match the mip level of
  /// the color attachments so all attachments share the same size. See
  /// [ColorAttachment.mipLevel].
  int mipLevel;

  /// The slice of [texture] to render into. See [ColorAttachment.slice].
  int slice;

  void _validate() {
    if (texture.storageMode == StorageMode.deviceTransient) {
      if (depthLoadAction == LoadAction.load) {
        throw Exception(
          "DepthStencilAttachment depthLoadAction must not be load when the texture has a storage mode of deviceTransient",
        );
      }
      if (stencilLoadAction == LoadAction.load) {
        throw Exception(
          "DepthStencilAttachment stencilLoadAction must not be load when the texture has a storage mode of deviceTransient",
        );
      }
    }
  }
}

base class StencilConfig {
  StencilConfig({
    this.compareFunction = CompareFunction.always,
    this.stencilFailureOperation = StencilOperation.keep,
    this.depthFailureOperation = StencilOperation.keep,
    this.depthStencilPassOperation = StencilOperation.keep,
    this.readMask = 0xFFFFFFFF,
    this.writeMask = 0xFFFFFFFF,
  });

  CompareFunction compareFunction;
  StencilOperation stencilFailureOperation;
  StencilOperation depthFailureOperation;
  StencilOperation depthStencilPassOperation;
  int readMask;
  int writeMask;
}

// Note: When modifying this enum, also update
//       `InternalFlutterGpu_RenderPass_SetStencilConfig` in `gpu/render_pass.cc`.
enum StencilFace { both, front, back }

base class ColorBlendEquation {
  ColorBlendEquation({
    this.colorBlendOperation = BlendOperation.add,
    this.sourceColorBlendFactor = BlendFactor.one,
    this.destinationColorBlendFactor = BlendFactor.oneMinusSourceAlpha,
    this.alphaBlendOperation = BlendOperation.add,
    this.sourceAlphaBlendFactor = BlendFactor.one,
    this.destinationAlphaBlendFactor = BlendFactor.oneMinusSourceAlpha,
  });

  BlendOperation colorBlendOperation;
  BlendFactor sourceColorBlendFactor;
  BlendFactor destinationColorBlendFactor;

  BlendOperation alphaBlendOperation;
  BlendFactor sourceAlphaBlendFactor;
  BlendFactor destinationAlphaBlendFactor;
}

base class SamplerOptions {
  SamplerOptions({
    this.minFilter = MinMagFilter.nearest,
    this.magFilter = MinMagFilter.nearest,
    this.mipFilter = MipFilter.nearest,
    this.widthAddressMode = SamplerAddressMode.clampToEdge,
    this.heightAddressMode = SamplerAddressMode.clampToEdge,
    this.maxAnisotropy = 1,
  });

  MinMagFilter minFilter;
  MinMagFilter magFilter;
  MipFilter mipFilter;
  SamplerAddressMode widthAddressMode;
  SamplerAddressMode heightAddressMode;

  /// The maximum anisotropy clamp used when sampling. The default value of 1
  /// disables anisotropic filtering.
  ///
  /// When greater than 1, [minFilter], [magFilter], and [mipFilter] must all
  /// be linear. Values beyond [GpuContext.maxSamplerAnisotropy] are clamped
  /// to it, and a maximum of 1 means the device does not support anisotropic
  /// filtering.
  ///
  /// Anisotropic filtering samples across the mip chain, so populate mip
  /// levels (via [Texture.overwrite] or by rendering into them) to get the
  /// full quality benefit.
  int maxAnisotropy;
}

base class Scissor {
  Scissor({this.x = 0, this.y = 0, this.width = 0, this.height = 0});

  int x, y, width, height;

  void _validate() {
    if (x < 0 || y < 0 || width < 0 || height < 0) {
      throw Exception(
        "Invalid values for scissor. All values should be positive.",
      );
    }
  }
}

base class DepthRange {
  DepthRange({this.zNear = 0.0, this.zFar = 1.0});

  double zNear;
  double zFar;
}

base class Viewport {
  Viewport({
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    DepthRange? depthRange = null,
  }) : this.depthRange = depthRange ?? DepthRange();

  int x, y, width, height;
  DepthRange depthRange;

  void _validate() {
    if (x < 0 || y < 0 || width < 0 || height < 0) {
      throw Exception(
        "Invalid values for viewport. All values should be positive.",
      );
    }
  }
}

base class RenderTarget {
  const RenderTarget({
    this.colorAttachments = const <ColorAttachment>[],
    this.depthStencilAttachment,
  });

  RenderTarget.singleColor(
    ColorAttachment colorAttachment, {
    DepthStencilAttachment? depthStencilAttachment,
  }) : this(
         colorAttachments: [colorAttachment],
         depthStencilAttachment: depthStencilAttachment,
       );

  _validate() {
    for (final color in colorAttachments) {
      color._validate();
    }
    if (depthStencilAttachment != null) {
      depthStencilAttachment!._validate();
    }
  }

  /// Validates attachment mip levels, slices, and sizes. Out-of-range
  /// subresources and mismatched sizes are undefined behavior in the engine,
  /// and the engine-side checks are compiled out in release builds, so this
  /// runs unconditionally.
  void _validateAttachments() {
    // The size of the first attachment, against which the rest are checked.
    // Each attachment renders into its mip level, clamped to a minimum of 1x1.
    int? width;
    int? height;
    void accumulate(Texture texture, int mipLevel) {
      final int w = texture.width >> mipLevel;
      final int h = texture.height >> mipLevel;
      final int mipWidth = w < 1 ? 1 : w;
      final int mipHeight = h < 1 ? 1 : h;
      if (width == null) {
        width = mipWidth;
        height = mipHeight;
      } else if (width != mipWidth || height != mipHeight) {
        throw Exception(
          "All render target attachments must render into the same size. "
          "Check that all color and depth-stencil attachments use matching "
          "texture sizes and mip levels.",
        );
      }
    }

    for (final color in colorAttachments) {
      _validateAttachmentSubresource(
        color.texture,
        color.mipLevel,
        color.slice,
        "ColorAttachment",
      );
      if (color.resolveTexture != null) {
        _validateAttachmentSubresource(
          color.resolveTexture!,
          color.mipLevel,
          color.slice,
          "ColorAttachment resolve texture",
        );
      }
      accumulate(color.texture, color.mipLevel);
    }

    final ds = depthStencilAttachment;
    if (ds != null) {
      _validateAttachmentSubresource(
        ds.texture,
        ds.mipLevel,
        ds.slice,
        "DepthStencilAttachment",
      );
      accumulate(ds.texture, ds.mipLevel);
    }
  }

  final List<ColorAttachment> colorAttachments;
  final DepthStencilAttachment? depthStencilAttachment;
}

void _validateAttachmentSubresource(
  Texture texture,
  int mipLevel,
  int slice,
  String label,
) {
  if (mipLevel < 0 || mipLevel >= texture.mipLevelCount) {
    throw Exception(
      "$label mipLevel ($mipLevel) must be in the range [0, ${texture.mipLevelCount - 1}] for this texture",
    );
  }
  // mcsm G9: -1 attaches every layer of an array or cube texture (the vertex
  // stage picks each primitive's layer; the mcsm9 engine on Metal and
  // Vulkan).
  if (slice == -1 && texture.sliceCount > 1 && _mcsmEngineS2) {
    return;
  }
  if (slice < 0 || slice >= texture.sliceCount) {
    throw Exception(
      "$label slice ($slice) must be in the range [0, ${texture.sliceCount - 1}] for textures of type ${texture.textureType}",
    );
  }
}

base class RenderPass extends NativeFieldWrapperClass1 {
  /// mcsm G11: this object's native pointer, read once: the leaf natives
  /// take it as a pointer, where passing the object made a Pointer per call.
  late final Pointer<Void> _mcsmSelf = _mcsmPointerOf(this);

  /// The maximum number of vertex buffer slots that can be bound to a single
  /// draw. Matches `flutter::gpu::RenderPass::kMaxVertexBufferSlots` on the
  /// native side, which in turn matches `impeller::kMaxVertexBuffers`; keep
  /// them in sync.
  static const int _kMaxVertexBufferSlots = 16;

  /// Bitmask of slots that have been bound via [bindVertexBuffer] since the
  /// most recent [clearBindings] (or since this RenderPass was created).
  /// Bit `i` is set when slot `i` has been bound.
  int _boundVertexSlotsMask = 0;

  /// Highest slot index that has been bound, or -1 if no slot has been
  /// bound. Tracked so [draw] can detect sparse bindings without scanning
  /// the entire bitmask.
  int _maxBoundVertexSlot = -1;

  // mcsm G5: each shader's texture slots as bound since the last
  // [clearBindings] (texture, sampler; by the slot's resolved index). The
  // pass keeps a binding until cleared, so binding the same texture and
  // sampler object again changes nothing and is skipped. mcsm G6: the memo
  // lives on the Shader (pass, clear number), not in an identity map.
  int _clearEpoch = 0;

  // mcsm G6: pipeline state as last set on this pass (-1: not yet), so
  // setting the same value again doesn't cross into the engine.
  int _cullMode = -1;
  int _windingOrder = -1;
  int _primitiveType = -1;
  int _polygonMode = -1;

  // mcsm G7: the view bound at each vertex buffer slot (for draws from a
  // first instance on engines without RenderPass_McsmDrawInstanced). mcsm
  // G13: made on the first vertex bind (a full-screen pass binds none).
  List<BufferView?>? _vertexViews;

  /// Creates a new RenderPass.
  RenderPass._(
    GpuContext gpuContext,
    CommandBuffer commandBuffer,
    RenderTarget renderTarget,
  ) {
    renderTarget._validateAttachments();
    assert(() {
      renderTarget._validate();
      return true;
    }());

    _initialize();
    String? error;
    for (final (index, color) in renderTarget.colorAttachments.indexed) {
      error = _setColorAttachmentP(
        _mcsmSelf,
        gpuContext._mcsmSelf,
        index,
        color.loadAction.index,
        color.storeAction.index,
        color.clearValue.r,
        color.clearValue.g,
        color.clearValue.b,
        color.clearValue.a,
        color.texture._mcsmSelf,
        color.resolveTexture,
        color.mipLevel,
        color.slice,
      );
      if (error != null) {
        throw Exception(error);
      }
    }
    if (renderTarget.depthStencilAttachment != null) {
      final ds = renderTarget.depthStencilAttachment!;
      error = _setDepthStencilAttachmentP(
        _mcsmSelf,
        ds.depthLoadAction.index,
        ds.depthStoreAction.index,
        ds.depthClearValue,
        ds.stencilLoadAction.index,
        ds.stencilStoreAction.index,
        ds.stencilClearValue,
        ds.texture._mcsmSelf,
        ds.mipLevel,
        ds.slice,
      );
      if (error != null) {
        throw Exception(error);
      }
    }
    error = _beginP(_mcsmSelf, commandBuffer._mcsmSelf);
    if (error != null) {
      throw Exception(error);
    }
  }

  // mcsm G6: the pipeline bound last (binding it again changes nothing).
  RenderPipeline? _pipeline;

  void bindPipeline(RenderPipeline pipeline) {
    if (identical(pipeline, _pipeline)) return;
    _pipeline = pipeline;
    _bindPipeline(pipeline);
  }

  /// Binds [bufferView] as the vertex buffer at the given [slot].
  ///
  /// [slot] selects which vertex-buffer binding the data appears at,
  /// matching the corresponding `VertexBuffer` declared on the active
  /// pipeline's `VertexLayout`. The default of 0 matches the default
  /// layout declared by a shader bundle, which is what every single-buffer
  /// call site expects. To bind multiple structure-of-arrays vertex
  /// buffers, call this method once per slot.
  ///
  /// The number of vertices to draw is passed separately, to [draw].
  ///
  /// Sparse bindings are not supported. Every slot in `[0, highestBound]`
  /// must have been bound before [draw] or [drawIndexed] is called,
  /// otherwise they throw a [StateError] naming the unbound slots. Slots
  /// can be bound in any order.
  ///
  /// [slot] must be in `[0, 16)` (the current Flutter GPU limit for vertex
  /// buffer bindings). Some devices may also impose a lower limit on the
  /// total number of vertex attributes used by a single pipeline.
  void bindVertexBuffer(BufferView bufferView, {int slot = 0}) {
    if (slot < 0 || slot >= _kMaxVertexBufferSlots) {
      throw RangeError.range(
        slot,
        0,
        _kMaxVertexBufferSlots - 1,
        'slot',
        'bindVertexBuffer slot must be in [0, $_kMaxVertexBufferSlots)',
      );
    }
    _boundVertexSlotsMask |= 1 << slot;
    if (slot > _maxBoundVertexSlot) {
      _maxBoundVertexSlot = slot;
    }
    (_vertexViews ??= List<BufferView?>.filled(
      _kMaxVertexBufferSlots,
      null,
    ))[slot] = bufferView;
    bufferView.buffer._bindAsVertexBuffer(
      this,
      bufferView.offsetInBytes,
      bufferView.lengthInBytes,
      slot,
    );
  }

  /// Binds [bufferView] as the index buffer.
  ///
  /// [indexType] is the width of each index. The number of indices to draw
  /// is passed separately, to [drawIndexed].
  void bindIndexBuffer(BufferView bufferView, IndexType indexType) {
    bufferView.buffer._bindAsIndexBuffer(
      this,
      bufferView.offsetInBytes,
      bufferView.lengthInBytes,
      indexType,
    );
  }

  void bindUniform(UniformSlot slot, BufferView bufferView) {
    bool success = bufferView.buffer._bindAsUniform(
      this,
      slot,
      bufferView.offsetInBytes,
      bufferView.lengthInBytes,
    );
    if (!success) {
      throw Exception("Failed to bind uniform");
    }
  }

  void bindTexture(
    UniformSlot slot,
    Texture texture, {
    SamplerOptions? sampler,
  }) {
    if (sampler == null) {
      sampler = SamplerOptions();
    }
    // mcsm G9: a whole sampler state.
    if (sampler is McsmSampler) {
      _mcsmBindTextureSampler(this, slot, texture, sampler);
      return;
    }

    assert(() {
      if (texture.storageMode == StorageMode.deviceTransient) {
        throw Exception(
          "Textures with StorageMode.deviceTransient cannot be bound to a RenderPass",
        );
      }
      return true;
    }());

    if (sampler.maxAnisotropy < 1) {
      throw Exception("SamplerOptions.maxAnisotropy must be at least 1");
    }
    if (sampler.maxAnisotropy > 1 &&
        (sampler.minFilter != MinMagFilter.linear ||
            sampler.magFilter != MinMagFilter.linear ||
            sampler.mipFilter != MipFilter.linear)) {
      throw Exception(
        "When SamplerOptions.maxAnisotropy is greater than 1, minFilter, "
        "magFilter, and mipFilter must all be linear",
      );
    }

    if (_mcsmEngineE3) {
      // mcsm G2: by the resolved index, as a leaf call.
      final index = slot._resolvedTextureIndex;
      // mcsm G5: the slot holds this texture and sampler already.
      final shader = slot.shader;
      final List<Object?> bound = shader._mcsmBound;
      if (!identical(shader._mcsmBoundPass, this) ||
          shader._mcsmBoundEpoch != _clearEpoch) {
        shader._mcsmBoundPass = this;
        shader._mcsmBoundEpoch = _clearEpoch;
        bound.length = 0;
      } else if (index >= 0 &&
          2 * index + 1 < bound.length &&
          identical(bound[2 * index], texture) &&
          identical(bound[2 * index + 1], sampler)) {
        return;
      }
      if (index < 0 ||
          !_bindTextureIndexed(
            slot.shader,
            index,
            texture,
            sampler.minFilter.index,
            sampler.magFilter.index,
            sampler.mipFilter.index,
            sampler.widthAddressMode.index,
            sampler.heightAddressMode.index,
            sampler.maxAnisotropy,
          )) {
        throw Exception("Failed to bind texture");
      }
      if (bound.length < 2 * index + 2) {
        bound.length = 2 * index + 2;
      }
      bound[2 * index] = texture;
      bound[2 * index + 1] = sampler;
      return;
    }
    bool success = _bindTexture(
      slot.shader,
      slot.uniformName,
      texture,
      sampler.minFilter.index,
      sampler.magFilter.index,
      sampler.mipFilter.index,
      sampler.widthAddressMode.index,
      sampler.heightAddressMode.index,
      sampler.maxAnisotropy,
    );
    if (!success) {
      throw Exception("Failed to bind texture");
    }
  }

  void clearBindings() {
    _clearBindings();
    _boundVertexSlotsMask = 0;
    _maxBoundVertexSlot = -1;
    _clearEpoch++;
  }

  void setColorBlendEnable(bool enable, {int colorAttachmentIndex = 0}) {
    _setColorBlendEnable(colorAttachmentIndex, enable);
  }

  void setColorBlendEquation(
    ColorBlendEquation equation, {
    int colorAttachmentIndex = 0,
  }) {
    _setColorBlendEquation(
      colorAttachmentIndex,
      equation.colorBlendOperation.index,
      equation.sourceColorBlendFactor.index,
      equation.destinationColorBlendFactor.index,
      equation.alphaBlendOperation.index,
      equation.sourceAlphaBlendFactor.index,
      equation.destinationAlphaBlendFactor.index,
    );
  }

  void setDepthWriteEnable(bool enable) {
    _setDepthWriteEnable(enable);
  }

  void setViewport(Viewport viewport) {
    assert(() {
      viewport._validate();
      return true;
    }());
    _setViewport(
      viewport.x,
      viewport.y,
      viewport.width,
      viewport.height,
      viewport.depthRange.zNear,
      viewport.depthRange.zFar,
    );
  }

  void setDepthCompareOperation(CompareFunction compareFunction) {
    _setDepthCompareOperation(compareFunction.index);
  }

  void setStencilReference(int referenceValue) {
    if (referenceValue < 0 || referenceValue > 0xFFFFFFFF) {
      throw Exception(
        "The stencil reference value must be in the range [0, 2^32 - 1]",
      );
    }
    _setStencilReference(referenceValue);
  }

  void setStencilConfig(
    StencilConfig configuration, {
    StencilFace targetFace = StencilFace.both,
  }) {
    if (configuration.readMask < 0 || configuration.readMask > 0xFFFFFFFF) {
      throw Exception("The stencil read mask must be in the range [0, 255]");
    }
    if (configuration.writeMask < 0 || configuration.writeMask > 0xFFFFFFFF) {
      throw Exception("The stencil write mask must be in the range [0, 255]");
    }
    _setStencilConfig(
      configuration.compareFunction.index,
      configuration.stencilFailureOperation.index,
      configuration.depthFailureOperation.index,
      configuration.depthStencilPassOperation.index,
      configuration.readMask,
      configuration.writeMask,
      targetFace.index,
    );
  }

  void setScissor(Scissor scissor) {
    assert(() {
      scissor._validate();
      return true;
    }());
    _setScissor(scissor.x, scissor.y, scissor.width, scissor.height);
  }

  // mcsm G6: an unchanged value doesn't cross into the engine.
  void setCullMode(CullMode cullMode) {
    final v = cullMode.index;
    if (v == _cullMode) return;
    _cullMode = v;
    _setCullMode(v);
  }

  void setPolygonMode(PolygonMode polygonMode) {
    final v = polygonMode.index;
    if (v == _polygonMode) return;
    _polygonMode = v;
    _setPolygonMode(v);
  }

  void setPrimitiveType(PrimitiveType primitiveType) {
    final v = primitiveType.index;
    if (v == _primitiveType) return;
    _primitiveType = v;
    _setPrimitiveType(v);
  }

  void setWindingOrder(WindingOrder windingOrder) {
    final v = windingOrder.index;
    if (v == _windingOrder) return;
    _windingOrder = v;
    _setWindingOrder(v);
  }

  /// Appends a non-indexed draw of [vertexCount] vertices.
  ///
  /// The vertices are read from the vertex buffers previously bound with
  /// [bindVertexBuffer]. Buffers whose [VertexBuffer.stepMode] is
  /// [VertexStepMode.vertex] advance once per vertex. Buffers whose
  /// [VertexBuffer.stepMode] is [VertexStepMode.instance] advance once per
  /// instance.
  ///
  /// Set [instanceCount] greater than 1 to repeat the same vertex range
  /// multiple times while reading a new element from each instance-rate vertex
  /// buffer for each instance. A [vertexCount] or [instanceCount] of 0 is
  /// valid and records no drawing work.
  ///
  /// If the bound pipeline does not use any instance-rate vertex buffers, each
  /// instance receives the same vertex buffer data. This is valid, but every
  /// instance will produce the same geometry unless the shader varies its output
  /// another way.
  ///
  /// mcsm G7: [firstInstance] starts every instance-rate vertex buffer at that
  /// instance, as if its view were bound [firstInstance] elements further on
  /// (one instance buffer, many draws). The shader's instance index still
  /// counts from 0 on every backend. The views must hold
  /// `firstInstance + instanceCount` elements.
  void draw(int vertexCount, {int instanceCount = 1, int firstInstance = 0}) {
    RangeError.checkNotNegative(vertexCount, 'vertexCount');
    RangeError.checkNotNegative(instanceCount, 'instanceCount');
    RangeError.checkNotNegative(firstInstance, 'firstInstance');
    if (vertexCount == 0 || instanceCount == 0) {
      return;
    }
    _validateVertexBindings();
    if (firstInstance > 0) {
      _drawFromInstance(vertexCount, instanceCount, firstInstance, false);
      return;
    }
    if (_mcsmEngineE3) {
      // mcsm G3: a leaf draw when the pipeline is cached on this pass.
      final drawn = _drawCached(vertexCount, instanceCount, false);
      if (drawn == 1) return;
      if (drawn == 0) throw Exception("Failed to append draw");
    }
    if (!_draw(vertexCount, instanceCount)) {
      throw Exception("Failed to append draw");
    }
  }

  /// Appends an indexed draw of [indexCount] indices.
  ///
  /// Indices are read from the index buffer previously bound with
  /// [bindIndexBuffer]. Vertex data is read from the vertex buffers previously
  /// bound with [bindVertexBuffer]. Buffers whose [VertexBuffer.stepMode] is
  /// [VertexStepMode.vertex] advance once per vertex selected by the index
  /// buffer. Buffers whose [VertexBuffer.stepMode] is [VertexStepMode.instance]
  /// advance once per instance.
  ///
  /// Set [instanceCount] greater than 1 to repeat the same indexed geometry
  /// multiple times while reading a new element from each instance-rate vertex
  /// buffer for each instance. An [indexCount] or [instanceCount] of 0 is valid
  /// and records no drawing work.
  ///
  /// If the bound pipeline does not use any instance-rate vertex buffers, each
  /// instance receives the same vertex and index buffer data. This is valid, but
  /// every instance will produce the same geometry unless the shader varies its
  /// output another way.
  ///
  /// mcsm G7: [firstInstance] as for [draw].
  void drawIndexed(
    int indexCount, {
    int instanceCount = 1,
    int firstInstance = 0,
  }) {
    RangeError.checkNotNegative(indexCount, 'indexCount');
    RangeError.checkNotNegative(instanceCount, 'instanceCount');
    RangeError.checkNotNegative(firstInstance, 'firstInstance');
    if (indexCount == 0 || instanceCount == 0) {
      return;
    }
    _validateVertexBindings();
    if (firstInstance > 0) {
      _drawFromInstance(indexCount, instanceCount, firstInstance, true);
      return;
    }
    if (_mcsmEngineE3) {
      // mcsm G3: a leaf draw when the pipeline is cached on this pass.
      final drawn = _drawCached(indexCount, instanceCount, true);
      if (drawn == 1) return;
      if (drawn == 0) throw Exception("Failed to append drawIndexed");
    }
    if (!_drawIndexed(indexCount, instanceCount)) {
      throw Exception("Failed to append drawIndexed");
    }
  }

  // mcsm G7: a draw from a first instance. The mcsm7 engine offsets the
  // instance-rate buffers itself (leaf); elsewhere, or before the pass has
  // made the pipeline, they are bound again at the offset for this draw.
  void _drawFromInstance(
    int count,
    int instanceCount,
    int first,
    bool indexed,
  ) {
    if (_mcsmDrawInstanced) {
      final drawn = _mcsmDrawInstancedNative(
        count,
        instanceCount,
        first,
        indexed,
      );
      if (drawn == 1) return;
      if (drawn == 0) {
        throw Exception('Failed to append a draw from instance $first');
      }
    }
    final buffers = _pipeline?._vertexLayout?.buffers ?? const <VertexBuffer>[];
    final moved = <int, BufferView>{};
    for (var slot = 0; slot < buffers.length; slot++) {
      final layout = buffers[slot];
      final view = _vertexViews?[slot];
      if (layout.stepMode != VertexStepMode.instance || view == null) continue;
      final skip = first * layout.strideInBytes;
      if (skip + instanceCount * layout.strideInBytes > view.lengthInBytes) {
        throw RangeError(
          'instances $first..${first + instanceCount} run past the view at '
          'vertex buffer slot $slot',
        );
      }
      moved[slot] = view;
      bindVertexBuffer(
        BufferView(
          view.buffer,
          offsetInBytes: view.offsetInBytes + skip,
          lengthInBytes: view.lengthInBytes - skip,
        ),
        slot: slot,
      );
    }
    try {
      if (indexed) {
        drawIndexed(count, instanceCount: instanceCount);
      } else {
        draw(count, instanceCount: instanceCount);
      }
    } finally {
      for (final MapEntry(key: slot, value: view) in moved.entries) {
        bindVertexBuffer(view, slot: slot);
      }
    }
  }

  @Native<Int Function(Pointer<Void>, Int, Int, Int, Bool)>(
    symbol: 'InternalFlutterGpu_RenderPass_McsmDrawInstanced',
    isLeaf: true,
  )
  external static int _mcsmDrawInstancedNativeP(
    Pointer<Void> self,
    int elementCount,
    int instanceCount,
    int firstInstance,
    bool indexed,
  );
  int _mcsmDrawInstancedNative(
    int elementCount,
    int instanceCount,
    int firstInstance,
    bool indexed,
  ) => _mcsmDrawInstancedNativeP(
    _mcsmSelf,
    elementCount,
    instanceCount,
    firstInstance,
    indexed,
  );

  /// Throws a [StateError] when the bound vertex buffer slots are sparse,
  /// naming the slots in `[0, highestBound]` that were left unbound.
  void _validateVertexBindings() {
    if (_maxBoundVertexSlot >= 0) {
      final int expectedMask = (1 << (_maxBoundVertexSlot + 1)) - 1;
      if (_boundVertexSlotsMask != expectedMask) {
        final List<int> missing = <int>[
          for (int i = 0; i <= _maxBoundVertexSlot; i++)
            if ((_boundVertexSlotsMask & (1 << i)) == 0) i,
        ];
        throw StateError(
          'draw called with sparse vertex buffer bindings: slot(s) '
          '${missing.join(', ')} were not bound but slot $_maxBoundVertexSlot '
          'was. Bind every slot in [0, $_maxBoundVertexSlot] before drawing.',
        );
      }
    }
  }

  /// Wrap with native counterpart.
  @Native<Void Function(Handle)>(
    symbol: 'InternalFlutterGpu_RenderPass_Initialize',
  )
  external void _initialize();

  @Native<
    Handle Function(
      Pointer<Void>,
      Pointer<Void>,
      Int,
      Int,
      Int,
      Float,
      Float,
      Float,
      Float,
      Pointer<Void>,
      Handle,
      Int,
      Int,
    )
  >(symbol: 'InternalFlutterGpu_RenderPass_SetColorAttachment')
  // mcsm G12: the wrappers by their kept pointers (a Pointer per wrapper
  // argument per call otherwise); the caller holds every one through it.
  external static String? _setColorAttachmentP(
    Pointer<Void> self,
    Pointer<Void> context,
    int colorAttachmentIndex,
    int loadAction,
    int storeAction,
    double clearColorR,
    double clearColorG,
    double clearColorB,
    double clearColorA,
    Pointer<Void> texture,
    Texture? resolveTexture,
    int mipLevel,
    int slice,
  );

  @Native<
    Handle Function(
      Pointer<Void>,
      Int,
      Int,
      Float,
      Int,
      Int,
      Int,
      Pointer<Void>,
      Int,
      Int,
    )
  >(symbol: 'InternalFlutterGpu_RenderPass_SetDepthStencilAttachment')
  external static String? _setDepthStencilAttachmentP(
    // mcsm G12
    Pointer<Void> self,
    int depthLoadAction,
    int depthStoreAction,
    double depthClearValue,
    int stencilLoadAction,
    int stencilStoreAction,
    int stencilClearValue,
    Pointer<Void> texture,
    int mipLevel,
    int slice,
  );

  @Native<Handle Function(Pointer<Void>, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_RenderPass_Begin',
  )
  external static String? _beginP(
    // mcsm G12
    Pointer<Void> self,
    Pointer<Void> commandBuffer,
  );

  @Native<Void Function(Pointer<Void>, Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_RenderPass_BindPipeline',
    isLeaf: true, // mcsm G6
  )
  external static void _bindPipelineP(
    Pointer<Void> self,
    Pointer<Void> pipeline,
  );
  void _bindPipeline(RenderPipeline pipeline) =>
      _bindPipelineP(_mcsmSelf, pipeline._mcsmSelf);

  @Native<Void Function(Pointer<Void>, Pointer<Void>, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_BindVertexBufferDevice',
    isLeaf: true, // mcsm G3
  )
  external static void _bindVertexBufferDeviceP(
    Pointer<Void> self,
    Pointer<Void> buffer,
    int offsetInBytes,
    int lengthInBytes,
    int slot,
  );
  void _bindVertexBufferDevice(
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
    int slot,
  ) => _bindVertexBufferDeviceP(
    _mcsmSelf,
    buffer._mcsmSelf,
    offsetInBytes,
    lengthInBytes,
    slot,
  );

  @Native<Void Function(Pointer<Void>, Pointer<Void>, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_BindIndexBufferDevice',
    isLeaf: true, // mcsm G3
  )
  external static void _bindIndexBufferDeviceP(
    Pointer<Void> self,
    Pointer<Void> buffer,
    int offsetInBytes,
    int lengthInBytes,
    int indexType,
  );
  void _bindIndexBufferDevice(
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
    int indexType,
  ) => _bindIndexBufferDeviceP(
    _mcsmSelf,
    buffer._mcsmSelf,
    offsetInBytes,
    lengthInBytes,
    indexType,
  );

  @Native<
    Bool Function(Pointer<Void>, Pointer<Void>, Handle, Pointer<Void>, Int, Int)
  >(symbol: 'InternalFlutterGpu_RenderPass_BindUniformDevice')
  external bool _bindUniformDevice(
    Shader shader,
    String uniformName,
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  );

  // mcsm G2
  @Native<
    Bool Function(Pointer<Void>, Pointer<Void>, Int, Pointer<Void>, Int, Int)
  >(symbol: 'InternalFlutterGpu_RenderPass_BindUniformIndexed', isLeaf: true)
  external static bool _bindUniformIndexedP(
    Pointer<Void> self,
    Pointer<Void> shader,
    int uniformIndex,
    Pointer<Void> buffer,
    int offsetInBytes,
    int lengthInBytes,
  );
  bool _bindUniformIndexed(
    Shader shader,
    int uniformIndex,
    DeviceBuffer buffer,
    int offsetInBytes,
    int lengthInBytes,
  ) => _bindUniformIndexedP(
    _mcsmSelf,
    shader._mcsmSelf,
    uniformIndex,
    buffer._mcsmSelf,
    offsetInBytes,
    lengthInBytes,
  );

  // mcsm G2
  @Native<
    Bool Function(
      Pointer<Void>,
      Pointer<Void>,
      Int,
      Pointer<Void>,
      Int,
      Int,
      Int,
      Int,
      Int,
      Int,
    )
  >(symbol: 'InternalFlutterGpu_RenderPass_BindTextureIndexed', isLeaf: true)
  external static bool _bindTextureIndexedP(
    Pointer<Void> self,
    Pointer<Void> shader,
    int textureIndex,
    Pointer<Void> texture,
    int minFilter,
    int magFilter,
    int mipFilter,
    int widthAddressMode,
    int heightAddressMode,
    int maxAnisotropy,
  );
  bool _bindTextureIndexed(
    Shader shader,
    int textureIndex,
    Texture texture,
    int minFilter,
    int magFilter,
    int mipFilter,
    int widthAddressMode,
    int heightAddressMode,
    int maxAnisotropy,
  ) => _bindTextureIndexedP(
    _mcsmSelf,
    shader._mcsmSelf,
    textureIndex,
    texture._mcsmSelf,
    minFilter,
    magFilter,
    mipFilter,
    widthAddressMode,
    heightAddressMode,
    maxAnisotropy,
  );

  // mcsm G3: 1 drawn, 0 failed, 2 pipeline not cached (nothing done).
  @Native<Int Function(Pointer<Void>, Int, Int, Bool)>(
    symbol: 'InternalFlutterGpu_RenderPass_DrawCached',
    isLeaf: true,
  )
  external static int _drawCachedP(
    Pointer<Void> self,
    int elementCount,
    int instanceCount,
    bool indexed,
  );
  int _drawCached(int elementCount, int instanceCount, bool indexed) =>
      _drawCachedP(_mcsmSelf, elementCount, instanceCount, indexed);

  @Native<Void Function(Pointer<Void>, Int, Int, Int, Int, Float, Float)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetViewport',
    isLeaf: true, // mcsm G6
  )
  external static void _setViewportP(
    Pointer<Void> self,
    int x,
    int y,
    int width,
    int height,
    double depthRangeZNear,
    double depthRangeZFar,
  );
  void _setViewport(
    int x,
    int y,
    int width,
    int height,
    double depthRangeZNear,
    double depthRangeZFar,
  ) => _setViewportP(
    _mcsmSelf,
    x,
    y,
    width,
    height,
    depthRangeZNear,
    depthRangeZFar,
  );

  @Native<
    Bool Function(
      Pointer<Void>,
      Pointer<Void>,
      Handle,
      Pointer<Void>,
      Int,
      Int,
      Int,
      Int,
      Int,
      Int,
    )
  >(symbol: 'InternalFlutterGpu_RenderPass_BindTexture')
  external bool _bindTexture(
    Shader shader,
    String uniformName,
    Texture texture,
    int minFilter,
    int magFilter,
    int mipFilter,
    int widthAddressMode,
    int heightAddressMode,
    int maxAnisotropy,
  );

  @Native<Void Function(Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_RenderPass_ClearBindings',
    isLeaf: true, // mcsm G3
  )
  external static void _clearBindingsP(Pointer<Void> self);
  void _clearBindings() => _clearBindingsP(_mcsmSelf);

  @Native<Void Function(Pointer<Void>, Int, Bool)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetColorBlendEnable',
    isLeaf: true, // mcsm G6
  )
  external static void _setColorBlendEnableP(
    Pointer<Void> self,
    int colorAttachmentIndex,
    bool enable,
  );
  void _setColorBlendEnable(int colorAttachmentIndex, bool enable) =>
      _setColorBlendEnableP(_mcsmSelf, colorAttachmentIndex, enable);

  @Native<Void Function(Pointer<Void>, Int, Int, Int, Int, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetColorBlendEquation',
    isLeaf: true, // mcsm G6
  )
  external static void _setColorBlendEquationP(
    Pointer<Void> self,
    int colorAttachmentIndex,
    int colorBlendOperation,
    int sourceColorBlendFactor,
    int destinationColorBlendFactor,
    int alphaBlendOperation,
    int sourceAlphaBlendFactor,
    int destinationAlphaBlendFactor,
  );
  void _setColorBlendEquation(
    int colorAttachmentIndex,
    int colorBlendOperation,
    int sourceColorBlendFactor,
    int destinationColorBlendFactor,
    int alphaBlendOperation,
    int sourceAlphaBlendFactor,
    int destinationAlphaBlendFactor,
  ) => _setColorBlendEquationP(
    _mcsmSelf,
    colorAttachmentIndex,
    colorBlendOperation,
    sourceColorBlendFactor,
    destinationColorBlendFactor,
    alphaBlendOperation,
    sourceAlphaBlendFactor,
    destinationAlphaBlendFactor,
  );

  @Native<Void Function(Pointer<Void>, Bool)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetDepthWriteEnable',
    isLeaf: true, // mcsm G6
  )
  external static void _setDepthWriteEnableP(Pointer<Void> self, bool enable);
  void _setDepthWriteEnable(bool enable) =>
      _setDepthWriteEnableP(_mcsmSelf, enable);

  @Native<Void Function(Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetDepthCompareOperation',
    isLeaf: true, // mcsm G6
  )
  external static void _setDepthCompareOperationP(
    Pointer<Void> self,
    int compareOperation,
  );
  void _setDepthCompareOperation(int compareOperation) =>
      _setDepthCompareOperationP(_mcsmSelf, compareOperation);

  @Native<Void Function(Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetStencilReference',
    isLeaf: true, // mcsm G6
  )
  external static void _setStencilReferenceP(
    Pointer<Void> self,
    int referenceValue,
  );
  void _setStencilReference(int referenceValue) =>
      _setStencilReferenceP(_mcsmSelf, referenceValue);

  @Native<Void Function(Pointer<Void>, Int, Int, Int, Int, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetStencilConfig',
    isLeaf: true, // mcsm G6
  )
  external static void _setStencilConfigP(
    Pointer<Void> self,
    int compareFunction,
    int stencilFailureOperation,
    int depthFailureOperation,
    int depthStencilPassOperation,
    int readMask,
    int writeMask,
    int target_face,
  );
  void _setStencilConfig(
    int compareFunction,
    int stencilFailureOperation,
    int depthFailureOperation,
    int depthStencilPassOperation,
    int readMask,
    int writeMask,
    int target_face,
  ) => _setStencilConfigP(
    _mcsmSelf,
    compareFunction,
    stencilFailureOperation,
    depthFailureOperation,
    depthStencilPassOperation,
    readMask,
    writeMask,
    target_face,
  );

  @Native<Void Function(Pointer<Void>, Int, Int, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetScissor',
    isLeaf: true, // mcsm G6
  )
  external static void _setScissorP(
    Pointer<Void> self,
    int x,
    int y,
    int width,
    int height,
  );
  void _setScissor(int x, int y, int width, int height) =>
      _setScissorP(_mcsmSelf, x, y, width, height);

  @Native<Void Function(Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetCullMode',
    isLeaf: true, // mcsm G6
  )
  external static void _setCullModeP(Pointer<Void> self, int cullMode);
  void _setCullMode(int cullMode) => _setCullModeP(_mcsmSelf, cullMode);

  @Native<Void Function(Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetPrimitiveType',
    isLeaf: true, // mcsm G6
  )
  external static void _setPrimitiveTypeP(
    Pointer<Void> self,
    int primitiveType,
  );
  void _setPrimitiveType(int primitiveType) =>
      _setPrimitiveTypeP(_mcsmSelf, primitiveType);

  @Native<Void Function(Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetWindingOrder',
    isLeaf: true, // mcsm G6
  )
  external static void _setWindingOrderP(Pointer<Void> self, int windingOrder);
  void _setWindingOrder(int windingOrder) =>
      _setWindingOrderP(_mcsmSelf, windingOrder);

  @Native<Void Function(Pointer<Void>, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_SetPolygonMode',
    isLeaf: true, // mcsm G6
  )
  external static void _setPolygonModeP(Pointer<Void> self, int polygonMode);
  void _setPolygonMode(int polygonMode) =>
      _setPolygonModeP(_mcsmSelf, polygonMode);

  @Native<Bool Function(Pointer<Void>, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_Draw',
  )
  external bool _draw(int vertexCount, int instanceCount);

  @Native<Bool Function(Pointer<Void>, Int, Int)>(
    symbol: 'InternalFlutterGpu_RenderPass_DrawIndexed',
  )
  external bool _drawIndexed(int indexCount, int instanceCount);
}
