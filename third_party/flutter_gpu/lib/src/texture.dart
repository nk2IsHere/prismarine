// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

part of flutter_gpu;

base class Texture extends NativeFieldWrapperClass1 {
  bool _valid = false;
  get isValid {
    return _valid;
  }

  /// Returns the maximum number of mip levels Flutter GPU will allocate
  /// for a texture of the given [width] and [height].
  ///
  /// This currently uses `floor(log2(min(w, h)))` and clamps at 1. Note
  /// that this is one less than the canonical `floor(log2(max(w, h))) + 1`
  /// used by Vulkan and OpenGL, and uses the smaller dimension instead of
  /// the larger; Flutter GPU may eventually relax this (tracked in
  /// https://github.com/flutter/flutter/issues/186176). Users should treat
  /// this as the upper bound for the `mipLevelCount` argument to
  /// `GpuContext.createTexture` rather than as a fixed mathematical
  /// formula.
  static int fullMipCount(int width, int height) {
    if (width < 1 || height < 1) {
      return 1;
    }
    final int smallest = width < height ? width : height;
    final int count = smallest.bitLength - 1;
    return count > 0 ? count : 1;
  }

  /// Creates a new Texture.
  Texture._initialize(
    GpuContext gpuContext,
    this.storageMode,
    this.format,
    this.width,
    this.height,
    this.sampleCount,
    this.textureType,
    this.enableRenderTargetUsage,
    this.enableShaderReadUsage,
    this.enableShaderWriteUsage,
    this.mipLevelCount, {
    this.layers = 1,
    this.depth = 1,
  }) : _gpuContext = gpuContext,
       _viewParent = null {
    // mcsm G9: layered textures, the added formats and 2x MSAA go through
    // the mcsm9 engine's export.
    final bool mcsm9 =
        layers != 1 ||
        depth != 1 ||
        sampleCount == 2 ||
        textureType.index > TextureType.textureExternalOES.index ||
        format.index > PixelFormat.astc8x8HDR.index;
    if (sampleCount != 1 && sampleCount != 4 && !(mcsm9 && sampleCount == 2)) {
      throw Exception("Only a sample count of 1, 2 or 4 is supported");
    }
    if (mcsm9 && !_mcsmEngineS2) {
      throw Exception(
        'Layered textures, the S2 pixel formats and 2x MSAA need the mcsm9 '
        'engine',
      );
    }
    _valid = mcsm9
        ? _initializeLayered(
            gpuContext,
            storageMode.index,
            format.index,
            width,
            height,
            layers,
            depth,
            sampleCount,
            textureType.index,
            enableRenderTargetUsage,
            enableShaderReadUsage,
            enableShaderWriteUsage,
            mipLevelCount,
          )
        : _initialize(
            gpuContext,
            storageMode.index,
            format.index,
            width,
            height,
            sampleCount,
            textureType.index,
            enableRenderTargetUsage,
            enableShaderReadUsage,
            enableShaderWriteUsage,
            mipLevelCount,
          );
    if (!_valid) {
      // The engine logs the specific reason (for example, a compressed format
      // used with render target or shader write usage, which is sample-only).
      throw Exception('Texture creation failed');
    }
    // mcsm G4: live GPU memory by kind.
    GpuMemory._track(this, GpuMemory._textureKind(this), _bytes());
  }

  /// The bytes this texture's levels occupy (mcsm G4; an estimate: the
  /// driver's alignment and padding aren't counted).
  int _bytes() {
    var total = 0;
    final bw = format.blockWidth, bh = format.blockHeight;
    for (var l = 0; l < mipLevelCount; l++) {
      final w = (width >> l) < 1 ? 1 : width >> l;
      final h = (height >> l) < 1 ? 1 : height >> l;
      // mcsm G9: a 3D texture's depth halves per level too.
      final d = (depth >> l) < 1 ? 1 : depth >> l;
      total +=
          ((w + bw - 1) ~/ bw) *
          ((h + bh - 1) ~/ bh) *
          format.bytesPerBlock *
          d;
    }
    return total *
        sampleCount *
        (textureType == TextureType.textureCubeArray ? 6 * layers : layers);
  }

  Texture._surface(
    GpuContext gpuContext,
    PixelFormat format,
    int width,
    int height,
  ) : _gpuContext = gpuContext,
      storageMode = StorageMode.devicePrivate,
      format = format,
      width = width,
      height = height,
      sampleCount = 1,
      textureType = TextureType.texture2D,
      enableRenderTargetUsage = true,
      enableShaderReadUsage = true,
      enableShaderWriteUsage = false,
      mipLevelCount = 1,
      layers = 1,
      depth = 1,
      _viewParent = null;

  /// Wraps the GPU texture that backs [image] as a Flutter GPU [Texture],
  /// without copying any pixel data.
  ///
  /// The returned texture shares its storage with [image], so it stays valid
  /// for as long as either the returned texture or [image] is alive. It is
  /// intended for sampling (for example as a material texture) and reflects
  /// the usage of the underlying texture, so it is not guaranteed to be usable
  /// as a render pass attachment.
  ///
  /// [image] must be backed by a GPU texture. Use an image produced by the
  /// asynchronous `RepaintBoundary.toImage` (or `Picture.toImage`). An image
  /// from `toImageSync` rasterizes asynchronously and may not have a texture
  /// yet when this is called. Throws if [image] has no compatible texture.
  factory Texture.fromImage(GpuContext gpuContext, ui.Image image) {
    final Int32List info = _imageTextureInfo(gpuContext, image);
    if (info.length != 10) {
      throw Exception(
        'Texture.fromImage could not wrap the image because it is not backed '
        'by a compatible GPU texture. Use an image from the asynchronous '
        'RepaintBoundary.toImage rather than toImageSync.',
      );
    }
    return Texture._fromImage(gpuContext, image, info);
  }

  /// Builds the wrapper from the metadata returned by [_imageTextureInfo] and
  /// associates it with the image's backing texture. The field layout must
  /// match `InternalFlutterGpu_Texture_ImageTextureInfo` on the native side.
  Texture._fromImage(GpuContext gpuContext, ui.Image image, Int32List info)
    : _gpuContext = gpuContext,
      storageMode = StorageMode.values[info[0]],
      format = PixelFormat.values[info[1]],
      width = info[2],
      height = info[3],
      sampleCount = info[4],
      textureType = TextureType.values[info[5]],
      enableRenderTargetUsage = info[6] != 0,
      enableShaderReadUsage = info[7] != 0,
      enableShaderWriteUsage = info[8] != 0,
      mipLevelCount = info[9],
      layers = 1,
      depth = 1,
      _viewParent = null {
    _valid = _initializeFromImage(gpuContext, image);
    if (!_valid) {
      throw Exception("Texture.fromImage failed to wrap the image texture");
    }
  }

  /// mcsm G9: a view of [parent]'s mip levels and layers (see [makeView]).
  Texture._view(
    GpuContext gpuContext,
    Texture parent,
    this.textureType,
    int baseMipLevel,
    this.mipLevelCount,
    int baseLayer,
    int layerCount,
  ) : _gpuContext = gpuContext,
      layers = textureType == TextureType.textureCubeArray
          ? layerCount ~/ 6
          : (textureType == TextureType.textureCube ? 1 : layerCount),
      storageMode = parent.storageMode,
      format = parent.format,
      width = (parent.width >> baseMipLevel) < 1
          ? 1
          : parent.width >> baseMipLevel,
      height = (parent.height >> baseMipLevel) < 1
          ? 1
          : parent.height >> baseMipLevel,
      sampleCount = parent.sampleCount,
      enableRenderTargetUsage = parent.enableRenderTargetUsage,
      enableShaderReadUsage = parent.enableShaderReadUsage,
      enableShaderWriteUsage = parent.enableShaderWriteUsage,
      depth = 1,
      _viewParent = parent {
    _valid = _initializeView(
      gpuContext,
      parent,
      textureType.index,
      baseMipLevel,
      mipLevelCount,
      baseLayer,
      layerCount,
    );
    if (!_valid) {
      throw Exception('Texture view creation failed');
    }
  }

  /// mcsm G9: a texture that is mip levels `[baseMipLevel, baseMipLevel +
  /// mipLevelCount)` and layers `[baseLayer, baseLayer + layers)` of this one
  /// (Metal and Vulkan; not of a 3D texture). Sample, render into or write it
  /// as a storage image on its own: one level while sampling the level
  /// above, one layer of an array as a 2D target. A view shares this
  /// texture's memory; upload through this texture, not the view.
  /// [textureType] defaults to 2D for one layer, else a 2D array.
  Texture makeView({
    int baseMipLevel = 0,
    int mipLevelCount = 1,
    int baseLayer = 0,
    int layers = 1,
    TextureType? textureType,
  }) {
    if (!_mcsmEngineS2) {
      throw Exception('Texture views need the mcsm9 engine');
    }
    if (baseMipLevel < 0 ||
        mipLevelCount < 1 ||
        baseMipLevel + mipLevelCount > this.mipLevelCount ||
        baseLayer < 0 ||
        layers < 1 ||
        baseLayer + layers > sliceCount) {
      throw RangeError('The view must lie within the texture');
    }
    return Texture._view(
      _gpuContext,
      this,
      textureType ??
          (layers == 1 ? TextureType.texture2D : TextureType.texture2DArray),
      baseMipLevel,
      mipLevelCount,
      baseLayer,
      layers,
    );
  }

  /// mcsm G9: the texture a view was made of (null for a texture of its
  /// own); it keeps the parent's Dart wrapper alive too.
  final Texture? _viewParent;

  GpuContext _gpuContext;

  final StorageMode storageMode;
  final PixelFormat format;
  final int width;
  final int height;
  final int sampleCount;
  final TextureType textureType;

  /// Enable using this texture as a render pass attachment.
  final bool enableRenderTargetUsage;

  /// Enable reading or sampling from this texture in a shader.
  final bool enableShaderReadUsage;

  /// Enable writing to the texture in a shader.
  ///
  /// Note that this is distinct from [enableRenderTargetUsage].
  final bool enableShaderWriteUsage;

  /// The number of mip levels allocated for this texture.
  ///
  /// A value of 1 means no mip chain (only the base level). Larger values
  /// allocate additional levels with halved dimensions per step. Use
  /// [Texture.fullMipCount] to compute the maximum for a given size.
  final int mipLevelCount;

  /// mcsm G9: the layers of a [TextureType.texture2DArray] (1 otherwise).
  final int layers;

  /// mcsm G9: the depth of a [TextureType.texture3D] (1 otherwise).
  final int depth;

  /// The number of slices in this texture. Determined by [textureType]:
  /// 1 for 2D and external textures, 6 for cubemap textures, the layers of
  /// an array and the depth of a 3D texture (mcsm G9).
  int get sliceCount => switch (textureType) {
    TextureType.textureCube => 6,
    TextureType.texture2DArray => layers,
    TextureType.textureCubeArray => 6 * layers,
    TextureType.texture3D => depth,
    _ => 1,
  };

  /// Returns the width of the texture at [mipLevel], clamped at 1.
  int getMipLevelWidth(int mipLevel) {
    _validateMipLevel(mipLevel);
    final int mipWidth = width >> mipLevel;
    return mipWidth > 0 ? mipWidth : 1;
  }

  /// Returns the height of the texture at [mipLevel], clamped at 1.
  int getMipLevelHeight(int mipLevel) {
    _validateMipLevel(mipLevel);
    final int mipHeight = height >> mipLevel;
    return mipHeight > 0 ? mipHeight : 1;
  }

  /// Returns the size in bytes of the [mipLevel] mip level (one slice). Mip
  /// dimensions are clamped at 1, matching standard mip chain semantics. For
  /// block-compressed formats the dimensions are rounded up to whole blocks.
  int getMipLevelSizeInBytes(int mipLevel) {
    final int w = getMipLevelWidth(mipLevel);
    final int h = getMipLevelHeight(mipLevel);
    final int bw = format.blockWidth;
    final int bh = format.blockHeight;
    final int blocksWide = (w + bw - 1) ~/ bw;
    final int blocksHigh = (h + bh - 1) ~/ bh;
    return blocksWide * blocksHigh * format.bytesPerBlock;
  }

  /// Returns the size in bytes of the base mip level (one slice). Equivalent
  /// to `getMipLevelSizeInBytes(0)`.
  int getBaseMipLevelSizeInBytes() {
    return getMipLevelSizeInBytes(0);
  }

  /// Overwrites a mip level (and slice for cubemap textures) of this
  /// [Texture] with the contents of [sourceBytes].
  ///
  /// [mipLevel] selects which mip level to write to. Defaults to 0 (base
  /// level). Must be in the range `[0, mipLevelCount)`.
  ///
  /// [slice] selects which slice to write to for cubemap textures, where
  /// each face is a separate slice in the order
  /// `+X, -X, +Y, -Y, +Z, -Z`. Must be 0 for non-cubemap textures.
  ///
  /// The length of [sourceBytes] must exactly match the size returned by
  /// [getMipLevelSizeInBytes] for the requested [mipLevel]. For
  /// block-compressed formats, this is the number of whole-block-rounded
  /// blocks times the bytes per block.
  ///
  /// Throws an exception if the write fails due to an internal error or if
  /// any of the parameters are out of range.
  void overwrite(ByteData sourceBytes, {int mipLevel = 0, int slice = 0}) {
    if (_viewParent != null) {
      throw Exception('Upload through the texture a view was made of');
    }
    _validateMipLevelAndSlice(mipLevel, slice);
    final int expectedSize = getMipLevelSizeInBytes(mipLevel);
    if (sourceBytes.lengthInBytes != expectedSize) {
      throw Exception(
        'The length of sourceBytes (bytes: ${sourceBytes.lengthInBytes}) must exactly match the size of mip level $mipLevel (bytes: $expectedSize)',
      );
    }
    bool success = _overwrite(_gpuContext, sourceBytes, mipLevel, slice);
    if (!success) {
      throw Exception("Texture overwrite failed");
    }
  }

  void _validateMipLevel(int mipLevel) {
    if (mipLevel < 0 || mipLevel >= mipLevelCount) {
      throw Exception(
        'mipLevel ($mipLevel) must be in the range [0, ${mipLevelCount - 1}] for this texture',
      );
    }
  }

  void _validateMipLevelAndSlice(int mipLevel, int slice) {
    _validateMipLevel(mipLevel);
    final int slices = sliceCount;
    if (slice < 0 || slice >= slices) {
      throw Exception(
        'slice ($slice) must be in the range [0, ${slices - 1}] for textures of type $textureType',
      );
    }
  }

  ui.Image asImage() {
    if (!enableShaderReadUsage) {
      throw Exception(
        'Only shader readable Flutter GPU textures can be used as UI Images',
      );
    }
    return _asImage();
  }

  /// Wrap with native counterpart.
  @Native<
    Bool Function(
      Handle,
      Pointer<Void>,
      Int,
      Int,
      Int,
      Int,
      Int,
      Int,
      Bool,
      Bool,
      Bool,
      Int,
    )
  >(symbol: 'InternalFlutterGpu_Texture_Initialize')
  external bool _initialize(
    GpuContext gpuContext,
    int storageMode,
    int format,
    int width,
    int height,
    int sampleCount,
    int textureType,
    bool enableRenderTargetUsage,
    bool enableShaderReadUsage,
    bool enableShaderWriteUsage,
    int mipLevelCount,
  );

  /// mcsm G9: the mcsm9 engine's texture creation (layers and depth).
  @Native<
    Bool Function(
      Handle,
      Pointer<Void>,
      Int,
      Int,
      Int,
      Int,
      Int,
      Int,
      Int,
      Int,
      Bool,
      Bool,
      Bool,
      Int,
    )
  >(symbol: 'InternalFlutterGpu_Texture_McsmInitializeLayered')
  external bool _initializeLayered(
    GpuContext gpuContext,
    int storageMode,
    int format,
    int width,
    int height,
    int layers,
    int depth,
    int sampleCount,
    int textureType,
    bool enableRenderTargetUsage,
    bool enableShaderReadUsage,
    bool enableShaderWriteUsage,
    int mipLevelCount,
  );

  /// mcsm G9: Texture_McsmInitializeView.
  @Native<
    Bool Function(Handle, Pointer<Void>, Pointer<Void>, Int, Int, Int, Int, Int)
  >(symbol: 'InternalFlutterGpu_Texture_McsmInitializeView')
  external bool _initializeView(
    GpuContext gpuContext,
    Texture parent,
    int textureType,
    int baseMipLevel,
    int mipLevelCount,
    int baseLayer,
    int layers,
  );

  @Native<Bool Function(Pointer<Void>, Pointer<Void>, Handle, Int, Int)>(
    symbol: 'InternalFlutterGpu_Texture_Overwrite',
  )
  external bool _overwrite(
    GpuContext gpuContext,
    ByteData bytes,
    int mipLevel,
    int slice,
  );

  @Native<Handle Function(Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_Texture_AsImage',
  )
  external ui.Image _asImage();

  @Native<Handle Function(Pointer<Void>, Handle)>(
    symbol: 'InternalFlutterGpu_Texture_ImageTextureInfo',
  )
  external static Int32List _imageTextureInfo(
    GpuContext gpuContext,
    ui.Image image,
  );

  @Native<Bool Function(Handle, Pointer<Void>, Handle)>(
    symbol: 'InternalFlutterGpu_Texture_InitializeFromImage',
  )
  external bool _initializeFromImage(GpuContext gpuContext, ui.Image image);
}
