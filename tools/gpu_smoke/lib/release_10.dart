// The checks of engine release 10, for passes that pull their vertices from
// storage buffers.
//
// - A vertex stage with no inputs, its vertices read from a storage buffer
//   by vertex index.
// - The same storage buffer bound to the vertex and the pixel stage, with a
//   second one in the pixel stage beside a uniform block. Metal can crash in
//   setFragmentBuffer here.
// - A four-channel unsigned texel buffer in a pixel stage.
// - In release_10_more.dart, resources that a pixel stage declares but does
//   not read, bindings changed and restored between draws, leaf indirect
//   draws and an sRGB view of a UNORM target. Metal reflects unread resources
// without an index. Binding them can crash the driver in
//   setFragmentBuffer and setFragmentTexture.
//
// Each check prints a SMOKE line and runs where the earlier ones survived.
// The result is false when one fails.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'release_10_more.dart';

/// Runs the checks of release 10 with [log] for SMOKE lines. Returns true when
/// all pass.
Future<bool> release10Checks(void Function(String) log) async {
  if (!gpu.mcsmEngine10) {
    log('SMOKE release 10 not on this engine or backend (no feature 4096)');
    return true;
  }
  final ctx = gpu.gpuContext;
  final bytes = await rootBundle.load(
    'features_generated/features.shaderbundle',
  );
  final lib = await gpu.ShaderLibrary.fromBytes(bytes);
  if (lib == null) {
    log('SMOKE release 10: no shader bundle of the features');
    return false;
  }
  var ok = true;
  Future<void> check(String name, Future<String?> Function() run) async {
    String? problem;
    try {
      problem = await run();
    } on Object catch (e) {
      problem = '$e';
    }
    log('SMOKE release 10 $name: ${problem ?? 'ok'}');
    if (problem != null) ok = false;
  }

  gpu.BufferView view(ByteData data) {
    final b = ctx.createDeviceBufferWithCopy(data);
    return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: b.sizeInBytes);
  }

  // A triangle over the whole target, then the colour of row 4, (0.25, 0.5,
  // 0.75, 1), which the pixel stage reads.
  final rows = view(
    ByteData.sublistView(
      Float32List.fromList([
        -1, -1, 0, 1, //
        3, -1, 0, 1, //
        -1, 3, 0, 1, //
        0, 0, 0, 0, //
        0.25, 0.5, 0.75, 1,
      ]),
    ),
  );
  final words = view(ByteData.sublistView(Uint32List.fromList([0, 51, 0, 0])));
  final scale = view(ByteData.sublistView(Float32List.fromList([1, 1, 1, 1])));

  Future<List<int>> drawPulled(String vertex, {bool input = false}) async {
    final target = ctx.createTexture(
      gpu.StorageMode.devicePrivate,
      16,
      16,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
    );
    final vs = lib[vertex]!, fs = lib['PullFragment']!;
    final pipeline = ctx.createRenderPipeline(
      vs,
      fs,
      vertexLayout: input
          ? const gpu.VertexLayout(
              buffers: [
                gpu.VertexBuffer(
                  strideInBytes: 4,
                  attributes: [
                    gpu.VertexAttribute(
                      name: 'pull_index',
                      format: gpu.VertexFormat.float32,
                    ),
                  ],
                ),
              ],
            )
          : const gpu.VertexLayout(buffers: []),
    );
    final cb = ctx.createCommandBuffer();
    final pass = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
      ),
    );
    pass.bindPipeline(pipeline);
    if (input) {
      pass.bindVertexBuffer(
        view(ByteData.sublistView(Float32List.fromList([0, 1, 2]))),
      );
    }
    pass
      ..bindStorageBuffer(vs.getStorageBufferSlot('RawPullRows'), rows)
      ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullRows'), rows)
      ..bindStorageBuffer(fs.getStorageBufferSlot('RawPullWords'), words)
      ..bindUniform(fs.getUniformSlot('PullScale'), scale)
      ..draw(3);
    return release10Centre(cb, target);
  }

  // R = 0.25 + 51/255 = 0.45 → 115, G 0.5 → 128 and B 0.75 → 191.
  bool right(List<int> c) =>
      (c[0] - 115).abs() <= 1 &&
      (c[1] - 128).abs() <= 1 &&
      (c[2] - 191).abs() <= 1;

  await check('pixel-stage storage beside the vertex stage\'s', () async {
    final c = await drawPulled('PullInputVertex', input: true);
    return right(c) ? null : 'got $c, want [115, 128, 191, 255]';
  });
  await check('vertex stage without inputs', () async {
    final c = await drawPulled('PullVertex');
    return right(c) ? null : 'got $c, want [115, 128, 191, 255]';
  });
  await check('RGBA32UI texel buffer in a pixel stage', () async {
    final target = ctx.createTexture(
      gpu.StorageMode.devicePrivate,
      16,
      16,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
    );
    final texels = view(
      ByteData.sublistView(
        Uint32List.fromList([
          0, 0, 0, 0, 0, 0, 0, 0, //
          40, 80, 120, 255,
        ]),
      ),
    );
    final vs = lib['PullInputVertex']!, fs = lib['Texel4Fragment']!;
    final pipeline = ctx.createRenderPipeline(
      vs,
      fs,
      vertexLayout: const gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: 4,
            attributes: [
              gpu.VertexAttribute(
                name: 'pull_index',
                format: gpu.VertexFormat.float32,
              ),
            ],
          ),
        ],
      ),
    );
    final cb = ctx.createCommandBuffer();
    final pass = cb.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
      ),
    );
    pass
      ..bindPipeline(pipeline)
      ..bindVertexBuffer(
        view(ByteData.sublistView(Float32List.fromList([0, 1, 2]))),
      )
      ..bindStorageBuffer(vs.getStorageBufferSlot('RawPullRows'), rows)
      ..bindTexelBuffer(
        fs.getTexelBufferSlot('words'),
        texels,
        gpu.PixelFormat.r32g32b32a32UInt,
      )
      ..draw(3);
    final c = await release10Centre(cb, target);
    return (c[0] - 40).abs() <= 1 &&
            (c[1] - 80).abs() <= 1 &&
            (c[2] - 120).abs() <= 1
        ? null
        : 'got $c, want [40, 80, 120, 255]';
  });
  await release10MoreChecks(lib, check);
  return ok;
}

/// Submits [cb], waits for the GPU and reads the RGBA8 centre pixel of
/// [target] through a picture, as the checks of release 9 do. GLES gives
/// zeros for the own read of a raw texture.
Future<List<int>> release10Centre(
  gpu.CommandBuffer cb,
  gpu.Texture target,
) async {
  final done = Completer<bool>();
  cb.submit(completionCallback: done.complete);
  await done.future;
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImage(target.asImage(), ui.Offset.zero, ui.Paint());
  final picture = recorder.endRecording();
  final image = await picture.toImage(target.width, target.height);
  picture.dispose();
  final bytes = (await image.toByteData())!;
  image.dispose();
  final i = ((target.height ~/ 2) * target.width + target.width ~/ 2) * 4;
  return bytes.buffer.asUint8List(bytes.offsetInBytes + i, 4).toList();
}
