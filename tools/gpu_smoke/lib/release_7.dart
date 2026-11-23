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

part 'release_7_cost.dart';
part 'release_7_instancing.dart';
part 'release_7_replays.dart';
part 'release_7_targets.dart';

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

Future<bool> release7Checks(void Function(String) log) async {
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
  final vInst = lib['SmokeInstancedVertex']!;
  final fColor = lib['SmokeColorFragment']!;
  final fMrt = lib['SmokeMrtFragment']!;
  final fTex = lib['SmokeTexturedFragment']!;
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
        strideInBytes: 24,
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
        ],
      ),
    ],
  );
  final colorPipeline = ctx.createRenderPipeline(
    vInst,
    fColor,
    vertexLayout: layout,
  );
  final quad = gpu.BufferView(
    ctx.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
      ),
    ),
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
  final instances = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(instData),
  );
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

  final s = _Smoke(
    log,
    ctx,
    lib,
    vInst,
    fMrt,
    fTex,
    layout,
    colorPipeline,
    quad,
    instances,
    scale,
    rt,
  );
  await s.instancing();
  await s.firstInstance();
  await s.mixedTargets();
  await s.gBuffer();
  await s.passReuse();
  await s.replays();
  await s.directWrite();
  await s.viewportArrays();
  await s.passCost();
  await s.drawCost();
  return s.allOk;
}

/// What every check shares: the context, the smoke shaders, the instanced
/// quad and the render-target maker.
class _Smoke {
  _Smoke(
    this.log,
    this.ctx,
    this.lib,
    this.vInst,
    this.fMrt,
    this.fTex,
    this.layout,
    this.colorPipeline,
    this.quad,
    this.instances,
    this.scale,
    this.rt,
  );
  final void Function(String) log;
  final gpu.GpuContext ctx;
  final gpu.ShaderLibrary lib;
  final gpu.Shader vInst;
  final gpu.Shader fMrt;
  final gpu.Shader fTex;
  final gpu.VertexLayout layout;
  final gpu.RenderPipeline colorPipeline;
  final gpu.BufferView quad;
  final gpu.DeviceBuffer instances;
  final gpu.DeviceBuffer scale;
  final gpu.Texture Function(gpu.PixelFormat) rt;
  var allOk = true;
}
