// mcsm7 checks: what the next perf round builds on, proven on this engine.
//
// - instancing: per-instance attributes, and a draw of a sub-range of the
//   instances by binding the instance buffer at an offset (a base instance);
// - multiple render targets of different formats in one pass (RGBA8 + R32F,
//   as a G-buffer writes a colour and a depth);
// - several passes in turn on one command buffer (feature 64);
// - a direct texture write (feature 16);
// - a scene-like per-draw cost (two vertex buffers, two uniform blocks,
//   three textures, cull and winding changes).
//
// Each check prints a SMOKE line; the result is false when a check that the
// engine claims to support fails.
import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/gpu.dart' as bundles;
import 'package:flutter_scene/scene.dart' show baseShaderLibrary;
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as fs;
import 'package:vector_math/vector_math.dart';

Future<Uint8List> _readRgba8(gpu.Texture t) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImage(t.asImage(), ui.Offset.zero, ui.Paint());
  final picture = recorder.endRecording();
  final image = await picture.toImage(t.width, t.height);
  picture.dispose();
  final bytes = (await image.toByteData())!;
  image.dispose();
  return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

List<int> _px(Uint8List rgba, int w, int x, int y) =>
    rgba.sublist((y * w + x) * 4, (y * w + x) * 4 + 4).toList();

bool _near(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    if ((a[i] - b[i]).abs() > 2) return false;
  }
  return true;
}

Future<bool> _done(gpu.CommandBuffer cb) {
  final done = Completer<bool>();
  cb.submit(completionCallback: done.complete);
  return done.future;
}

