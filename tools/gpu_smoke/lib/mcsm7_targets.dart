part of 'mcsm7.dart';

extension _Targets on _Smoke {
  // 2. Two targets of different formats in one pass, then the R32F one
  // copied into RGBA8 to read it.
  Future<void> mixedTargets() async {
    final mixed = fs.mcsmMixedColorAttachmentFormats;
    final c0 = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final c1 = rt(
      mixed ? gpu.PixelFormat.r32Float : gpu.PixelFormat.r32g32b32a32Float,
    );
    final copyOut = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final mrtPipeline = ctx.createRenderPipeline(
      vInst,
      fMrt,
      vertexLayout: layout,
    );
    final one = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([0, 0, 0.25, 0.5, 0.75, 1])),
    );
    final big = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([1, 0, 0, 0])),
    );
    var cb = ctx.createCommandBuffer();
    final p = cb.createRenderPass(
      gpu.RenderTarget(
        colorAttachments: [
          gpu.ColorAttachment(texture: c0, clearValue: Vector4(0, 0, 0, 1)),
          gpu.ColorAttachment(texture: c1, clearValue: Vector4.zero()),
        ],
      ),
    );
    p.setColorBlendEnable(false, colorAttachmentIndex: 1);
    p
      ..bindPipeline(mrtPipeline)
      ..bindVertexBuffer(quad)
      ..bindVertexBuffer(
        gpu.BufferView(one, offsetInBytes: 0, lengthInBytes: 24),
        slot: 1,
      )
      ..bindUniform(
        vInst.getUniformSlot('FrameInfo'),
        gpu.BufferView(big, offsetInBytes: 0, lengthInBytes: 16),
      )
      ..draw(6);
    await _done(cb);
    cb = ctx.createCommandBuffer();
    final copy = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: copyOut, clearValue: Vector4(0, 0, 0, 1)),
      ),
    );
    final fsv = baseShaderLibrary['FullscreenVertex']!;
    final fcopy = baseShaderLibrary['CopyFragment']!;
    copy
      ..bindPipeline(ctx.createRenderPipeline(fsv, fcopy))
      ..bindVertexBuffer(quad)
      ..bindTexture(
        fcopy.getUniformSlot('source_texture'),
        c1,
        sampler: gpu.SamplerOptions(),
      )
      ..draw(6);
    await _done(cb);
    final r0 = await _readRgba8(c0), r1 = await _readRgba8(copyOut);
    // Target 0: the colour; target 1: g · 4 = 2.0, saturated by the copy
    // into RGBA8 (r = 255): a second target that was never written stays 0.
    final ok0 = _near(_px(r0, 64, 32, 32), [64, 128, 191, 255]);
    final ok1 = _near(_px(r1, 64, 32, 32).sublist(0, 1) + [0, 0, 0], [
      255,
      0,
      0,
      0,
    ]);
    final claimed = mixed; // Metal with the mixed-format pipelines (mcsm6+)
    log(
      'SMOKE mrt ${ok0 && ok1 ? 'ok' : 'WRONG'} (RGBA8 + '
      '${mixed ? 'R32F' : 'RGBA32F'} in one pass) '
      'target0 ${_px(r0, 64, 32, 32)} target1->rgba8 ${_px(r1, 64, 32, 32)}'
      '${claimed ? '' : ' (not claimed by this engine)'}',
    );
    if (claimed) allOk &= ok0 && ok1;
  }

  // 2b. A G-buffer pass: two targets (RGBA8 + a float) and a depth
  // attachment with the depth test, as the single G-buffer pass that will
  // replace the depth prepass and the occlusion pass writes them. Two
  // overlapping quads, the nearer drawn first: where they overlap both
  // targets keep the nearer one.
  Future<void> gBuffer() async {
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
    final pipeline = ctx.createRenderPipeline(vG, fMrt, vertexLayout: gLayout);
    final c0 = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final c1 = rt(
      mixed ? gpu.PixelFormat.r32Float : gpu.PixelFormat.r32g32b32a32Float,
    );
    final depth = ctx.createTexture(
      gpu.StorageMode.deviceTransient,
      64,
      64,
      format: ctx.defaultDepthStencilFormat,
      enableRenderTargetUsage: true,
    )!;
    final copyOut = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    // Near (z 0.2): blue with g 0.125 (→ 0.5 in target 1), left; far (z 0.6):
    // g 0.25 (→ 1.0), right; they overlap in the middle.
    final quads = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList([
          -0.25, 0, 0, 0.125, 1, 1, 0.2, //
          0.25, 0, 1, 0.25, 0, 1, 0.6, //
        ]),
      ),
    );
    final half = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([0.5, 0, 0, 0])),
    );
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
        gpu.BufferView(half, offsetInBytes: 0, lengthInBytes: 16),
      )
      ..draw(6, instanceCount: 2);
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
    final r0 = await _readRgba8(c0), r1 = await _readRgba8(copyOut);
    // Columns: 20 near only, 32 both (near wins), 44 far only.
    final ok =
        _near(_px(r0, 64, 20, 32), [0, 32, 255, 255]) &&
        _near(_px(r0, 64, 32, 32), [0, 32, 255, 255]) &&
        _near(_px(r0, 64, 44, 32), [255, 64, 0, 255]) &&
        (_px(r1, 64, 32, 32)[0] - 128).abs() <= 2 &&
        _px(r1, 64, 44, 32)[0] >= 253 &&
        _px(r1, 64, 4, 4)[0] == 0;
    log(
      'SMOKE gbuffer ${ok ? 'ok' : 'WRONG'} (RGBA8 + '
      '${mixed ? 'R32F' : 'RGBA32F'} + depth, depth test, instanced) '
      'target0 ${[_px(r0, 64, 20, 32), _px(r0, 64, 32, 32), _px(r0, 64, 44, 32)]} '
      'target1->rgba8 ${[_px(r1, 64, 32, 32)[0], _px(r1, 64, 44, 32)[0]]}'
      '${mixed ? '' : ' (not claimed by this engine)'}',
    );
    if (mixed) allOk &= ok;
  }

  // 2c. Pass reuse (mcsm8): the same colour targets in passes that differ in
  // load actions and depth targets must each get their own load, clear and
  // depth (Vulkan caches a render pass and framebuffer per target).
  Future<void> passReuse() async {
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
    final pipeline = ctx.createRenderPipeline(vG, fMrt, vertexLayout: gLayout);
    final c0 = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final c1 = rt(
      mixed ? gpu.PixelFormat.r32Float : gpu.PixelFormat.r32g32b32a32Float,
    );
    gpu.Texture depthTexture() => ctx.createTexture(
      gpu.StorageMode.devicePrivate,
      64,
      64,
      format: ctx.defaultDepthStencilFormat,
      enableRenderTargetUsage: true,
    )!;
    final depthA = depthTexture(), depthB = depthTexture();
    final quads = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList([
          -0.25, 0, 0, 0.125, 1, 1, 0.2, //
          0.25, 0, 1, 0.25, 0, 1, 0.6, //
        ]),
      ),
    );
    final half = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([0.5, 0, 0, 0])),
    );
    Future<void> pass({
      required bool loadColor,
      required Vector4 clear,
      required gpu.Texture depth,
      required bool loadDepth,
      required double depthClear,
      required bool draw,
    }) async {
      final cb = ctx.createCommandBuffer();
      final load = loadColor ? gpu.LoadAction.load : gpu.LoadAction.clear;
      final p = cb.createRenderPass(
        gpu.RenderTarget(
          colorAttachments: [
            gpu.ColorAttachment(
              texture: c0,
              loadAction: load,
              clearValue: clear,
            ),
            gpu.ColorAttachment(
              texture: c1,
              loadAction: load,
              clearValue: Vector4.zero(),
            ),
          ],
          depthStencilAttachment: gpu.DepthStencilAttachment(
            texture: depth,
            depthLoadAction: loadDepth
                ? gpu.LoadAction.load
                : gpu.LoadAction.clear,
            depthStoreAction: gpu.StoreAction.store,
            depthClearValue: depthClear,
          ),
        ),
      );
      p.setColorBlendEnable(false, colorAttachmentIndex: 1);
      if (draw) {
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
            gpu.BufferView(half, offsetInBytes: 0, lengthInBytes: 16),
          )
          ..draw(6, instanceCount: 2);
      }
      await _done(cb);
    }

    // Red over depth 0.1; then loaded, both quads (z 0.2, 0.6) fail the
    // loaded depth: still red (a stale clear would give black and quads).
    await pass(
      loadColor: false,
      clear: Vector4(1, 0, 0, 1),
      depth: depthA,
      loadDepth: false,
      depthClear: 0.1,
      draw: false,
    );
    await pass(
      loadColor: true,
      clear: Vector4(0, 0, 0, 1),
      depth: depthA,
      loadDepth: true,
      depthClear: 1.0,
      draw: true,
    );
    final r1 = await _readRgba8(c0);
    // Cleared to black over a second depth target cleared to 1.0: both
    // quads; then loaded with nothing drawn: kept.
    await pass(
      loadColor: false,
      clear: Vector4(0, 0, 0, 1),
      depth: depthB,
      loadDepth: false,
      depthClear: 1.0,
      draw: true,
    );
    await pass(
      loadColor: true,
      clear: Vector4(0, 1, 0, 1),
      depth: depthB,
      loadDepth: true,
      depthClear: 1.0,
      draw: false,
    );
    final r2 = await _readRgba8(c0);
    final ok =
        _near(_px(r1, 64, 20, 32), [255, 0, 0, 255]) &&
        _near(_px(r1, 64, 44, 32), [255, 0, 0, 255]) &&
        _near(_px(r2, 64, 20, 32), [0, 32, 255, 255]) &&
        _near(_px(r2, 64, 44, 32), [255, 64, 0, 255]) &&
        _near(_px(r2, 64, 4, 4), [0, 0, 0, 255]);
    log(
      'SMOKE pass reuse ${ok ? 'ok' : 'WRONG'} (one target: clear, load '
      'over a loaded depth, clear over another depth, load) '
      '${[_px(r1, 64, 20, 32), _px(r1, 64, 44, 32), _px(r2, 64, 20, 32), _px(r2, 64, 44, 32), _px(r2, 64, 4, 4)]}'
      '${mixed ? '' : ' (not claimed by this engine)'}',
    );
    if (mixed) allOk &= ok;
  }
}
