// mcsm9 checks: what S2's frame needs from the engine (Metal and Vulkan):
//
// - a 12,288-byte uniform block (impellerc's limit is per block there);
// - a storage buffer read in a fragment shader;
// - 2D array textures (uploaded per layer, sampled by layer, rendered into
//   a layer) and 3D textures (uploaded per slice, read per slice);
// - the added formats as targets (R11G11B10 float, RGBA16 unorm, RGBA16
//   float, D16, D32 float) and a 2x MSAA D16 target read per sample later;
// - a compute pass: storage buffers in and out, a uniform, an RGBA8 storage
//   image and a uint 3D storage image, read afterwards by render passes;
// - indirect draws and dispatches, texture views, per-frame array uploads,
//   sampler state, copies and mip generation, vertex formats and step
//   rates, layered passes and cube arrays.
//
// Each check prints a SMOKE line; the result is false when a check fails on
// an engine that claims S2's features (bit 2048).
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

part 'mcsm9_compute.dart';
part 'mcsm9_more.dart';
part 'mcsm9_targets.dart';
part 'mcsm9_texel.dart';
part 'mcsm9_views.dart';

/// What every check uses: the context, the S2 bundle, a quad.
class _S2 {
  _S2(this.ctx, this.lib, this.quad, this.log);

  final gpu.GpuContext ctx;
  final gpu.ShaderLibrary lib;
  final gpu.BufferView quad;
  final void Function(String) log;

  gpu.Shader shader(String name) => lib[name]!;

  gpu.Texture rgba8(int size) => ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    size,
    size,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
  );

  gpu.BufferView floats(List<double> values) {
    final buffer = ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(Float32List.fromList(values)),
    );
    return gpu.BufferView(
      buffer,
      offsetInBytes: 0,
      lengthInBytes: values.length * 4,
    );
  }

  /// Draws the quad into [target] with [fragment], after [bind].
  Future<bool> draw(
    gpu.Texture target,
    String fragment,
    void Function(gpu.RenderPass, gpu.Shader) bind, {
    String vertex = 'S2QuadVertex',
  }) {
    final f = shader(fragment);
    final pipeline = ctx.createRenderPipeline(shader(vertex), f);
    final cb = ctx.createCommandBuffer();
    final pass = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
      ),
    );
    pass
      ..bindPipeline(pipeline)
      ..bindVertexBuffer(quad);
    bind(pass, f);
    pass.draw(6);
    return done(cb);
  }
}

Future<bool> done(gpu.CommandBuffer cb) {
  final c = Completer<bool>();
  cb.submit(completionCallback: c.complete);
  return c.future;
}

Future<List<int>> centre(gpu.Texture t) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImage(t.asImage(), ui.Offset.zero, ui.Paint());
  final picture = recorder.endRecording();
  final image = await picture.toImage(t.width, t.height);
  picture.dispose();
  final bytes = (await image.toByteData())!;
  image.dispose();
  final i = ((t.height ~/ 2) * t.width + t.width ~/ 2) * 4;
  return bytes.buffer.asUint8List(bytes.offsetInBytes + i, 4).toList();
}

bool near(List<int> a, List<int> b, [int tolerance = 2]) {
  for (var i = 0; i < 4; i++) {
    if ((a[i] - b[i]).abs() > tolerance) return false;
  }
  return true;
}

