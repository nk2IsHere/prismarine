part of 'release_7.dart';

extension _Replays on _Smoke {
  // 2d. Replays into an MRT pass of RGBA8 + R32F + depth. Draws recorded in
  // one pass with their uniforms at different offsets of one buffer and
  // replayed into a fresh pass must give the bytes of the recorded pass in
  // every target.
  Future<void> replays() async {
    if (fs.mcsmRetainedDraws) {
      final mixed = fs.mcsmMixedColorAttachmentFormats;
      final vG = lib['SmokeGbufferVertex']!;
      final gLayout = gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: 8,
            attributes: [
              gpu.VertexAttribute(
                name: 'position',
                format: gpu.VertexFormat.float32x2,
              ),
            ],
          ),
          gpu.VertexBuffer(
            strideInBytes: 28,
            stepMode: gpu.VertexStepMode.instance,
            attributes: [
              gpu.VertexAttribute(
                name: 'offset',
                format: gpu.VertexFormat.float32x2,
              ),
              gpu.VertexAttribute(
                name: 'color',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 8,
              ),
              gpu.VertexAttribute(
                name: 'depth',
                format: gpu.VertexFormat.float32,
                offsetInBytes: 24,
              ),
            ],
          ),
        ],
      );
      final pipeline = ctx.createRenderPipeline(
        vG,
        fMrt,
        vertexLayout: gLayout,
      );
      final c0 = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
      final c1 = rt(
        mixed ? gpu.PixelFormat.r32Float : gpu.PixelFormat.r32g32b32a32Float,
      );
      final depth = ctx.createTexture(
        gpu.StorageMode.devicePrivate,
        64,
        64,
        format: ctx.defaultDepthStencilFormat,
        enableRenderTargetUsage: true,
      )!;
      final copyOut = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
      final quads = ctx.createDeviceBufferWithCopy(
        ByteData.sublistView(
          Float32List.fromList([
            -0.25, 0, 0, 0.125, 1, 1, 0.2, //
            0.25, 0, 1, 0.25, 0, 1, 0.6, //
            0, 0.5, 0.5, 0.5, 0.5, 1, 0.4, //
          ]),
        ),
      );
      // Two FrameInfo blocks in one buffer, 256 bytes apart.
      final blocks = Float32List(128)
        ..[0] = 0.5
        ..[64] = 0.3;
      final uniforms = ctx.createDeviceBufferWithCopy(
        ByteData.sublistView(blocks),
      );
      final list = fs.McsmDrawList();
      Future<(Uint8List, Uint8List)> frame(bool record) async {
        var cb = ctx.createCommandBuffer();
        final p = cb.createRenderPass(
          gpu.RenderTarget(
            colorAttachments: [
              gpu.ColorAttachment(texture: c0, clearValue: Vector4(0, 0, 0, 1)),
              gpu.ColorAttachment(texture: c1, clearValue: Vector4.zero()),
            ],
            depthStencilAttachment: gpu.DepthStencilAttachment(
              texture: depth,
              depthClearValue: 1.0,
            ),
          ),
        );
        p.setColorBlendEnable(false, colorAttachmentIndex: 1);
        if (record) {
          fs.mcsmBeginRecording(p, list);
          p
            ..bindPipeline(pipeline)
            ..setDepthWriteEnable(true)
            ..setDepthCompareOperation(gpu.CompareFunction.less)
            ..bindVertexBuffer(quad)
            ..bindVertexBuffer(
              gpu.BufferView(quads, offsetInBytes: 0, lengthInBytes: 56),
              slot: 1,
            )
            ..bindUniform(
              vG.getUniformSlot('FrameInfo'),
              gpu.BufferView(uniforms, offsetInBytes: 0, lengthInBytes: 16),
            )
            ..draw(6, instanceCount: 2)
            ..bindVertexBuffer(
              gpu.BufferView(quads, offsetInBytes: 56, lengthInBytes: 28),
              slot: 1,
            )
            ..bindUniform(
              vG.getUniformSlot('FrameInfo'),
              gpu.BufferView(uniforms, offsetInBytes: 256, lengthInBytes: 16),
            )
            ..draw(6);
          fs.mcsmEndRecording(p);
        } else {
          fs.mcsmReplay(p, list, Int32List.fromList([0, 1]), 2);
        }
        await _done(cb);
        cb = ctx.createCommandBuffer();
        final fsv = baseShaderLibrary['FullscreenVertex']!;
        final fcopy = baseShaderLibrary['CopyFragment']!;
        cb.createRenderPass(
            gpu.RenderTarget.singleColor(
              gpu.ColorAttachment(
                texture: copyOut,
                clearValue: Vector4(0, 0, 0, 1),
              ),
            ),
          )
          ..bindPipeline(ctx.createRenderPipeline(fsv, fcopy))
          ..bindVertexBuffer(quad)
          ..bindTexture(
            fcopy.getUniformSlot('source_texture'),
            c1,
            sampler: gpu.SamplerOptions(),
          )
          ..draw(6);
        await _done(cb);
        return (await _readRgba8(c0), await _readRgba8(copyOut));
      }

      final (d0, d1) = await frame(true);
      final (r0, r1) = await frame(false);
      var differ0 = 0, differ1 = 0, covered = 0;
      for (var i = 0; i < d0.length; i += 4) {
        if (d0[i] != r0[i] || d0[i + 1] != r0[i + 1] || d0[i + 2] != r0[i + 2])
          differ0++;
        if (d1[i] != r1[i]) differ1++;
        if (d0[i] != 0 || d0[i + 1] != 0 || d0[i + 2] != 0) covered++;
      }
      final ok = differ0 == 0 && differ1 == 0 && covered > 500;
      log(
        'SMOKE mrt replay ${ok ? 'ok' : 'WRONG'} (RGBA8 + '
        '${mixed ? 'R32F' : 'RGBA32F'} + depth, 2 draws with uniforms 256 '
        'bytes apart, recorded then replayed into a fresh pass: '
        '$differ0/$differ1 of 4096 px differ in target 0/1, $covered covered)'
        '${mixed ? '' : ' (not claimed by this engine)'}',
      );
      if (mixed) allOk &= ok;
    } else {
      log('SMOKE mrt replay: not on this engine (no retained draws)');
    }
  }

  // 3. A direct texture write (feature 16), drawn and read back.
  Future<void> directWrite() async {
    if (fs.mcsmDirectTextureWrites) {
      final t = ctx.createTexture(
        gpu.StorageMode.hostVisible,
        4,
        4,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
      )!;
      final texel = Uint8List(64);
      for (var i = 0; i < 64; i += 4) {
        texel.setAll(i, [77, 33, 200, 255]);
      }
      final wrote = fs.mcsmWriteTextureDirect(t, ByteData.sublistView(texel));
      final out = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
      final cb = ctx.createCommandBuffer();
      final fsv = baseShaderLibrary['FullscreenVertex']!;
      final fcopy = baseShaderLibrary['CopyFragment']!;
      cb.createRenderPass(
          gpu.RenderTarget.singleColor(
            gpu.ColorAttachment(texture: out, clearValue: Vector4(0, 0, 0, 1)),
          ),
        )
        ..bindPipeline(ctx.createRenderPipeline(fsv, fcopy))
        ..bindVertexBuffer(quad)
        ..bindTexture(
          fcopy.getUniformSlot('source_texture'),
          t,
          sampler: gpu.SamplerOptions(),
        )
        ..draw(6);
      await _done(cb);
      final r = await _readRgba8(out);
      final ok = wrote && _near(_px(r, 64, 32, 32), [77, 33, 200, 255]);
      log(
        'SMOKE direct texture write ${ok ? 'ok' : 'WRONG'} '
        '(written: $wrote) ${_px(r, 64, 32, 32)}',
      );
      allOk &= ok;
    } else {
      log(
        'SMOKE direct texture write: not on this engine or backend (uploads the usual way)',
      );
    }
  }

  // 4. Viewport arrays (feature 256). One instanced draw into four tiles
  // must give the same bytes as four draws with the viewport of one tile
  // each.
  Future<void> viewportArrays() async {
    allOk &= await _viewportArrays(log, ctx, rt);
  }
}

