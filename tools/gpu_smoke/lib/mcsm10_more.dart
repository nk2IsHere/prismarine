// mcsm10 checks, continued (mcsm10.dart): resources a pixel stage declares
// but never reads, bindings changed and restored between draws, leaf
// indirect draws and an sRGB view of a UNORM target.
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'mcsm10.dart' show mcsm10Centre;

/// Runs the checks through [check] (which logs and records each result).
Future<void> mcsm10MoreChecks(
  gpu.ShaderLibrary lib,
  Future<void> Function(String, Future<String?> Function()) check,
) async {
  final ctx = gpu.gpuContext;
  gpu.BufferView view(TypedData data) {
    final b = ctx.createDeviceBufferWithCopy(ByteData.sublistView(data));
    return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: b.sizeInBytes);
  }

  // A triangle over the whole target, for the vertex stage.
  final triangle = view(
    Float32List.fromList([-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1]),
  );
  // Row 4 is the colour the pixel stage reads.
  gpu.BufferView colour(double r, double g, double b) =>
      view(Float32List.fromList([...List.filled(16, 0.0), r, g, b, 1]));
  final zeros = view(Uint32List(4));
  final unity = view(Float32List.fromList([1, 1, 1, 1]));
  final vs = lib['S2PullVertex']!;

  // An RGBA8 render target (on Vulkan, mutable to its sRGB twin).
  gpu.Texture target() => ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    16,
    16,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  );

  String? near(List<int> got, List<int> want, [int tolerance = 1]) {
    for (var i = 0; i < want.length; i++) {
      if ((got[i] - want[i]).abs() > tolerance) return 'got $got, want $want';
    }
    return null;
  }

  // Draws with [fragment]; [steps] binds the pixel stage's resources and
  // draws, once per step, in one pass.
  Future<List<int>> run(
    gpu.Shader fragment,
    List<void Function(gpu.RenderPass)> steps, {
    gpu.Texture? into,
    gpu.Texture? readBack,
  }) {
    final t = into ?? target();
    final pipeline = ctx.createRenderPipeline(
      vs,
      fragment,
      vertexLayout: const gpu.VertexLayout(buffers: []),
    );
    final cb = ctx.createCommandBuffer();
    final pass = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: t, clearValue: Vector4(0, 0, 0, 1)),
      ),
    );
    pass
      ..bindPipeline(pipeline)
      ..bindStorageBuffer(vs.getStorageBufferSlot('RawPullRows'), triangle);
    for (final step in steps) {
      step(pass);
    }
    return mcsm10Centre(cb, readBack ?? t);
  }

  final unusedFs = lib['S2PullUnusedFragment']!;
  await check('resources a pixel stage declares but never reads', () async {
    final c = await run(unusedFs, [
      (pass) => pass
        ..bindStorageBuffer(
          unusedFs.getStorageBufferSlot('RawPullRows'),
          colour(0.25, 0.5, 0.75),
        )
        ..bindStorageBuffer(
          unusedFs.getStorageBufferSlot('RawPullUnused'),
          zeros,
        )
        ..bindTexelBuffer(
          unusedFs.getTexelBufferSlot('unusedWords'),
          zeros,
          gpu.PixelFormat.r32g32b32a32UInt,
        )
        ..draw(3),
    ]);
    return near(c, [64, 128, 191, 255]);
  });

  final fs = lib['S2PullFragment']!;
  void Function(gpu.RenderPass) drawWith(gpu.BufferView rows) =>
      (pass) => pass
        ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullRows'), rows)
        ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullWords'), zeros)
        ..bindUniform(fs.getUniformSlot('PullScale'), unity)
        ..draw(3);
  final a = colour(1, 0, 0), b = colour(0, 0, 1);
  await check('a storage binding changed, then restored', () async {
    final changed = await run(fs, [drawWith(a), drawWith(b)]);
    final restored = await run(fs, [drawWith(a), drawWith(b), drawWith(a)]);
    final again = await run(fs, [drawWith(a), drawWith(a)]);
    return near(changed, [0, 0, 255, 255]) ??
        near(restored, [255, 0, 0, 255]) ??
        near(again, [255, 0, 0, 255]);
  });

  await check('leaf indirect draws', () async {
    if (!gpu.mcsmEngine10) return 'the engine reports no mcsm10 features';
    final args = view(Uint32List.fromList([3, 1, 0, 0, 3, 1, 0, 0]));
    final c = await run(fs, [
      (pass) => pass
        ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullRows'), a)
        ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullWords'), zeros)
        ..bindUniform(fs.getUniformSlot('PullScale'), unity)
        ..drawIndirect(
          gpu.BufferView(args.buffer, offsetInBytes: 0, lengthInBytes: 16),
        ),
      // The pipeline is cached on the pass now: this one is the leaf call.
      (pass) => pass
        ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullRows'), b)
        ..drawIndirect(
          gpu.BufferView(args.buffer, offsetInBytes: 16, lengthInBytes: 16),
        ),
    ]);
    return near(c, [0, 0, 255, 255]);
  });

  await check('an sRGB view of a UNORM target', () async {
    final t = target();
    final srgb = t.makeView(format: gpu.PixelFormat.r8g8b8a8UNormIntSRGB);
    final c = await run(
      fs,
      [drawWith(colour(0.25, 0.5, 0.75))],
      into: srgb,
      readBack: t,
    );
    // Linear 0.25, 0.5, 0.75 encoded as sRGB.
    return near(c, [137, 188, 226, 255], 2);
  });
}