/// Runs the checks; true when all pass or the engine lacks S2's features.
Future<bool> mcsm9Checks(void Function(String) log) async {
  if (!gpu.mcsmEngineSupportsS2) {
    log('SMOKE mcsm9 not on this engine or backend (no feature 2048)');
    return true;
  }
  final ByteData bytes;
  try {
    bytes = await rootBundle.load('s2_generated/s2smoke.shaderbundle');
  } catch (_) {
    log(
      'SMOKE mcsm9 FAILED: no S2 shader bundle (built by the engine impellerc)',
    );
    return false;
  }
  final lib = await gpu.ShaderLibrary.fromBytes(bytes);
  if (lib == null) {
    log('SMOKE mcsm9 FAILED: the S2 shader bundle did not load');
    return false;
  }
  final ctx = gpu.gpuContext;
  final s2 = _S2(
    ctx,
    lib,
    // Two triangles covering the target.
    _quad(ctx),
    log,
  );
  var ok = true;
  Future<void> check(String name, Future<String?> Function() run) async {
    String? failure;
    try {
      failure = await run();
    } catch (e) {
      failure = 'threw $e';
    }
    log('SMOKE mcsm9 $name ${failure == null ? 'ok' : 'FAILED: $failure'}');
    ok &= failure == null;
  }

  await check('uniform block 65536 bytes', () => _bigUbo(s2));
  await check('storage buffer in a fragment shader', () => _storage(s2));
  await check('2D array texture', () => _array(s2));
  await check('render into an array layer', () => _arrayTarget(s2));
  await check('3D texture', () => _volume(s2));
  await check('formats as targets', () => _formats(s2));
  await check('2x MSAA D16 read per sample', () => _msaaDepth(s2));
  await check('compute pass', () => _compute(s2));
  await check('indirect dispatch and draw', () => _indirect(s2));
  await check('texture views (a mip level, an array layer)', () => _views(s2));
  await check(
    'per-frame array upload (two layers, one command buffer)',
    () => _arrayUpload(s2),
  );
  await check(
    'sampler state (compare, border, LOD clamps, mirror clamp)',
    () => _samplers(s2),
  );
  await check(
    'copies between mips and slices, to buffers; mip generation',
    () => _copies(s2),
  );
  await check(
    'vertex formats (half, unorm8) and step rates',
    () => _vertexFormats(s2),
  );
  await check('layered pass (gl_Layer) and cube arrays', () => _layered(s2));
  await check(
    'texel buffers, storage texel buffers, atomics',
    () => _texelBuffers(s2),
  );
  await check(
    'storage image formats (RGBA16 unorm, RGBA32UI 3D, RGBA16F)',
    () => _storageFormats(s2),
  );
  await check(
    'IEEE arithmetic (NaN, Inf; -0 + 0 reported) without SPIR-V or Metal fast '
    'math',
    () => _metalOptions(s2),
  );
  await check(
    'compute-written vertex and indexed indirect buffers',
    () => _computeBuffers(s2),
  );
  await check(
    'base instance, clip distance, invariant position',
    () => _drawParameters(s2),
  );
  await check(
    'textures and samplers declared apart (and compare)',
    () => _separateSamplers(s2),
  );
  await check('BC3 array 1392x1288, three layers', () => _bc3Array(s2));
  return ok;
}

gpu.BufferView _quad(gpu.GpuContext ctx) {
  final buffer = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(
      Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
    ),
  );
  return gpu.BufferView(buffer, offsetInBytes: 0, lengthInBytes: 48);
}

Future<String?> _bigUbo(_S2 s2) async {
  final rows = List<double>.filled(4096 * 4, 0);
  rows.setAll(4000 * 4, [0.2, 0.4, 0, 1]);
  rows.setAll(5 * 4, [0.1, 0, 0.6, 0]);
  final target = s2.rgba8(16);
  await s2.draw(target, 'S2BigUboFragment', (p, f) {
    p.bindUniform(f.getUniformSlot('LightData'), s2.floats(rows));
  });
  final c = await centre(target);
  return near(c, [77, 102, 153, 255])
      ? null
      : 'got $c, want [77, 102, 153, 255]';
}

Future<String?> _storage(_S2 s2) async {
  final rows = [
    for (var i = 0; i < 8; i++) ...[i / 8, 0.5, 1 - i / 8, 1.0],
  ];
  final target = s2.rgba8(16);
  await s2.draw(target, 'S2StorageFragment', (p, f) {
    p.bindStorageBuffer(f.getStorageBufferSlot('Cascades'), s2.floats(rows));
  });
  final c = await centre(target);
  // rows[3] = (0.375, 0.5, 0.625, 1).
  return near(c, [96, 128, 159, 255])
      ? null
      : 'got $c, want [96, 128, 159, 255]';
}