Future<bool> mcsm7Checks(void Function(String) log) async {
  final ctx = gpu.gpuContext;
  final features = fs.mcsmEngineFeatures;
  log('SMOKE mcsm features $features');
  final lib = await fs.loadShaderLibraryAsync(
    await bundles.resolveShaderBundleKey('smoke', package: 'gpu_smoke'),
  );
  if (lib == null) {
    log('SMOKE mcsm7 FAILED: no smoke shader bundle');
    return false;
  }
  var allOk = true;
  final vInst = lib['SmokeInstancedVertex']!;
  final fColor = lib['SmokeColorFragment']!;
  final fMrt = lib['SmokeMrtFragment']!;
  final fTex = lib['SmokeTexturedFragment']!;
  final layout = gpu.VertexLayout(buffers: [
    gpu.VertexBuffer(
      strideInBytes: 8,
      attributes: [
        gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x2),
      ],
    ),
    gpu.VertexBuffer(
      strideInBytes: 24,
      stepMode: gpu.VertexStepMode.instance,
      attributes: [
        gpu.VertexAttribute(name: 'offset', format: gpu.VertexFormat.float32x2),
        gpu.VertexAttribute(
          name: 'color',
          format: gpu.VertexFormat.float32x4,
          offsetInBytes: 8,
        ),
      ],
    ),
  ]);
  final colorPipeline = ctx.createRenderPipeline(vInst, fColor, vertexLayout: layout);
  final quad = gpu.BufferView(
    ctx.createDeviceBufferWithCopy(ByteData.sublistView(
      Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
    )),
    offsetInBytes: 0,
    lengthInBytes: 48,
  );
  // Four instances: one per quadrant, each its own colour.
  final instData = Float32List.fromList([
    -0.5, 0.5, 1, 0, 0, 1, //
    0.5, 0.5, 0, 1, 0, 1, //
    -0.5, -0.5, 0, 0, 1, 1, //
    0.5, -0.5, 1, 1, 0, 1, //
  ]);
  final instances = ctx.createDeviceBufferWithCopy(ByteData.sublistView(instData));
  final scale = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(Float32List.fromList([0.25, 0, 0, 0])),
  );
  gpu.Texture rt(gpu.PixelFormat f) => ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    64,
    64,
    format: f,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  )!;

  // 1. Instancing: all four, then the last two again through an offset
  // binding (a base instance of 2) into a second target.
  {
    final a = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final b = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final cb = ctx.createCommandBuffer();
    void draw(gpu.Texture target, int first, int count) {
      final p = cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
      ));
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
    final shared = fs.mcsmPassesPerCommandBuffer;
    draw(a, 0, 4);
    if (shared) {
      draw(b, 2, 2);
      await _done(cb);
    } else {
      await _done(cb);
      final cb2 = ctx.createCommandBuffer();
      final p = cb2.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: b, clearValue: Vector4(0, 0, 0, 1)),
      ));
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
    final ra = await _readRgba8(a), rb = await _readRgba8(b);
    // Quadrant centres (y down in the image): top-left red, top-right
    // green, bottom-left blue, bottom-right yellow; b has only the bottom.
    final ok =
        _near(_px(ra, 64, 16, 16), [255, 0, 0, 255]) &&
        _near(_px(ra, 64, 48, 16), [0, 255, 0, 255]) &&
        _near(_px(ra, 64, 16, 48), [0, 0, 255, 255]) &&
        _near(_px(ra, 64, 48, 48), [255, 255, 0, 255]) &&
        _near(_px(ra, 64, 32, 32), [0, 0, 0, 255]) &&
        _near(_px(rb, 64, 16, 16), [0, 0, 0, 255]) &&
        _near(_px(rb, 64, 16, 48), [0, 0, 255, 255]) &&
        _near(_px(rb, 64, 48, 48), [255, 255, 0, 255]);
    log('SMOKE instancing ${ok ? 'ok' : 'WRONG'} '
        '(4 instances; 2 from an offset binding; '
        '${shared ? 'both passes on one command buffer' : 'one command buffer per pass'}) '
        '${[_px(ra, 64, 16, 16), _px(ra, 64, 48, 16), _px(ra, 64, 16, 48), _px(ra, 64, 48, 48), _px(rb, 64, 16, 48)]}');
    allOk &= ok;
  }

  // 2. Two targets of different formats in one pass, then the R32F one
  // copied into RGBA8 to read it.
  {
    final mixed = fs.mcsmMixedColorAttachmentFormats;
    final c0 = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final c1 = rt(mixed ? gpu.PixelFormat.r32Float : gpu.PixelFormat.r32g32b32a32Float);
    final copyOut = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final mrtPipeline = ctx.createRenderPipeline(vInst, fMrt, vertexLayout: layout);
    final one = ctx.createDeviceBufferWithCopy(ByteData.sublistView(
      Float32List.fromList([0, 0, 0.25, 0.5, 0.75, 1]),
    ));
    final big = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([1, 0, 0, 0])),
    );
    var cb = ctx.createCommandBuffer();
    final p = cb.createRenderPass(gpu.RenderTarget(
      colorAttachments: [
        gpu.ColorAttachment(texture: c0, clearValue: Vector4(0, 0, 0, 1)),
        gpu.ColorAttachment(texture: c1, clearValue: Vector4.zero()),
      ],
    ));
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
    final copy = cb.createRenderPass(gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: copyOut, clearValue: Vector4(0, 0, 0, 1)),
    ));
    final fsv = baseShaderLibrary['FullscreenVertex']!;
    final fcopy = baseShaderLibrary['CopyFragment']!;
    copy
      ..bindPipeline(ctx.createRenderPipeline(fsv, fcopy))
      ..bindVertexBuffer(quad)
      ..bindTexture(fcopy.getUniformSlot('source_texture'), c1,
          sampler: gpu.SamplerOptions())
      ..draw(6);
    await _done(cb);
    final r0 = await _readRgba8(c0), r1 = await _readRgba8(copyOut);
    // Target 0: the colour; target 1: g · 4 = 2.0, saturated by the copy
    // into RGBA8 (r = 255): a second target that was never written stays 0.
    final ok0 = _near(_px(r0, 64, 32, 32), [64, 128, 191, 255]);
    final ok1 = _near(_px(r1, 64, 32, 32).sublist(0, 1) + [0, 0, 0], [255, 0, 0, 0]);
    final claimed = mixed;  // Metal with the mixed-format pipelines (mcsm6+)
    log('SMOKE mrt ${ok0 && ok1 ? 'ok' : 'WRONG'} (RGBA8 + '
        '${mixed ? 'R32F' : 'RGBA32F'} in one pass) '
        'target0 ${_px(r0, 64, 32, 32)} target1→rgba8 ${_px(r1, 64, 32, 32)}'
        '${claimed ? '' : ' (not claimed by this engine)'}');
    if (claimed) allOk &= ok0 && ok1;
  }

  // 3. A direct texture write (feature 16), drawn and read back.
  if (fs.mcsmDirectTextureWrites) {
    final t = ctx.createTexture(gpu.StorageMode.hostVisible, 4, 4,
        format: gpu.PixelFormat.r8g8b8a8UNormInt)!;
    final texel = Uint8List(64);
    for (var i = 0; i < 64; i += 4) {
      texel.setAll(i, [77, 33, 200, 255]);
    }
    final wrote = fs.mcsmWriteTextureDirect(t, ByteData.sublistView(texel));
    final out = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final cb = ctx.createCommandBuffer();
    final fsv = baseShaderLibrary['FullscreenVertex']!;
    final fcopy = baseShaderLibrary['CopyFragment']!;
    cb.createRenderPass(gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: out, clearValue: Vector4(0, 0, 0, 1)),
    ))
      ..bindPipeline(ctx.createRenderPipeline(fsv, fcopy))
      ..bindVertexBuffer(quad)
      ..bindTexture(fcopy.getUniformSlot('source_texture'), t,
          sampler: gpu.SamplerOptions())
      ..draw(6);
    await _done(cb);
    final r = await _readRgba8(out);
    final ok = wrote && _near(_px(r, 64, 32, 32), [77, 33, 200, 255]);
    log('SMOKE direct texture write ${ok ? 'ok' : 'WRONG'} '
        '(written: $wrote) ${_px(r, 64, 32, 32)}');
    allOk &= ok;
  } else {
    log('SMOKE direct texture write: not on this engine');
  }

  // 4. Scene-like draws: µs per draw (CPU), best of 7 rounds of 2,000.
  {
    final pipeline = ctx.createRenderPipeline(vInst, fTex, vertexLayout: layout);
    final geometry = [
      for (var i = 0; i < 8; i++)
        ctx.createDeviceBufferWithCopy(ByteData.sublistView(
          Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
        )),
    ];
    final blocks = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List(2000 * 64)),
    );
    gpu.Texture tex(int v) {
      final t = ctx.createTexture(gpu.StorageMode.hostVisible, 4, 4,
          format: gpu.PixelFormat.r8g8b8a8UNormInt)!;
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
      final p = cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
      ));
      final sw = Stopwatch()..start();
      p.bindPipeline(pipeline);
      for (var i = 0; i < 2000; i++) {
        p
          ..bindVertexBuffer(gpu.BufferView(
            geometry[i & 7],
            offsetInBytes: 0,
            lengthInBytes: 48,
          ))
          ..bindVertexBuffer(
            gpu.BufferView(instances, offsetInBytes: (i & 3) * 24, lengthInBytes: 24),
            slot: 1,
          )
          ..bindUniform(frame, gpu.BufferView(blocks, offsetInBytes: i * 256, lengthInBytes: 16))
          ..bindUniform(material, gpu.BufferView(blocks, offsetInBytes: i * 256 + 64, lengthInBytes: 16))
          ..bindTexture(a, maps[i & 7], sampler: sampler)
          ..bindTexture(b, shared, sampler: sampler)
          ..bindTexture(c, maps[(i >> 3) & 7], sampler: sampler)
          ..setCullMode((i & 1) == 0 ? gpu.CullMode.backFace : gpu.CullMode.none)
          ..setWindingOrder((i & 2) == 0 ? gpu.WindingOrder.clockwise : gpu.WindingOrder.counterClockwise)
          ..draw(6);
      }
      final us = sw.elapsedMicroseconds / 2000;
      cb.submit();
      if (r > 0 && us < best) best = us;
    }
    log('SMOKE scene-like draw ${best.toStringAsFixed(3)} us '
        '(2 vertex buffers, 2 uniform blocks, 3 textures, cull + winding per draw)');
  }
  return allOk;
}
