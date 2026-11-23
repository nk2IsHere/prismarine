part of 'release_7.dart';

extension _Instancing on _Smoke {
  // 1. Instancing with all four instances, then the last two again through
  // an offset binding, a base instance of 2, into a second target.
  Future<void> instancing() async {
    final a = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final b = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final cb = ctx.createCommandBuffer();
    void draw(gpu.Texture target, int first, int count) {
      final p = cb.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
        ),
      );
      p
        ..bindPipeline(colorPipeline)
        ..bindVertexBuffer(quad)
        ..bindVertexBuffer(
          gpu.BufferView(
            instances,
            offsetInBytes: first * 24,
            lengthInBytes: count * 24,
          ),
          slot: 1,
        )
        ..bindUniform(
          vInst.getUniformSlot('FrameInfo'),
          gpu.BufferView(scale, offsetInBytes: 0, lengthInBytes: 16),
        )
        ..draw(6, instanceCount: count);
    }

    // Two passes on one command buffer need feature 64 on Metal.
    final shared = fs.prismarinePassesPerCommandBuffer;
    draw(a, 0, 4);
    if (shared) {
      draw(b, 2, 2);
      await _done(cb);
    } else {
      await _done(cb);
      final cb2 = ctx.createCommandBuffer();
      final p = cb2.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(texture: b, clearValue: Vector4(0, 0, 0, 1)),
        ),
      );
      p
        ..bindPipeline(colorPipeline)
        ..bindVertexBuffer(quad)
        ..bindVertexBuffer(
          gpu.BufferView(instances, offsetInBytes: 48, lengthInBytes: 48),
          slot: 1,
        )
        ..bindUniform(
          vInst.getUniformSlot('FrameInfo'),
          gpu.BufferView(scale, offsetInBytes: 0, lengthInBytes: 16),
        )
        ..draw(6, instanceCount: 2);
      await _done(cb2);
    }
    final ra = await _readRgba8(a);
    var rb = await _readRgba8(b);
    if (_px(rb, 64, 16, 48).every((v) => v == 0)) {
      // An empty read on ANGLE reads the same target again later without a
      // draw.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      rb = await _readRgba8(b);
      log(
        'SMOKE instancing: target b read empty, re-read 200 ms later '
        'without drawing: ${_px(rb, 64, 16, 48)}',
      );
    }
    // The quadrant centres with y down in the image are red at the top left,
    // green at the top right, blue at the bottom left and yellow at the bottom
    // right. b has only the bottom.
    final ok =
        _near(_px(ra, 64, 16, 16), [255, 0, 0, 255]) &&
        _near(_px(ra, 64, 48, 16), [0, 255, 0, 255]) &&
        _near(_px(ra, 64, 16, 48), [0, 0, 255, 255]) &&
        _near(_px(ra, 64, 48, 48), [255, 255, 0, 255]) &&
        _near(_px(ra, 64, 32, 32), [0, 0, 0, 255]) &&
        _near(_px(rb, 64, 16, 16), [0, 0, 0, 255]) &&
        _near(_px(rb, 64, 16, 48), [0, 0, 255, 255]) &&
        _near(_px(rb, 64, 48, 48), [255, 255, 0, 255]);
    log(
      'SMOKE instancing ${ok ? 'ok' : 'WRONG'} '
      '(4 instances; 2 from an offset binding; '
      '${shared ? 'both passes on one command buffer' : 'one command buffer per pass'}) '
      '${[_px(ra, 64, 16, 16), _px(ra, 64, 48, 16), _px(ra, 64, 16, 48), _px(ra, 64, 48, 48), _px(rb, 64, 16, 48)]}',
    );
    allOk &= ok;
  }

  // 1b. Draws from a first instance (G7), one leaf call on engine release 7
  // and bound again at the offset elsewhere. The whole instance buffer is
  // bound, instances 2..3 are drawn and 1..3 indexed, each against the same
  // instances through an offset binding. The bytes must match.
  Future<void> firstInstance() async {
    Future<Uint8List> one(void Function(gpu.RenderPass p) body) async {
      final t = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
      final cb = ctx.createCommandBuffer();
      final p = cb.createRenderPass(
        gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(texture: t, clearValue: Vector4(0, 0, 0, 1)),
        ),
      );
      p
        ..bindPipeline(colorPipeline)
        ..bindVertexBuffer(quad)
        ..bindUniform(
          vInst.getUniformSlot('FrameInfo'),
          gpu.BufferView(scale, offsetInBytes: 0, lengthInBytes: 16),
        );
      body(p);
      await _done(cb);
      return _readRgba8(t);
    }

    final all = gpu.BufferView(instances, offsetInBytes: 0, lengthInBytes: 96);
    gpu.BufferView from(int first) => gpu.BufferView(
      instances,
      offsetInBytes: 24 * first,
      lengthInBytes: 96 - 24 * first,
    );
    final indices = gpu.BufferView(
      ctx.createDeviceBufferWithCopy(
        ByteData.sublistView(Uint16List.fromList([0, 1, 2, 3, 4, 5, 0, 0])),
      ),
      offsetInBytes: 0,
      lengthInBytes: 12,
    );
    final viaFirst = await one(
      (p) => p
        ..bindVertexBuffer(all, slot: 1)
        ..draw(6, instanceCount: 2, firstInstance: 2),
    );
    final viaOffset = await one(
      (p) => p
        ..bindVertexBuffer(from(2), slot: 1)
        ..draw(6, instanceCount: 2),
    );
    final idxFirst = await one(
      (p) => p
        ..bindVertexBuffer(all, slot: 1)
        ..bindIndexBuffer(indices, gpu.IndexType.int16)
        ..drawIndexed(6, instanceCount: 3, firstInstance: 1),
    );
    final idxOffset = await one(
      (p) => p
        ..bindVertexBuffer(from(1), slot: 1)
        ..bindIndexBuffer(indices, gpu.IndexType.int16)
        ..drawIndexed(6, instanceCount: 3),
    );
    int differ(Uint8List a, Uint8List b) {
      var n = 0;
      for (var i = 0; i < a.length; i += 4) {
        if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) n++;
      }
      return n;
    }

    final d1 = differ(viaFirst, viaOffset), d2 = differ(idxFirst, idxOffset);
    // Instance 1 (top right, green) only in the indexed pair.
    final ok =
        d1 == 0 &&
        d2 == 0 &&
        _near(_px(viaFirst, 64, 16, 48), [0, 0, 255, 255]) &&
        _near(_px(viaFirst, 64, 48, 16), [0, 0, 0, 255]) &&
        _near(_px(idxFirst, 64, 48, 16), [0, 255, 0, 255]) &&
        _near(_px(idxFirst, 64, 16, 16), [0, 0, 0, 255]);
    log(
      'SMOKE first instance ${ok ? 'ok' : 'WRONG'} '
      '(${fs.prismarineFirstInstanceDraws ? 'engine draw' : 'bound again at the offset'}; '
      'draw 2..3: $d1 px differ from an offset binding, '
      'indexed 1..3: $d2 px differ)',
    );
    allOk &= ok;
  }
}
