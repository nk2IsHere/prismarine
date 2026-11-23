part of 'release_9.dart';

// Sampler state, copies and mip generation, vertex formats and step rates,
// layered passes and cube arrays.

Future<List<int>> _pixel(gpu.Texture t, int x, int y) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImage(t.asImage(), ui.Offset.zero, ui.Paint());
  final picture = recorder.endRecording();
  final image = await picture.toImage(t.width, t.height);
  picture.dispose();
  final bytes = (await image.toByteData())!;
  image.dispose();
  final i = (y * t.width + x) * 4;
  return bytes.buffer.asUint8List(bytes.offsetInBytes + i, 4).toList();
}

Future<String?> _samplers(_Kit kit) async {
  // A comparison of a D32 float depth of 0.25 with references on either
  // side of it.
  final depth = kit.ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: gpu.PixelFormat.d32Float,
  );
  await _depthPass(kit, depth, 0.25);
  for (final (ref, want) in [(0.2, 255), (0.3, 0)]) {
    final out = kit.rgba8(16);
    await kit.draw(out, 'ShadowFragment', (p, f) {
      p.bindTexture(
        f.getUniformSlot('shadow'),
        depth,
        sampler: gpu.PrismarineSampler(compare: gpu.CompareFunction.less),
      );
      p.bindUniform(f.getUniformSlot('Ref'), kit.floats([ref, 0, 0, 0]));
    });
    final c = await centre(out);
    if ((c[0] - want).abs() > 2)
      return 'compare at $ref: got $c, want red $want';
  }
  // Two mip levels of different colours, a border, LOD clamps.
  final t = kit.ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    8,
    8,
    mipLevelCount: 2,
  );
  t.overwrite(_texels(64, [200, 40, 40, 255]));
  t.overwrite(_texels(16, [40, 40, 200, 255]), mipLevel: 1);
  final cases = <(List<double>, gpu.PrismarineSampler, List<int>, String)>[
    (
      [1.5, 0.5, 0, 0],
      gpu.PrismarineSampler(
        widthAddressMode: gpu.SamplerAddressMode.clampToBorder,
        borderColor: gpu.PrismarineBorderColor.opaqueWhite,
      ),
      [255, 255, 255, 255],
      'border',
    ),
    (
      [0.5, 0.5, 1, 0],
      gpu.PrismarineSampler(mipFilter: gpu.MipFilter.nearest, maxLod: 0),
      [200, 40, 40, 255],
      'max LOD',
    ),
    (
      [0.5, 0.5, 0, 0],
      gpu.PrismarineSampler(mipFilter: gpu.MipFilter.nearest, minLod: 1),
      [40, 40, 200, 255],
      'min LOD',
    ),
    (
      [-0.25, 0.5, 0, 0],
      gpu.PrismarineSampler(
        widthAddressMode: gpu.SamplerAddressMode.mirrorClampToEdge,
      ),
      [200, 40, 40, 255],
      'mirror clamp',
    ),
  ];
  for (final (at, sampler, want, name) in cases) {
    final out = kit.rgba8(16);
    await kit.draw(out, 'SampleAtFragment', (p, f) {
      p.bindTexture(f.getUniformSlot('source'), t, sampler: sampler);
      p.bindUniform(f.getUniformSlot('At'), kit.floats(at));
    });
    final c = await centre(out);
    if (!near(c, want)) return '$name: got $c, want $want';
  }
  return null;
}

