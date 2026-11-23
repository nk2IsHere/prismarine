part of 'release_9.dart';

// Texel buffers, storage texel buffers with atomics, storage image formats,
// the IEEE and invariance options of Metal, compute-written vertex and
// indirect buffers, draw parameters, clip distances, textures and samplers
// declared apart and a BC3 array.

gpu.BufferView _u32(_Kit kit, List<int> values) {
  final b = kit.ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(Uint32List.fromList(values)),
  );
  return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: values.length * 4);
}

Future<String?> _texelBuffers(_Kit kit) async {
  final lights = kit.floats([
    for (var i = 0; i < 8; i++) ...[i / 8, 0.5, 1 - i / 8, 1],
  ]);
  final indices = _u32(kit, [0, 0, 0, 5, 0, 0, 0, 0]);
  final out = kit.rgba8(16);
  await kit.draw(out, 'TexelFragment', (p, f) {
    p.bindTexelBuffer(
      f.getTexelBufferSlot('lights'),
      lights,
      gpu.PixelFormat.r32g32b32a32Float,
    );
    p.bindTexelBuffer(
      f.getTexelBufferSlot('indices'),
      indices,
      gpu.PixelFormat.r32UInt,
    );
  });
  final c = await centre(out);
  // lights[5] = (0.625, 0.5, 0.375, 1).
  if (!near(c, [159, 128, 96, 255])) return 'read: got $c';

  // 64 invocations add to counter 0 and exchange counter 1 (atomics).
  final shader = kit.shader('AtomicsCompute');
  final counters = _u32(kit, [0, 0, 0, 0]);
  final values = kit.floats(List<double>.filled(64 * 4, 0));
  final cb = kit.ctx.createCommandBuffer();
  cb.createComputePass()
    ..bindPipeline(kit.ctx.createComputePipeline(shader))
    ..bindUniform(shader.getUniformSlot('Params'), _u32(kit, [1, 77, 0, 0]))
    ..bindStorageBuffer(
      shader.getStorageBufferSlot('Scratch'),
      _u32(kit, List<int>.filled(64, 0)),
    )
    ..bindTexelBuffer(
      shader.getTexelBufferSlot('counters'),
      counters,
      gpu.PixelFormat.r32UInt,
    )
    ..bindTexelBuffer(
      shader.getTexelBufferSlot('values'),
      values,
      gpu.PixelFormat.r32g32b32a32Float,
    )
    ..dispatch(1);
  final read = kit.rgba8(16);
  final f = kit.shader('CountersFragment');
  cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: read, clearValue: Vector4(0, 0, 0, 1)),
      ),
    )
    ..bindPipeline(kit.ctx.createRenderPipeline(kit.shader('QuadVertex'), f))
    ..bindVertexBuffer(kit.quad)
    ..bindTexelBuffer(
      f.getTexelBufferSlot('counters'),
      counters,
      gpu.PixelFormat.r32UInt,
    )
    ..bindTexelBuffer(
      f.getTexelBufferSlot('values'),
      values,
      gpu.PixelFormat.r32g32b32a32Float,
    )
    ..draw(6);
  if (!await done(cb)) return 'atomics: the command buffer failed';
  final c2 = await centre(read);
  return near(c2, [64, 77, 191, 255], 1) ? null : 'atomics: got $c2';
}

