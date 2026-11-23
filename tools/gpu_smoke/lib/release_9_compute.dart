part of 'release_9.dart';

// A compute pass whose outputs, a storage buffer, an RGBA8 storage image and
// a uint 3D storage image, render passes read afterwards.

Future<String?> _compute(_Kit kit) async {
  final ctx = kit.ctx;
  final ph = _ph(kit);
  final shader = kit.shader('Compute');
  final pipeline = ctx.createComputePipeline(shader);
  final inputs = kit.floats([
    0.1, 0.2, 0.3, 0.4, //
    0.25, 0.125, 0.0625, 0.5,
    0.3, 0.3, 0.3, 0.3,
    0.4, 0.4, 0.4, 0.4,
  ]);
  final outputs = kit.floats(List<double>.filled(256 * 4, 0));
  final image = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
    enableRenderTargetUsage: false,
    enableShaderWriteUsage: true,
  );

  final cb = ctx.createCommandBuffer();
  final pass = cb.createComputePass()
    ..bindPipeline(pipeline)
    ..bindStorageBuffer(shader.getStorageBufferSlot('Inputs'), inputs)
    ..bindStorageBuffer(shader.getStorageBufferSlot('Outputs'), outputs)
    ..bindUniform(shader.getUniformSlot('Scale'), kit.floats([2, 4, 8, 1]))
    ..bindStorageImage(shader.getStorageImageSlot('color_out'), image)
    ..bindStorageImage(shader.getStorageImageSlot('grid_out'), ph.grid);
  pass.dispatch(2, 2);
  // A render pass on the same command buffer reads the storage buffer.
  final read = kit.rgba8(16);
  final f = kit.shader('OutputsFragment');
  final rp = cb.createRenderPass(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: read, clearValue: Vector4(0, 0, 0, 1)),
    ),
  );
  rp
    ..bindPipeline(ctx.createRenderPipeline(kit.shader('QuadVertex'), f))
    ..bindVertexBuffer(kit.quad)
    ..bindStorageBuffer(f.getStorageBufferSlot('Outputs'), outputs)
    ..draw(6);
  if (!await done(cb)) return 'the command buffer failed';

  // outputs[17] = inputs[1] * (2, 4, 8, 1) = (0.5, 0.5, 0.5, 0.5).
  final c = await centre(read);
  if (!near(c, [128, 128, 128, 128])) {
    return 'storage buffer: got $c, want [128, 128, 128, 128]';
  }
  // The storage image, sampled.
  final sampled = kit.rgba8(16);
  await kit.draw(sampled, 'SampleFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('source'), image, sampler: _nearest);
  });
  final c2 = await centre(sampled);
  if (!near(c2, [64, 128, 191, 255])) {
    return 'storage image: got $c2, want [64, 128, 191, 255]';
  }
  // The uint 3D grid at (1, 1, 2) holds i = 1 * 16 + 1 = 17, + 0x1100.
  final g = kit.rgba8(16);
  await kit.draw(g, 'LayersFragment', (p, f) {
    _bindLayers(p, f, layers: ph.layers, volume: ph.volume, grid: ph.grid);
    _pick(kit, p, f, 2, 2);
  });
  final c3 = await centre(g);
  if (!near(c3, [17, 0x11, 0, 255], 0)) {
    return 'uint 3D storage image: got $c3, want [17, 17, 0, 255]';
  }
  return null;
}

/// The compute pass again with its workgroup counts read from a buffer, then
/// a quad drawn with its counts read from a buffer.
Future<String?> _indirect(_Kit kit) async {
  final ctx = kit.ctx;
  final ph = _ph(kit);
  final shader = kit.shader('Compute');
  final pipeline = ctx.createComputePipeline(shader);
  final u32 = (List<int> v) {
    final b = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Uint32List.fromList(v)),
    );
    return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: v.length * 4);
  };
  final inputs = kit.floats([
    0.5,
    0.5,
    0.5,
    0.5,
    0.125,
    0.25,
    0.375,
    0.5,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
  final outputs = kit.floats(List<double>.filled(256 * 4, 0));
  final image = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    enableRenderTargetUsage: false,
    enableShaderWriteUsage: true,
  );
  final cb = ctx.createCommandBuffer();
  cb.createComputePass()
    ..bindPipeline(pipeline)
    ..bindStorageBuffer(shader.getStorageBufferSlot('Inputs'), inputs)
    ..bindStorageBuffer(shader.getStorageBufferSlot('Outputs'), outputs)
    ..bindUniform(shader.getUniformSlot('Scale'), kit.floats([2, 2, 2, 2]))
    ..bindStorageImage(shader.getStorageImageSlot('color_out'), image)
    ..bindStorageImage(shader.getStorageImageSlot('grid_out'), ph.grid)
    ..dispatchIndirect(u32([2, 2, 1]));
  final read = kit.rgba8(16);
  final f = kit.shader('OutputsFragment');
  cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: read, clearValue: Vector4(0, 0, 0, 1)),
      ),
    )
    ..bindPipeline(ctx.createRenderPipeline(kit.shader('QuadVertex'), f))
    ..bindVertexBuffer(kit.quad)
    ..bindStorageBuffer(f.getStorageBufferSlot('Outputs'), outputs)
    // Six vertices, one instance, from vertex 0 and instance 0.
    ..drawIndirect(u32([6, 1, 0, 0]));
  if (!await done(cb)) return 'the command buffer failed';
  // outputs[17] = inputs[1] * 2 = (0.25, 0.5, 0.75, 1).
  final c = await centre(read);
  return near(c, [64, 128, 191, 255])
      ? null
      : 'got $c, want [64, 128, 191, 255]';
}