Future<String?> _copies(_Kit kit) async {
  final ctx = kit.ctx;
  final colour = [30, 200, 120, 255];
  final source = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    4,
    4,
    textureType: gpu.TextureType.texture2DArray,
    layers: 2,
  );
  source.overwrite(_texels(16, colour), slice: 1);
  final mipped = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    8,
    8,
    mipLevelCount: 2,
  );
  final round = ctx.createTexture(gpu.StorageMode.devicePrivate, 4, 4);
  final buffer = ctx.createDeviceBuffer(gpu.StorageMode.devicePrivate, 64);
  final cb = ctx.createCommandBuffer()
    ..copyTextureRegion(
      source,
      mipped,
      x: 0,
      y: 0,
      width: 4,
      height: 4,
      sourceSlice: 1,
      destinationMipLevel: 1,
    )
    ..copyTextureRegionToBuffer(
      source,
      buffer,
      x: 0,
      y: 0,
      width: 4,
      height: 4,
      slice: 1,
    );
  cb.copyBufferToTexture(
    gpu.BufferView(buffer, offsetInBytes: 0, lengthInBytes: 64),
    gpu.TextureRegion(round),
  );
  if (!await done(cb)) return 'the copies failed';
  final out = kit.rgba8(16);
  await kit.draw(out, 'SampleAtFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('source'), mipped, sampler: _nearest);
    p.bindUniform(f.getUniformSlot('At'), kit.floats([0.5, 0.5, 1, 0]));
  });
  final c = await centre(out);
  if (!near(c, colour)) return 'slice 1 to mip 1: got $c, want $colour';
  final out2 = kit.rgba8(16);
  await kit.draw(out2, 'SampleFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('source'), round, sampler: _nearest);
  });
  final c2 = await centre(out2);
  if (!near(c2, colour)) return 'through a buffer: got $c2, want $colour';

  // Mip generation over every layer of an array.
  final array = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    8,
    8,
    textureType: gpu.TextureType.texture2DArray,
    layers: 2,
    mipLevelCount: 2,
  );
  array.overwrite(_texels(64, [10, 20, 30, 255]), slice: 0);
  array.overwrite(_texels(64, colour), slice: 1);
  final cb2 = ctx.createCommandBuffer()..generateMipmaps(array);
  if (!await done(cb2)) return 'mip generation failed';
  final out3 = kit.rgba8(16);
  await kit.draw(out3, 'LayerLodFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('layers'), array, sampler: _nearest);
    p.bindUniform(f.getUniformSlot('At'), kit.floats([1, 1, 0, 0]));
  });
  final c3 = await centre(out3);
  if (!near(c3, colour)) return 'array layer 1 mip 1: got $c3, want $colour';
  return null;
}

Future<String?> _vertexFormats(_Kit kit) async {
  final ctx = kit.ctx;
  // Positions as float32x2 and colours as unorm8x4, then positions as half2.
  final quad = [
    -1.0,
    -1.0,
    1.0,
    -1.0,
    -1.0,
    1.0,
    -1.0,
    1.0,
    1.0,
    -1.0,
    1.0,
    1.0,
  ];
  final colour = [64, 128, 191, 255];
  final f32 = ByteData(6 * 12);
  for (var v = 0; v < 6; v++) {
    f32.setFloat32(v * 12, quad[v * 2], Endian.little);
    f32.setFloat32(v * 12 + 4, quad[v * 2 + 1], Endian.little);
    for (var k = 0; k < 4; k++) {
      f32.setUint8(v * 12 + 8 + k, colour[k]);
    }
  }
  int half(double x) => x == 1.0 ? 0x3c00 : (x == -1.0 ? 0xbc00 : 0);
  final f16 = ByteData(6 * 8);
  for (var v = 0; v < 6; v++) {
    f16.setUint16(v * 8, half(quad[v * 2]), Endian.little);
    f16.setUint16(v * 8 + 2, half(quad[v * 2 + 1]), Endian.little);
    for (var k = 0; k < 4; k++) {
      f16.setUint8(v * 8 + 4 + k, colour[k]);
    }
  }
  for (final (data, posFormat, stride, colourOffset) in [
    (f32, gpu.VertexFormat.float32x2, 12, 8),
    (f16, gpu.VertexFormat.float16x2, 8, 4),
  ]) {
    final pipeline = ctx.createRenderPipeline(
      kit.shader('AttribVertex'),
      kit.shader('VColorFragment'),
      vertexLayout: gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: stride,
            attributes: [
              gpu.VertexAttribute(
                name: 'position',
                format: posFormat,
                offsetInBytes: 0,
              ),
              gpu.VertexAttribute(
                name: 'color',
                format: gpu.VertexFormat.unorm8x4,
                offsetInBytes: colourOffset,
              ),
            ],
          ),
        ],
      ),
    );
    final buffer = ctx.createDeviceBufferWithCopy(data);
    final out = kit.rgba8(16);
    final cb = ctx.createCommandBuffer();
    cb.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(texture: out, clearValue: Vector4(0, 0, 0, 1)),
        ),
      )
      ..bindPipeline(pipeline)
      ..bindVertexBuffer(
        gpu.BufferView(
          buffer,
          offsetInBytes: 0,
          lengthInBytes: data.lengthInBytes,
        ),
      )
      ..draw(6);
    await done(cb);
    final c = await centre(out);
    if (!near(c, colour)) return '$posFormat + unorm8x4: got $c, want $colour';
  }

  // A per-instance tint advancing every two instances.
  final pipeline = ctx.createRenderPipeline(
    kit.shader('SteppedVertex'),
    kit.shader('VColorFragment'),
    vertexLayout: gpu.VertexLayout(
      buffers: [
        gpu.VertexBuffer(
          strideInBytes: 8,
          attributes: [
            gpu.VertexAttribute(
              name: 'position',
              format: gpu.VertexFormat.float32x2,
              offsetInBytes: 0,
            ),
          ],
        ),
        gpu.VertexBuffer(
          strideInBytes: 4,
          stepMode: gpu.VertexStepMode.instance,
          stepRate: 2,
          attributes: [
            gpu.VertexAttribute(
              name: 'tint',
              format: gpu.VertexFormat.unorm8x4,
              offsetInBytes: 0,
            ),
          ],
        ),
      ],
    ),
  );
  final tints = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(Uint8List.fromList([250, 0, 0, 255, 0, 0, 250, 255])),
  );
  final out = kit.rgba8(16);
  final cb = ctx.createCommandBuffer();
  cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: out, clearValue: Vector4(0, 0, 0, 1)),
      ),
    )
    ..bindPipeline(pipeline)
    ..bindVertexBuffer(kit.quad)
    ..bindVertexBuffer(
      gpu.BufferView(tints, offsetInBytes: 0, lengthInBytes: 8),
      slot: 1,
    )
    ..draw(6, instanceCount: 4);
  await done(cb);
  final row0 = [await _pixel(out, 4, 4), await _pixel(out, 12, 4)];
  final row1 = [await _pixel(out, 4, 12), await _pixel(out, 12, 12)];
  final red = [250, 0, 0, 255], blue = [0, 0, 250, 255];
  final ok =
      (near(row0[0], red) &&
          near(row0[1], red) &&
          near(row1[0], blue) &&
          near(row1[1], blue)) ||
      (near(row0[0], blue) &&
          near(row0[1], blue) &&
          near(row1[0], red) &&
          near(row1[1], red));
  return ok ? null : 'step rate 2: rows $row0 $row1';
}