Future<String?> _storageFormats(_Kit kit) async {
  final ctx = kit.ctx;
  gpu.Texture make(
    gpu.PixelFormat format, {
    gpu.TextureType type = gpu.TextureType.texture2D,
    int layers = 1,
    int depth = 1,
    int mips = 1,
  }) => ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    8,
    8,
    format: format,
    textureType: type,
    layers: layers,
    depth: depth,
    mipLevelCount: mips,
    enableRenderTargetUsage: false,
    enableShaderWriteUsage: true,
  );
  final moments = make(gpu.PixelFormat.r16g16b16a16UNormInt);
  final array = make(
    gpu.PixelFormat.r16g16b16a16UNormInt,
    type: gpu.TextureType.texture2DArray,
    layers: 4,
  );
  final mipped = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: gpu.PixelFormat.r16g16b16a16UNormInt,
    mipLevelCount: 2,
    enableRenderTargetUsage: false,
    enableShaderWriteUsage: true,
  );
  final grid = make(
    gpu.PixelFormat.r32g32b32a32UInt,
    type: gpu.TextureType.texture3D,
    depth: 2,
  );
  final hdr = make(gpu.PixelFormat.r16g16b16a16Float);
  final shader = kit.shader('ImagesCompute');
  final cb = ctx.createCommandBuffer();
  cb.createComputePass()
    ..bindPipeline(ctx.createComputePipeline(shader))
    ..bindStorageImage(shader.getStorageImageSlot('moments'), moments)
    ..bindStorageImage(
      shader.getStorageImageSlot('moments_layer'),
      array.makeView(baseLayer: 2),
    )
    ..bindStorageImage(
      shader.getStorageImageSlot('moments_mip'),
      mipped.makeView(baseMipLevel: 1),
    )
    ..bindStorageImage(shader.getStorageImageSlot('grid'), grid)
    ..bindStorageImage(shader.getStorageImageSlot('hdr'), hdr)
    ..dispatch(2, 2);
  if (!await done(cb)) return 'the compute pass failed';
  Future<List<int>> sampleAt(gpu.Texture t, double lod) async {
    final out = kit.rgba8(16);
    await kit.draw(out, 'SampleAtFragment', (p, f) {
      p.bindTexture(f.getUniformSlot('source'), t, sampler: _nearest);
      p.bindUniform(f.getUniformSlot('At'), kit.floats([0.5, 0.5, lod, 0]));
    });
    return centre(out);
  }

  final m = await sampleAt(moments, 0);
  if (!near(m, [64, 128, 191, 255])) return 'RGBA16 unorm 2D: got $m';
  final mip = await sampleAt(mipped, 1);
  if (!near(mip, [128, 128, 128, 255])) return 'RGBA16 unorm mip 1: got $mip';
  final h = await sampleAt(hdr, 0);
  // 2.0 clamps to 1 in RGBA8.
  if (!near(h, [255, 128, 64, 255])) return 'RGBA16F 2D: got $h';
  final layerOut = kit.rgba8(16);
  await kit.draw(layerOut, 'LayerLodFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('layers'), array, sampler: _nearest);
    p.bindUniform(f.getUniformSlot('At'), kit.floats([2, 0, 0, 0]));
  });
  final l = await centre(layerOut);
  if (!near(l, [191, 128, 64, 255])) return 'RGBA16 unorm layer 2: got $l';
  final g = kit.rgba8(16);
  await kit.draw(g, 'Grid4Fragment', (p, f) {
    p.bindTexture(f.getUniformSlot('grid4'), grid, sampler: _nearest);
  });
  final gc = await centre(g);
  return near(gc, [50, 100, 150, 200]) ? null : 'RGBA32UI 3D: got $gc';
}

Future<String?> _metalOptions(_Kit kit) async {
  final out = kit.rgba8(16);
  await kit.draw(out, 'IeeeFragment', (p, f) {
    p.bindUniform(f.getUniformSlot('Zero'), kit.floats([0, 0, 0, 0]));
  });
  final c = await centre(out);
  // Red is NaN and green is Inf, which shaders may expect. Blue shows if -0 + 0
  // came out +0. A driver that drops the addition, such as the UHD 620 of Intel
  // on Vulkan, does what spirv-opt does in optimized bundles. The check reports
  // it and does not fail.
  if (c[0] < 128 || c[1] < 128) return 'NaN or Inf folded away: got $c';
  if (c[2] < 128) {
    kit.log('SMOKE release 9 -0 + 0 stays -0 on this driver: got $c');
  }
  return null;
}

Future<String?> _computeBuffers(_Kit kit) async {
  final ctx = kit.ctx;
  final shader = kit.shader('SkinCompute');
  final positions = kit.floats(List<double>.filled(8, 0));
  final args = _u32(kit, [0, 0, 0, 0, 0]);
  final indices = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(Uint16List.fromList([0, 1, 2, 2, 1, 3])),
  );
  final out = kit.rgba8(16);
  final cb = ctx.createCommandBuffer();
  cb.createComputePass()
    ..bindPipeline(ctx.createComputePipeline(shader))
    ..bindStorageBuffer(shader.getStorageBufferSlot('Positions'), positions)
    ..bindStorageBuffer(shader.getStorageBufferSlot('Args'), args)
    ..dispatch(1);
  final color = kit.shader('ColorFragment');
  cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: out, clearValue: Vector4(0, 0, 0, 1)),
      ),
    )
    ..bindPipeline(ctx.createRenderPipeline(kit.shader('QuadVertex'), color))
    ..bindVertexBuffer(positions)
    ..bindIndexBuffer(
      gpu.BufferView(indices, offsetInBytes: 0, lengthInBytes: 12),
      gpu.IndexType.int16,
    )
    ..bindUniform(
      color.getUniformSlot('Paint'),
      kit.floats([0.5, 0.75, 0.25, 1]),
    )
    ..drawIndirect(args, indexed: true);
  if (!await done(cb)) return 'the command buffer failed';
  final c = await centre(out);
  return near(c, [128, 191, 64, 255])
      ? null
      : 'got $c, want [128, 191, 64, 255]';
}

