// mcsm7 checks: what the next perf round builds on, proven on this engine.
//
// - instancing: per-instance attributes, and a draw of a sub-range of the
//   instances by binding the instance buffer at an offset (a base instance),
//   and the same through draw(firstInstance:) (flutter_gpu G7, engine bit
//   512), non-indexed and indexed;
// - a G-buffer pass: RGBA8 + a float target + depth with the depth test;
// - viewport arrays (Metal; elsewhere casters draw per tile);
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
  log('SMOKE mcsm features $features backend ${fs.mcsmBackend ?? 'unknown'}');
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

  // 1b. Draws from a first instance (G7; one leaf call on the mcsm7 engine,
  // bound again at the offset elsewhere): the whole instance buffer bound,
  // instances 2..3 drawn, and 1..3 indexed, each against the same instances
  // through an offset binding. The bytes must match.
  {
    Future<Uint8List> one(void Function(gpu.RenderPass p) body) async {
      final t = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
      final cb = ctx.createCommandBuffer();
      final p = cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: t, clearValue: Vector4(0, 0, 0, 1)),
      ));
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
    final viaFirst = await one((p) => p
      ..bindVertexBuffer(all, slot: 1)
      ..draw(6, instanceCount: 2, firstInstance: 2));
    final viaOffset = await one((p) => p
      ..bindVertexBuffer(from(2), slot: 1)
      ..draw(6, instanceCount: 2));
    final idxFirst = await one((p) => p
      ..bindVertexBuffer(all, slot: 1)
      ..bindIndexBuffer(indices, gpu.IndexType.int16)
      ..drawIndexed(6, instanceCount: 3, firstInstance: 1));
    final idxOffset = await one((p) => p
      ..bindVertexBuffer(from(1), slot: 1)
      ..bindIndexBuffer(indices, gpu.IndexType.int16)
      ..drawIndexed(6, instanceCount: 3));
    int differ(Uint8List a, Uint8List b) {
      var n = 0;
      for (var i = 0; i < a.length; i += 4) {
        if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) n++;
      }
      return n;
    }

    final d1 = differ(viaFirst, viaOffset), d2 = differ(idxFirst, idxOffset);
    // Instance 1 (top right, green) only in the indexed pair.
    final ok = d1 == 0 &&
        d2 == 0 &&
        _near(_px(viaFirst, 64, 16, 48), [0, 0, 255, 255]) &&
        _near(_px(viaFirst, 64, 48, 16), [0, 0, 0, 255]) &&
        _near(_px(idxFirst, 64, 48, 16), [0, 255, 0, 255]) &&
        _near(_px(idxFirst, 64, 16, 16), [0, 0, 0, 255]);
    log('SMOKE first instance ${ok ? 'ok' : 'WRONG'} '
        '(${fs.mcsmFirstInstanceDraws ? 'engine draw' : 'bound again at the offset'}; '
        'draw 2..3: $d1 px differ from an offset binding, '
        'indexed 1..3: $d2 px differ)');
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
        'target0 ${_px(r0, 64, 32, 32)} target1->rgba8 ${_px(r1, 64, 32, 32)}'
        '${claimed ? '' : ' (not claimed by this engine)'}');
    if (claimed) allOk &= ok0 && ok1;
  }

  // 2b. A G-buffer pass: two targets (RGBA8 + a float) and a depth
  // attachment with the depth test, as the single G-buffer pass that will
  // replace the depth prepass and the occlusion pass writes them. Two
  // overlapping quads, the nearer drawn first: where they overlap both
  // targets keep the nearer one.
  {
    final mixed = fs.mcsmMixedColorAttachmentFormats;
    final vG = lib['SmokeGbufferVertex']!;
    final gLayout = gpu.VertexLayout(buffers: [
      gpu.VertexBuffer(
        strideInBytes: 8,
        attributes: [
          gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x2),
        ],
      ),
      gpu.VertexBuffer(
        strideInBytes: 28,
        stepMode: gpu.VertexStepMode.instance,
        attributes: [
          gpu.VertexAttribute(name: 'offset', format: gpu.VertexFormat.float32x2),
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
    ]);
    final pipeline = ctx.createRenderPipeline(vG, fMrt, vertexLayout: gLayout);
    final c0 = rt(gpu.PixelFormat.r8g8b8a8UNormInt);
    final c1 = rt(mixed ? gpu.PixelFormat.r32Float : gpu.PixelFormat.r32g32b32a32Float);
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
    final quads = ctx.createDeviceBufferWithCopy(ByteData.sublistView(
      Float32List.fromList([
        -0.25, 0, 0, 0.125, 1, 1, 0.2, //
        0.25, 0, 1, 0.25, 0, 1, 0.6, //
      ]),
    ));
    final half = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList([0.5, 0, 0, 0])),
    );
    var cb = ctx.createCommandBuffer();
    final p = cb.createRenderPass(gpu.RenderTarget(
      colorAttachments: [
        gpu.ColorAttachment(texture: c0, clearValue: Vector4(0, 0, 0, 1)),
        gpu.ColorAttachment(texture: c1, clearValue: Vector4.zero()),
      ],
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depth,
        depthClearValue: 1.0,
      ),
    ));
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
    cb.createRenderPass(gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: copyOut, clearValue: Vector4(0, 0, 0, 1)),
    ))
      ..bindPipeline(ctx.createRenderPipeline(fsv, fcopy))
      ..bindVertexBuffer(quad)
      ..bindTexture(fcopy.getUniformSlot('source_texture'), c1,
          sampler: gpu.SamplerOptions())
      ..draw(6);
    await _done(cb);
    final r0 = await _readRgba8(c0), r1 = await _readRgba8(copyOut);
    // Columns: 20 near only, 32 both (near wins), 44 far only.
    final ok = _near(_px(r0, 64, 20, 32), [0, 32, 255, 255]) &&
        _near(_px(r0, 64, 32, 32), [0, 32, 255, 255]) &&
        _near(_px(r0, 64, 44, 32), [255, 64, 0, 255]) &&
        (_px(r1, 64, 32, 32)[0] - 128).abs() <= 2 &&
        _px(r1, 64, 44, 32)[0] >= 253 &&
        _px(r1, 64, 4, 4)[0] == 0;
    log('SMOKE gbuffer ${ok ? 'ok' : 'WRONG'} (RGBA8 + '
        '${mixed ? 'R32F' : 'RGBA32F'} + depth, depth test, instanced) '
        'target0 ${[_px(r0, 64, 20, 32), _px(r0, 64, 32, 32), _px(r0, 64, 44, 32)]} '
        'target1->rgba8 ${[_px(r1, 64, 32, 32)[0], _px(r1, 64, 44, 32)[0]]}'
        '${mixed ? '' : ' (not claimed by this engine)'}');
    if (mixed) allOk &= ok;
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
    log('SMOKE direct texture write: not on this engine or backend (uploads the usual way)');
  }

  // 4. Viewport arrays (feature 256): one instanced draw into four tiles
  // must give the same bytes as four draws with one tile's viewport each.
  allOk &= await _viewportArrays(log, ctx, rt);

  // 5. Scene-like draws: µs per draw (CPU), best of 7 rounds of 2,000.
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
  final layout = gpu.VertexLayout(buffers: [
    gpu.VertexBuffer(
      strideInBytes: 8,
      attributes: [
        gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x2),
      ],
    ),
    gpu.VertexBuffer(
      strideInBytes: 28,
      stepMode: gpu.VertexStepMode.instance,
      attributes: [
        gpu.VertexAttribute(name: 'offset', format: gpu.VertexFormat.float32x2),
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
  ]);
  final pipeline = ctx.createRenderPipeline(v, f, vertexLayout: layout);
  // A thin slanted triangle: edges that cross pixel centres at odd places.
  final tri = gpu.BufferView(
    ctx.createDeviceBufferWithCopy(ByteData.sublistView(
      Float32List.fromList([-0.93, -0.71, 0.87, -0.97, 0.13, 0.94]),
    )),
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
  // The per-tile draws' instances name viewport 0 (each draw has one
  // viewport): an index past a pipeline's viewport count is undefined on
  // Vulkan, where the shader writes gl_ViewportIndex itself.
  final instOne = Float32List.fromList(inst);
  for (var i = 0; i < 4; i++) {
    instOne[7 * i + 6] = 0;
  }
  final instancesOne =
      ctx.createDeviceBufferWithCopy(ByteData.sublistView(instOne));
  final scale = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(Float32List.fromList([0.9, 0, 0, 0])),
  );
  final tiles = [
    for (var i = 0; i < 4; i++)
      gpu.Viewport(x: (i % 2) * 32 + 1, y: (i ~/ 2) * 32 + 1, width: 30, height: 30),
  ];
  final scissors = [
    for (final t in tiles)
      gpu.Scissor(x: t.x, y: t.y, width: t.width, height: t.height),
  ];
  gpu.RenderPass begin(gpu.CommandBuffer cb, gpu.Texture t) =>
      cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: t, clearValue: Vector4(0, 0, 0, 1)),
      ))
        ..bindPipeline(pipeline)
        ..bindVertexBuffer(tri)
        ..bindUniform(
          v.getUniformSlot('FrameInfo'),
          gpu.BufferView(scale, offsetInBytes: 0, lengthInBytes: 16),
        );
  // A: one draw per tile, each with its own viewport and scissor.
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
    // The per-tile path casters take on this backend still has to work.
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
    log('SMOKE viewport arrays: not on this engine or backend (casters draw '
        'per tile; per-tile draws ${ok ? 'ok' : 'WRONG'}: ${n.join('/')})');
    return ok;
  }
  // B: one instanced draw, four instances, each into its tile.
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
  // A later draw without them goes back to one viewport (the whole target):
  // nothing here, but it must not fail.
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
  // Coverage per tile (quadrant) of each, to see which draws landed where.
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
  log('SMOKE viewport arrays ${ok ? 'ok' : 'WRONG'} (set: $set; 4 tiles: '
      'one instanced draw vs one draw per tile: $differ of ${ra.length ~/ 4} '
      'pixels differ, $covered covered; per tile ${perTile(ra)} vs ${perTile(rb)})');
  return ok;
}
