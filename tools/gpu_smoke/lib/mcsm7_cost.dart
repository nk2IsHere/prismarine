part of 'mcsm7.dart';

extension _Cost on _Smoke {
  // 4b. Per-pass CPU cost: a command buffer, one pass with one draw, a
  // submit (the look's post passes are like this), median of 200.
  Future<void> passCost() async {
    final target = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final times = <int, List<double>>{0: [], 1: [], 2: []};
    for (var i = 0; i < 200; i++) {
      final sw = Stopwatch()..start();
      final cb = ctx.createCommandBuffer();
      final t0 = sw.elapsedMicroseconds;
      cb.createRenderPass(
          gpu.RenderTarget.singleColor(
            gpu.ColorAttachment(
              texture: target,
              clearValue: Vector4(0, 0, 0, 1),
            ),
          ),
        )
        ..bindPipeline(colorPipeline)
        ..bindVertexBuffer(quad)
        ..bindVertexBuffer(
          gpu.BufferView(instances, offsetInBytes: 0, lengthInBytes: 24),
          slot: 1,
        )
        ..bindUniform(
          vInst.getUniformSlot('FrameInfo'),
          gpu.BufferView(scale, offsetInBytes: 0, lengthInBytes: 16),
        )
        ..draw(6);
      final t1 = sw.elapsedMicroseconds;
      cb.submit();
      final t2 = sw.elapsedMicroseconds;
      times[0]!.add(t0.toDouble());
      times[1]!.add((t1 - t0).toDouble());
      times[2]!.add((t2 - t1).toDouble());
    }
    double med(List<double> v) => (v..sort())[v.length ~/ 2];
    log(
      'SMOKE pass cost: command buffer ${med(times[0]!).toStringAsFixed(1)} us, '
      'pass + draw ${med(times[1]!).toStringAsFixed(1)} us, '
      'submit ${med(times[2]!).toStringAsFixed(1)} us (median of 200)',
    );
  }

  // 5. Scene-like draws: µs per draw (CPU), best of 7 rounds of 2,000.
  Future<void> drawCost() async {
    final pipeline = ctx.createRenderPipeline(
      vInst,
      fTex,
      vertexLayout: layout,
    );
    final geometry = [
      for (var i = 0; i < 8; i++)
        ctx.createDeviceBufferWithCopy(
          ByteData.sublistView(
            Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
          ),
        ),
    ];
    final blocks = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List(2000 * 64)),
    );
    gpu.Texture tex(int v) {
      final t = ctx.createTexture(
        gpu.StorageMode.hostVisible,
        4,
        4,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
      )!;
      t.overwrite(ByteData.sublistView(Uint8List(64)..fillRange(0, 64, v)));
      return t;
    }

    final maps = [for (var i = 0; i < 8; i++) tex(200 + i)];
    final shared = tex(255);
    final sampler = gpu.SamplerOptions();
    final frame = vInst.getUniformSlot('FrameInfo');
    final material = fTex.getUniformSlot('MaterialInfo');
    final a = fTex.getUniformSlot('map_a');
    final b = fTex.getUniformSlot('map_b');
    final c = fTex.getUniformSlot('map_c');
    final target = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    var best = double.infinity;
    // GPU_SMOKE_REPEAT=<n>: n rounds instead of 7 (for a profiler).
    final rounds =
        int.tryParse(io.Platform.environment['GPU_SMOKE_REPEAT'] ?? '') ?? 7;
    for (var r = 0; r < rounds; r++) {
      final cb = ctx.createCommandBuffer();
      final p = cb.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
        ),
      );
      final sw = Stopwatch()..start();
      p.bindPipeline(pipeline);
      for (var i = 0; i < 2000; i++) {
        p
          ..bindVertexBuffer(
            gpu.BufferView(
              geometry[i & 7],
              offsetInBytes: 0,
              lengthInBytes: 48,
            ),
          )
          ..bindVertexBuffer(
            gpu.BufferView(
              instances,
              offsetInBytes: (i & 3) * 24,
              lengthInBytes: 24,
            ),
            slot: 1,
          )
          ..bindUniform(
            frame,
            gpu.BufferView(blocks, offsetInBytes: i * 256, lengthInBytes: 16),
          )
          ..bindUniform(
            material,
            gpu.BufferView(
              blocks,
              offsetInBytes: i * 256 + 64,
              lengthInBytes: 16,
            ),
          )
          ..bindTexture(a, maps[i & 7], sampler: sampler)
          ..bindTexture(b, shared, sampler: sampler)
          ..bindTexture(c, maps[(i >> 3) & 7], sampler: sampler)
          ..setCullMode(
            (i & 1) == 0 ? gpu.CullMode.backFace : gpu.CullMode.none,
          )
          ..setWindingOrder(
            (i & 2) == 0
                ? gpu.WindingOrder.clockwise
                : gpu.WindingOrder.counterClockwise,
          )
          ..draw(6);
      }
      final us = sw.elapsedMicroseconds / 2000;
      cb.submit();
      if (r > 0 && us < best) best = us;
    }
    log(
      'SMOKE scene-like draw ${best.toStringAsFixed(3)} us '
      '(2 vertex buffers, 2 uniform blocks, 3 textures, cull + winding per draw)',
    );
  }
}
