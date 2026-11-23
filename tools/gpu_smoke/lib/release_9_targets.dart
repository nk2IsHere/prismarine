part of 'release_9.dart';

// Layered textures, the added formats and multisampled depth.

ByteData _texels(int count, List<int> rgba) {
  final bytes = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    bytes.setAll(i * 4, rgba);
  }
  return ByteData.sublistView(bytes);
}

const _layerColours = [
  [200, 10, 10, 255],
  [10, 200, 10, 255],
  [10, 10, 200, 255],
  [200, 200, 10, 255],
];

void _pick(
  _Kit kit,
  gpu.RenderPass p,
  gpu.Shader f,
  double slice,
  double mode,
) {
  p.bindUniform(f.getUniformSlot('Pick'), kit.floats([slice, mode, 0, 0]));
}

// Integer and 32-bit float textures can't be filtered.
final _nearest = gpu.SamplerOptions(
  minFilter: gpu.MinMagFilter.nearest,
  magFilter: gpu.MinMagFilter.nearest,
);

/// Binds every sampler of LayersFragment (unused ones get placeholders:
/// Metal and Vulkan want every declared texture bound).
void _bindLayers(
  gpu.RenderPass p,
  gpu.Shader f, {
  required gpu.Texture layers,
  required gpu.Texture volume,
  required gpu.Texture grid,
}) {
  p.bindTexture(f.getUniformSlot('layers'), layers, sampler: _nearest);
  p.bindTexture(f.getUniformSlot('volume'), volume, sampler: _nearest);
  p.bindTexture(f.getUniformSlot('grid'), grid, sampler: _nearest);
}

class _Placeholders {
  _Placeholders(gpu.GpuContext ctx)
    : layers = ctx.createTexture(
        gpu.StorageMode.devicePrivate,
        4,
        4,
        textureType: gpu.TextureType.texture2DArray,
        layers: 4,
        enableRenderTargetUsage: true,
      ),
      volume = ctx.createTexture(
        gpu.StorageMode.devicePrivate,
        4,
        4,
        textureType: gpu.TextureType.texture3D,
        depth: 4,
        enableRenderTargetUsage: false,
      ),
      grid = ctx.createTexture(
        gpu.StorageMode.devicePrivate,
        16,
        16,
        format: gpu.PixelFormat.r32UInt,
        textureType: gpu.TextureType.texture3D,
        depth: 4,
        enableRenderTargetUsage: false,
        enableShaderWriteUsage: true,
      );

  final gpu.Texture layers;
  final gpu.Texture volume;
  final gpu.Texture grid;
}

_Placeholders? _placeholders;
_Placeholders _ph(_Kit kit) => _placeholders ??= _Placeholders(kit.ctx);

Future<String?> _array(_Kit kit) async {
  final ph = _ph(kit);
  for (var l = 0; l < 4; l++) {
    ph.layers.overwrite(_texels(16, _layerColours[l]), slice: l);
  }
  for (var l = 0; l < 4; l++) {
    final target = kit.rgba8(16);
    await kit.draw(target, 'LayersFragment', (p, f) {
      _bindLayers(p, f, layers: ph.layers, volume: ph.volume, grid: ph.grid);
      _pick(kit, p, f, l.toDouble(), 0);
    });
    final c = await centre(target);
    if (!near(c, _layerColours[l])) {
      return 'layer $l: got $c, want ${_layerColours[l]}';
    }
  }
  return null;
}

Future<String?> _arrayTarget(_Kit kit) async {
  final ph = _ph(kit);
  // Paint layer 1 grey through a render pass on that slice, then sample it.
  final color = kit.shader('ColorFragment');
  final pipeline = kit.ctx.createRenderPipeline(
    kit.shader('QuadVertex'),
    color,
  );
  final cb = kit.ctx.createCommandBuffer();
  final pass = cb.createRenderPass(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: ph.layers,
        slice: 1,
        clearValue: Vector4(0, 0, 0, 1),
      ),
    ),
  );
  pass
    ..bindPipeline(pipeline)
    ..bindVertexBuffer(kit.quad)
    ..bindUniform(
      color.getUniformSlot('Paint'),
      kit.floats([0.5, 0.25, 0.75, 1]),
    )
    ..draw(6);
  await done(cb);
  final target = kit.rgba8(16);
  await kit.draw(target, 'LayersFragment', (p, f) {
    _bindLayers(p, f, layers: ph.layers, volume: ph.volume, grid: ph.grid);
    _pick(kit, p, f, 1, 0);
  });
  final c = await centre(target);
  // Layer 2 must keep its upload.
  final other = kit.rgba8(16);
  await kit.draw(other, 'LayersFragment', (p, f) {
    _bindLayers(p, f, layers: ph.layers, volume: ph.volume, grid: ph.grid);
    _pick(kit, p, f, 2, 0);
  });
  final c2 = await centre(other);
  if (!near(c, [128, 64, 191, 255])) return 'layer 1: got $c';
  if (!near(c2, _layerColours[2])) return 'layer 2 changed: got $c2';
  return null;
}

