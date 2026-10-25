// gpu_smoke: does Flutter GPU work on this engine and platform? Renders a
// texture through flutter_scene's base FullscreenVertex + CopyFragment into an
// offscreen target, reads it back, checks the pixel, times draws and binds,
// prints one SMOKE line per result and exits (code 0 when the pixel matches).
//
//   flutter run -d <linux|windows|macos> --release [--local-engine…]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' show Scene, baseShaderLibrary;
import 'package:vector_math/vector_math.dart';

import 'mcsm7.dart';

// Each SMOKE line goes to stdout and, when GPU_SMOKE_OUT names a file, to it
// too (a Windows GUI app has no console).
final _out = Platform.environment['GPU_SMOKE_OUT'];

void _log(String line) {
  stdout.writeln(line);
  if (_out != null) File(_out!).writeAsStringSync('$line\n', mode: FileMode.append);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  var code = 1;
  try {
    code = await _smoke();
  } catch (e, st) {
    _log('SMOKE error $e\n$st');
  }
  await stdout.flush();
  exit(code);
}

Future<int> _smoke() async {
  _log('SMOKE platform ${Platform.operatingSystem} '
      '${Platform.version.split(' ').last}');
  final startup = Stopwatch()..start();
  await Scene.initializeStaticResources();
  final ctx = gpu.gpuContext;
  final vertex = (baseShaderLibrary['FullscreenVertex'] as Object) as gpu.Shader;
  final fragment = (baseShaderLibrary['CopyFragment'] as Object) as gpu.Shader;
  final pipeline = ctx.createRenderPipeline(vertex, fragment);
  final quad = ctx.createDeviceBufferWithCopy(ByteData.sublistView(
      Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1])));
  final vb = gpu.BufferView(quad, offsetInBytes: 0, lengthInBytes: 48);
  final source = ctx.createTexture(gpu.StorageMode.hostVisible, 4, 4,
      format: gpu.PixelFormat.r8g8b8a8UNormInt)!;
  final texel = Uint8List(64);
  for (var i = 0; i < 64; i += 4) {
    texel.setAll(i, [10, 200, 30, 255]);
  }
  source.overwrite(ByteData.sublistView(texel));
  final target = ctx.createTexture(gpu.StorageMode.devicePrivate, 64, 64,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true)!;
  final slot = fragment.getUniformSlot('source_texture');
  final sampler = gpu.SamplerOptions();

  gpu.RenderPass pass(gpu.CommandBuffer cb) => cb.createRenderPass(
      gpu.RenderTarget.singleColor(gpu.ColorAttachment(
          texture: target, clearValue: Vector4(0, 0, 0, 1))));

  // The render check.
  var cb = ctx.createCommandBuffer();
  var p = pass(cb)
    ..bindPipeline(pipeline)
    ..bindVertexBuffer(vb)
    ..bindTexture(slot, source, sampler: sampler)
    ..draw(6);
  // Wait for the GPU (GLES runs the pass on the raster thread later).
  final done = Completer<bool>();
  cb.submit(completionCallback: (ok) => done.complete(ok));
  _log('SMOKE submit ${await done.future ? 'completed' : 'FAILED'}, '
      'first draw done ${startup.elapsedMilliseconds} ms after init began '
      '(shader and pipeline compiles included)');
  // Read back through a Picture, as the player's captures do: on GLES
  // (Linux, Windows/ANGLE) `asImage().toByteData()` straight on a Flutter GPU
  // texture returns zeros, while drawing it into a picture and reading that
  // gives the pixels.
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImage(target.asImage(), ui.Offset.zero, ui.Paint());
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  picture.dispose();
  final bytes = (await image.toByteData())!;
  image.dispose();
  final c = bytes.buffer.asUint8List(bytes.offsetInBytes + (32 * 64 + 32) * 4, 4);
  final ok = c[0] == 10 && c[1] == 200 && c[2] == 30 && c[3] == 255;
  _log('SMOKE pixel ${c.toList()} ${ok ? 'ok' : 'WRONG (want [10, 200, 30, 255])'}');

  // Timings (µs per draw, CPU, best of 7 rounds of 2,000).
  double time(void Function(gpu.RenderPass) setup, void Function(gpu.RenderPass) draw) {
    var best = double.infinity;
    for (var r = 0; r < 7; r++) {
      cb = ctx.createCommandBuffer();
      p = pass(cb);
      final sw = Stopwatch()..start();
      setup(p);
      for (var i = 0; i < 2000; i++) {
        draw(p);
      }
      final us = sw.elapsedMicroseconds / 2000;
      cb.submit();
      if (r > 0 && us < best) best = us;
    }
    return best;
  }

  final bare = time((p) {
    p.bindPipeline(pipeline);
    p.bindVertexBuffer(vb);
    p.bindTexture(slot, source, sampler: sampler);
  }, (p) => p.draw(6));
  final bind = time((p) {
    p.bindPipeline(pipeline);
    p.bindVertexBuffer(vb);
  }, (p) {
    p.bindTexture(slot, source, sampler: sampler);
    p.draw(6);
  });
  _log('SMOKE draw ${bare.toStringAsFixed(3)} us, '
      'draw+texture bind ${bind.toStringAsFixed(3)} us');
  final mcsm7 = await mcsm7Checks(_log);
  return ok && mcsm7 ? 0 : 2;
}
