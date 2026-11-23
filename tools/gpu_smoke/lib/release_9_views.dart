part of 'release_9.dart';

// Texture views: a mip level built from the level above in a render pass
// (S2's MakeMipLevel), and one layer of an array rendered as a 2D target.

Future<String?> _views(_Kit kit) async {
  final ctx = kit.ctx;
  final mipped = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    mipLevelCount: 2,
  );
  mipped.overwrite(_texels(256, [40, 120, 220, 255]));
  final level0 = mipped.makeView();
  final level1 = mipped.makeView(baseMipLevel: 1);
  // Level 1 from level 0, in one pass on the same texture.
  await kit.draw(level1, 'SampleFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('source'), level0, sampler: _nearest);
  });
  final out = kit.rgba8(8);
  await kit.draw(out, 'SampleFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('source'), level1, sampler: _nearest);
  });
  final c = await centre(out);
  if (!near(c, [40, 120, 220, 255])) {
    return 'mip level 1: got $c, want [40, 120, 220, 255]';
  }

  // Layer 3 of the array as a plain 2D target, then sampled from the array.
  final ph = _ph(kit);
  final layer3 = ph.layers.makeView(baseLayer: 3);
  await kit.draw(layer3, 'ColorFragment', (p, f) {
    p.bindUniform(f.getUniformSlot('Paint'), kit.floats([0.25, 0.75, 0.5, 1]));
  });
  final g = kit.rgba8(16);
  await kit.draw(g, 'LayersFragment', (p, f) {
    _bindLayers(p, f, layers: ph.layers, volume: ph.volume, grid: ph.grid);
    _pick(kit, p, f, 3, 0);
  });
  final c2 = await centre(g);
  if (!near(c2, [64, 191, 128, 255])) {
    return 'array layer 3: got $c2, want [64, 191, 128, 255]';
  }
  return null;
}

/// Both layers of a two-layer RGBA8 array rewritten from one buffer in one
/// command buffer, as Enlighten's output is uploaded every frame, then
/// sampled.
Future<String?> _arrayUpload(_Kit kit) async {
  final ctx = kit.ctx;
  final array = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    4,
    4,
    textureType: gpu.TextureType.texture2DArray,
    layers: 2,
    enableRenderTargetUsage: false,
  );
  final bytes = Uint8List(2 * 16 * 4);
  for (var i = 0; i < 16; i++) {
    bytes.setAll(i * 4, [250, 20, 90, 255]);
    bytes.setAll(64 + i * 4, [30, 160, 240, 255]);
  }
  final buffer = ctx.createDeviceBufferWithCopy(ByteData.sublistView(bytes));
  final cb = ctx.createCommandBuffer();
  for (var layer = 0; layer < 2; layer++) {
    cb.copyBufferToTexture(
      gpu.BufferView(buffer, offsetInBytes: layer * 64, lengthInBytes: 64),
      gpu.TextureRegion(array, slice: layer),
    );
  }
  await done(cb);
  final ph = _ph(kit);
  for (final (layer, want) in [
    (0, [250, 20, 90, 255]),
    (1, [30, 160, 240, 255]),
  ]) {
    final out = kit.rgba8(16);
    await kit.draw(out, 'LayersFragment', (p, f) {
      _bindLayers(p, f, layers: array, volume: ph.volume, grid: ph.grid);
      _pick(kit, p, f, layer.toDouble(), 0);
    });
    final c = await centre(out);
    if (!near(c, want)) return 'layer $layer: got $c, want $want';
  }
  return null;
}