Future<bool> _viewportArrays(
  void Function(String) log,
  gpu.GpuContext ctx,
  gpu.Texture Function(gpu.PixelFormat) rt,
) async {
  final supported = fs.mcsmViewportArrays;
  final lib = await fs.loadShaderLibraryAsync(
    await bundles.resolveShaderBundleKey('smoke', package: 'gpu_smoke'),
  );
  if (lib == null) return false;
  final v = lib['SmokeTilesVertex']!, f = lib['SmokeTilesFragment']!;
  final layout = gpu.VertexLayout(
    buffers: [
      gpu.VertexBuffer(
        strideInBytes: 8,
        attributes: [
          gpu.VertexAttribute(
            name: 'position',
            format: gpu.VertexFormat.float32x2,
          ),
        ],
      ),
      gpu.VertexBuffer(
        strideInBytes: 28,
        stepMode: gpu.VertexStepMode.instance,
        attributes: [
          gpu.VertexAttribute(
            name: 'offset',
            format: gpu.VertexFormat.float32x2,
          ),
          gpu.VertexAttribute(
            name: 'color',
            format: gpu.VertexFormat.float32x4,
            offsetInBytes: 8,
          ),
          gpu.VertexAttribute(
            name: 'tile',
            format: gpu.VertexFormat.float32,
            offsetInBytes: 24,
          ),
        ],
      ),
    ],
  );
  final pipeline = ctx.createRenderPipeline(v, f, vertexLayout: layout);
  // A thin slanted triangle with edges that cross pixel centres at odd
  // places.
  final tri = gpu.BufferView(
    ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList([-0.93, -0.71, 0.87, -0.97, 0.13, 0.94]),
      ),
    ),
    offsetInBytes: 0,
    lengthInBytes: 24,
  );
  final inst = Float32List(4 * 7);
  final colors = [
    [1.0, 0.25, 0.0, 1.0],
    [0.0, 0.8, 0.3, 1.0],
    [0.2, 0.1, 0.9, 1.0],
    [0.7, 0.7, 0.1, 1.0],
  ];
  for (var i = 0; i < 4; i++) {
    inst.setAll(7 * i, [0.03 * i, -0.02 * i, ...colors[i], i.toDouble()]);
  }
  final instances = ctx.createDeviceBufferWithCopy(ByteData.sublistView(inst));
  // The instances of the per-tile draws use viewport 0, since each draw has
  // one viewport. An index past the viewport count of a pipeline is
  // undefined on Vulkan, where the shader writes gl_ViewportIndex itself.
  final instOne = Float32List.fromList(inst);
  for (var i = 0; i < 4; i++) {
    instOne[7 * i + 6] = 0;
  }
  final instancesOne = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(instOne),
  );
  final scale = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(Float32List.fromList([0.9, 0, 0, 0])),
  );
  final tiles = [
    for (var i = 0; i < 4; i++)
      gpu.Viewport(
        x: (i % 2) * 32 + 1,
        y: (i ~/ 2) * 32 + 1,
        width: 30,
        height: 30,
      ),
  ];
  final scissors = [
    for (final t in tiles)
      gpu.Scissor(x: t.x, y: t.y, width: t.width, height: t.height),
  ];
  gpu.RenderPass begin(gpu.CommandBuffer cb, gpu.Texture t) =>
      cb.createRenderPass(
          gpu.RenderTarget.singleColor(
            gpu.ColorAttachment(texture: t, clearValue: Vector4(0, 0, 0, 1)),
          ),
        )
        ..bindPipeline(pipeline)
        ..bindVertexBuffer(tri)
        ..bindUniform(
          v.getUniformSlot('FrameInfo'),
          gpu.BufferView(scale, offsetInBytes: 0, lengthInBytes: 16),
        );
  // A has one draw per tile, each with its own viewport and scissor.
  final a = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
  var cb = ctx.createCommandBuffer();
  final pa = begin(cb, a);
  for (var i = 0; i < 4; i++) {
    pa
      ..setViewport(tiles[i])
      ..setScissor(scissors[i])
      ..bindVertexBuffer(
        gpu.BufferView(instancesOne, offsetInBytes: 28 * i, lengthInBytes: 28),
        slot: 1,
      )
      ..draw(3);
  }
  await _done(cb);
  if (!supported) {
    // The per-tile path of this backend must still work.
    final ra = await _readRgba8(a);
    var n = [0, 0, 0, 0];
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final i = (y * 64 + x) * 4;
        if (ra[i] != 0 || ra[i + 1] != 0 || ra[i + 2] != 0) {
          n[(y ~/ 32) * 2 + x ~/ 32]++;
        }
      }
    }
    final ok = n.every((c) => c > 100);
    log(
      'SMOKE viewport arrays: not on this engine or backend (casters draw '
      'per tile; per-tile draws ${ok ? 'ok' : 'WRONG'}: ${n.join('/')})',
    );
    return ok;
  }
  // B has one instanced draw of four instances, each into its tile.
  final b = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
  cb = ctx.createCommandBuffer();
  final pb = begin(cb, b);
  final set = fs.mcsmSetViewports(pb, tiles, scissors: scissors);
  pb
    ..bindVertexBuffer(
      gpu.BufferView(instances, offsetInBytes: 0, lengthInBytes: 28 * 4),
      slot: 1,
    )
    ..draw(3, instanceCount: 4);
  // A later draw without them goes back to one viewport over the whole
  // target. It draws nothing here and must not fail.
  fs.mcsmSetViewports(pb, const []);
  await _done(cb);
  final ra = await _readRgba8(a), rb = await _readRgba8(b);
  var differ = 0, covered = 0;
  for (var i = 0; i < ra.length; i += 4) {
    if (ra[i] != 0 || ra[i + 1] != 0 || ra[i + 2] != 0) covered++;
    for (var k = 0; k < 4; k++) {
      if (ra[i + k] != rb[i + k]) {
        differ++;
        break;
      }
    }
  }
  final ok = set && differ == 0 && covered > 400;
  // The coverage of each per tile, a quadrant, to see the tiles of the draws.
  String perTile(Uint8List px) {
    final n = [0, 0, 0, 0];
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final i = (y * 64 + x) * 4;
        if (px[i] != 0 || px[i + 1] != 0 || px[i + 2] != 0) {
          n[(y ~/ 32) * 2 + x ~/ 32]++;
        }
      }
    }
    return n.join('/');
  }

  log(
    'SMOKE viewport arrays ${ok ? 'ok' : 'WRONG'} (set: $set; 4 tiles: '
    'one instanced draw vs one draw per tile: $differ of ${ra.length ~/ 4} '
    'pixels differ, $covered covered; per tile ${perTile(ra)} vs ${perTile(rb)})',
  );
  return ok;
}