Future<String?> _layered(_Kit kit) async {
  final ctx = kit.ctx;
  final array = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    8,
    8,
    textureType: gpu.TextureType.texture2DArray,
    layers: 4,
  );
  final pipeline = ctx.createRenderPipeline(
    kit.shader('LayeredVertex'),
    kit.shader('LayerColorFragment'),
  );
  final cb = ctx.createCommandBuffer();
  cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: array,
          slice: -1,
          clearValue: Vector4(0, 0, 0, 1),
        ),
      ),
    )
    ..bindPipeline(pipeline)
    ..bindVertexBuffer(kit.quad)
    ..draw(6, instanceCount: 4);
  if (!await done(cb)) return 'the layered pass failed';
  for (var layer = 0; layer < 4; layer++) {
    final out = kit.rgba8(16);
    await kit.draw(out, 'LayerLodFragment', (p, f) {
      p.bindTexture(f.getUniformSlot('layers'), array, sampler: _nearest);
      p.bindUniform(
        f.getUniformSlot('At'),
        kit.floats([layer.toDouble(), 0, 0, 0]),
      );
    });
    final c = await centre(out);
    final want = [
      (layer * 0.25 * 255).round(),
      ((1 - layer * 0.25) * 255).round(),
      128,
      255,
    ];
    if (!near(c, want)) return 'layer $layer: got $c, want $want';
  }

  // A cube array of two cubes, read at face +X of cube 1.
  final cubes = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    4,
    4,
    textureType: gpu.TextureType.textureCubeArray,
    layers: 2,
    enableRenderTargetUsage: false,
  );
  for (var face = 0; face < 12; face++) {
    cubes.overwrite(
      _texels(16, [face * 20, 255 - face * 20, 60, 255]),
      slice: face,
    );
  }
  final out = kit.rgba8(16);
  await kit.draw(out, 'CubeFragment', (p, f) {
    p.bindTexture(f.getUniformSlot('cubes'), cubes, sampler: _nearest);
    p.bindUniform(f.getUniformSlot('At'), kit.floats([1, 0, 0, 0]));
  });
  final c = await centre(out);
  // Face 6 is the +X face of cube 1.
  return near(c, [120, 135, 60, 255])
      ? null
      : 'cube 1 +X: got $c, want [120, 135, 60, 255]';
}