Future<String?> _volume(_Kit kit) async {
  final ph = _ph(kit);
  for (var z = 0; z < 4; z++) {
    ph.volume.overwrite(_texels(16, _layerColours[3 - z]), slice: z);
  }
  for (var z = 0; z < 4; z++) {
    final target = kit.rgba8(16);
    await kit.draw(target, 'LayersFragment', (p, f) {
      _bindLayers(p, f, layers: ph.layers, volume: ph.volume, grid: ph.grid);
      _pick(kit, p, f, z.toDouble(), 1);
    });
    final c = await centre(target);
    if (!near(c, _layerColours[3 - z])) {
      return 'slice $z: got $c, want ${_layerColours[3 - z]}';
    }
  }
  return null;
}

/// Renders a colour into a texture of [format], samples it into RGBA8.
Future<List<int>> _throughFormat(
  _Kit kit,
  gpu.PixelFormat format,
  List<double> colour,
) async {
  final t = kit.ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: format,
  );
  await kit.draw(t, 'ColorFragment', (p, f) {
    p.bindUniform(f.getUniformSlot('Paint'), kit.floats(colour));
  });
  final out = kit.rgba8(16);
  await kit.draw(out, 'SampleFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('source'), t, sampler: _nearest);
  });
  return centre(out);
}

/// A depth-only pass at depth [z] into [depth], then [read] samples it.
Future<void> _depthPass(_Kit kit, gpu.Texture depth, double z) async {
  final v = kit.shader('DepthVertex');
  final f = kit.shader('DepthOnlyFragment');
  final pipeline = kit.ctx.createRenderPipeline(v, f);
  final cb = kit.ctx.createCommandBuffer();
  final pass = cb.createRenderPass(
    gpu.RenderTarget(
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depth,
        depthClearValue: 1.0,
        depthStoreAction: gpu.StoreAction.store,
      ),
    ),
  );
  pass
    ..bindPipeline(pipeline)
    ..setDepthWriteEnable(true)
    ..setDepthCompareOperation(gpu.CompareFunction.less)
    ..bindVertexBuffer(kit.quad)
    ..bindUniform(v.getUniformSlot('Depth'), kit.floats([z, 0, 0, 0]))
    ..draw(6);
  await done(cb);
}

Future<String?> _formats(_Kit kit) async {
  final cases = <(gpu.PixelFormat, List<double>, List<int>)>[
    (
      gpu.PixelFormat.r11g11b10UFloat,
      [0.5, 0.25, 0.75, 1],
      [128, 64, 191, 255],
    ),
    (
      gpu.PixelFormat.r16g16b16a16UNormInt,
      [0.5, 0.25, 0.75, 0.5],
      [128, 64, 191, 128],
    ),
    (
      gpu.PixelFormat.r16g16b16a16Float,
      [0.5, 0.25, 0.75, 1],
      [128, 64, 191, 255],
    ),
    (gpu.PixelFormat.r16g16Float, [0.5, 0.25, 0, 1], [128, 64, 0, 255]),
    (gpu.PixelFormat.r32g32Float, [0.5, 0.25, 0, 1], [128, 64, 0, 255]),
    (
      gpu.PixelFormat.r10g10b10a2UNormInt,
      [0.5, 0.25, 0.75, 1],
      [128, 64, 191, 255],
    ),
    (gpu.PixelFormat.r16UNormInt, [0.5, 0, 0, 1], [128, 0, 0, 255]),
    (gpu.PixelFormat.r16g16UNormInt, [0.5, 0.25, 0, 1], [128, 64, 0, 255]),
  ];
  for (final (format, colour, want) in cases) {
    final c = await _throughFormat(kit, format, colour);
    if (!near(c, want)) return '$format: got $c, want $want';
  }
  for (final format in [
    gpu.PixelFormat.d16UNormInt,
    gpu.PixelFormat.d32Float,
  ]) {
    final depth = kit.ctx.createTexture(
      gpu.StorageMode.devicePrivate,
      16,
      16,
      format: format,
    );
    await _depthPass(kit, depth, 0.25);
    final out = kit.rgba8(16);
    await kit.draw(out, 'SampleFragment', (p, f) {
      p.bindTexture(f.getUniformSlot('source'), depth, sampler: _nearest);
    });
    final c = await centre(out);
    // The depth sampled as red (0.25 → 64); the other channels vary by API.
    if ((c[0] - 64).abs() > 2) return '$format depth: got $c, want red 64';
  }
  return null;
}

Future<String?> _msaaDepth(_Kit kit) async {
  final depth = kit.ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: gpu.PixelFormat.d16UNormInt,
    sampleCount: 2,
    textureType: gpu.TextureType.texture2DMultisample,
  );
  await _depthPass(kit, depth, 0.5);
  final out = kit.rgba8(16);
  await kit.draw(out, 'DepthMsFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('depth_ms'), depth, sampler: _nearest);
  });
  final c = await centre(out);
  return near(c, [128, 128, 0, 255]) ? null : 'got $c, want [128, 128, 0, 255]';
}
