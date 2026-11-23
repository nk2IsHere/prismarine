// mcsm11 checks: command buffers and passes made again after their submit
// (flutter_gpu G15 over the engine's McsmDetach), and the VM's collection at
// the caller's idle point (mcsmGcIdle):
//
// - after a submit, the next command buffer is the same Dart object on a new
//   native one, and a pass made again draws as a new pass: a clear alone
//   leaves the clear colour (nothing of the draws before), a draw after it
//   the drawn colour;
// - an idle call with no minimum runs a young collection and says so.
//
// Each check prints a SMOKE line; the result is false when one fails.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' show baseShaderLibrary;
import 'package:vector_math/vector_math.dart';

/// Runs the mcsm11 checks with [log] for SMOKE lines; true when all pass.
Future<bool> mcsm11Checks(void Function(String) log) async {
  if (!gpu.mcsmGcIdleSupported) {
    log('SMOKE mcsm11 not on this engine (no McsmDetach)');
    return true;
  }
  final ctx = gpu.gpuContext;
  final vertex =
      (baseShaderLibrary['FullscreenVertex'] as Object) as gpu.Shader;
  final fragment = (baseShaderLibrary['CopyFragment'] as Object) as gpu.Shader;
  final pipeline = ctx.createRenderPipeline(vertex, fragment);
  final quad = ctx.createDeviceBufferWithCopy(
    ByteData.sublistView(
      Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
    ),
  );
  final vb = gpu.BufferView(quad, offsetInBytes: 0, lengthInBytes: 48);
  final source = ctx.createTexture(
    gpu.StorageMode.hostVisible,
    4,
    4,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
  )!;
  final texel = Uint8List(64);
  for (var i = 0; i < 64; i += 4) {
    texel.setAll(i, [200, 10, 30, 255]);
  }
  source.overwrite(ByteData.sublistView(texel));
  final target = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    64,
    64,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  )!;
  final slot = fragment.getUniformSlot('source_texture');
  final sampler = gpu.SamplerOptions();
  final renderTarget = gpu.RenderTarget.singleColor(
    gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 1, 1)),
  );

  Future<List<int>> run(gpu.CommandBuffer cb, {required bool draw}) async {
    final pass = cb.createRenderPass(renderTarget);
    if (draw) {
      pass
        ..bindPipeline(pipeline)
        ..bindVertexBuffer(vb)
        ..bindTexture(slot, source, sampler: sampler)
        ..draw(6);
    }
    final done = Completer<bool>();
    cb.submit(completionCallback: done.complete);
    await done.future;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImage(target.asImage(), ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final image = await picture.toImage(64, 64);
    picture.dispose();
    final bytes = (await image.toByteData())!;
    image.dispose();
    return bytes.buffer
        .asUint8List(bytes.offsetInBytes + (32 * 64 + 32) * 4, 4)
        .toList();
  }

  var ok = true;
  void say(String name, String? problem) {
    log('SMOKE mcsm11 $name: ${problem ?? 'ok'}');
    if (problem != null) ok = false;
  }

  bool same(List<int> a, List<int> b) =>
      a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
  const drawn = [200, 10, 30, 255], cleared = [0, 0, 255, 255];
  try {
    final first = ctx.createCommandBuffer();
    final a = await run(first, draw: true);
    final second = ctx.createCommandBuffer();
    final again = identical(first, second);
    final b = await run(second, draw: false);
    final c = await run(ctx.createCommandBuffer(), draw: true);
    say(
      'passes made again',
      !again
          ? 'the next command buffer is a new object'
          : !same(a, drawn)
          ? 'first draw $a, want $drawn'
          : !same(b, cleared)
          ? 'a clear alone on a pass made again left $b, want $cleared'
          : !same(c, drawn)
          ? 'a draw on a pass made again left $c, want $drawn'
          : null,
    );
  } on Object catch (e) {
    say('passes made again', '$e');
  }
  try {
    // No minimum: new space holds enough whatever it holds.
    final ran = gpu.mcsmGcIdle(0, 0, 0);
    say('idle collection', ran & 1 == 1 ? null : 'ran $ran, want bit 1');
  } on Object catch (e) {
    say('idle collection', '$e');
  }
  return ok;
}