Future<String?> _drawParameters(_Kit kit) async {
  final ctx = kit.ctx;
  final out = kit.rgba8(16);
  final cb = ctx.createCommandBuffer();
  cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: out, clearValue: Vector4(0, 0, 0, 1)),
      ),
    )
    ..bindPipeline(
      ctx.createRenderPipeline(
        kit.shader('InvariantVertex'),
        kit.shader('BaseFragment'),
      ),
    )
    ..bindVertexBuffer(kit.quad)
    // Six vertices, one instance, from vertex 0 and instance 3.
    ..drawIndirect(_u32(kit, [6, 1, 0, 3]));
  if (!await done(cb)) return 'the command buffer failed';
  final left = await _pixel(out, 3, 8);
  final right = await _pixel(out, 12, 8);
  if (!near(left, [0, 0, 0, 255])) return 'clip distance: left half $left';
  return near(right, [120, 128, 64, 255])
      ? null
      : 'base instance 3: got $right, want [120, 128, 64, 255]';
}

Future<String?> _separateSamplers(_Kit kit) async {
  final ctx = kit.ctx;
  final albedo = ctx.createTexture(gpu.StorageMode.devicePrivate, 4, 4);
  albedo.overwrite(_texels(16, [100, 200, 50, 255]));
  final depth = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: gpu.PixelFormat.d32Float,
  );
  await _depthPass(kit, depth, 0.25);
  for (final (ref, want) in [
    (0.2, [100, 200, 50, 255]),
    (0.3, [0, 0, 0, 255]),
  ]) {
    final out = kit.rgba8(16);
    await kit.draw(out, 'SeparateFragment', (p, f) {
      p.bindSeparateTexture(f.getSeparateTextureSlot('albedo'), albedo);
      p.bindSeparateSampler(
        f.getSeparateSamplerSlot('albedo_sampler'),
        _nearest,
      );
      p.bindSeparateTexture(f.getSeparateTextureSlot('depth_map'), depth);
      p.bindSeparateSampler(
        f.getSeparateSamplerSlot('compare_sampler'),
        gpu.PrismarineSampler(compare: gpu.CompareFunction.less),
      );
      p.bindUniform(f.getUniformSlot('Ref'), kit.floats([ref, 0, 0, 0]));
    });
    final c = await centre(out);
    if (!near(c, want)) return 'reference $ref: got $c, want $want';
  }
  return null;
}

Future<String?> _bc3Array(_Kit kit) async {
  // 1392 x 1288, not a power of two, three layers and one mip, uploaded one
  // layer at a time as lightmaps are.
  final ctx = kit.ctx;
  const w = 1392, h = 1288;
  final array = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    w,
    h,
    format: gpu.PixelFormat.bc3RGBAUNormInt,
    textureType: gpu.TextureType.texture2DArray,
    layers: 3,
    enableRenderTargetUsage: false,
  );
  final colours = [0xF800, 0x07E0, 0x001F];
  for (var layer = 0; layer < 3; layer++) {
    final blocks = (w ~/ 4) * (h ~/ 4);
    final bytes = Uint8List(blocks * 16);
    for (var b = 0; b < blocks; b++) {
      final o = b * 16;
      bytes[o] = 255; // alpha0
      bytes[o + 1] = 255; // alpha1, then indices 0
      bytes[o + 8] = colours[layer] & 0xff;
      bytes[o + 9] = colours[layer] >> 8;
      bytes[o + 10] = colours[layer] & 0xff;
      bytes[o + 11] = colours[layer] >> 8; // colour indices 0
    }
    array.overwrite(ByteData.sublistView(bytes), slice: layer);
  }
  final ph = _ph(kit);
  final wants = [
    [255, 0, 0, 255],
    [0, 255, 0, 255],
    [0, 0, 255, 255],
  ];
  for (var layer = 0; layer < 3; layer++) {
    final out = kit.rgba8(16);
    await kit.draw(out, 'LayersFragment', (p, f) {
      _bindLayers(p, f, layers: array, volume: ph.volume, grid: ph.grid);
      _pick(kit, p, f, layer.toDouble(), 0);
    });
    final c = await centre(out);
    if (!near(c, wants[layer]))
      return 'layer $layer: got $c, want ${wants[layer]}';
  }
  return null;
}
