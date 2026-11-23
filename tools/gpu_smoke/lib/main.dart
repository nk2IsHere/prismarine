// gpu_smoke checks that Flutter GPU works on this engine and platform. It
// renders a texture through the ScreenCopy of prismarine_scene into an
// offscreen target, reads it back, checks the pixel,
// times draws and binds, prints one SMOKE line per result and exits. The exit
// code is 0 when the pixel matches.
//
//   flutter run -d <linux|windows|macos> --release [--local-engine…]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:prismarine_scene/prismarine_scene.dart' show ScreenCopy;
import 'package:vector_math/vector_math.dart';

import 'release_10.dart';
import 'release_11.dart';
import 'release_7.dart';
import 'release_9.dart';
import 'release_prismarine1.dart';

// Each SMOKE line goes to stdout and also to the file of GPU_SMOKE_OUT, since a
// Windows GUI app has no console. Lines are ASCII and the file reads the same
// in any code page. On Windows with a log file nothing goes to stdout. The
// stdout of a GUI process has no reader. Flushing it before the exit holds the
// process for minutes.
final _out = Platform.environment['GPU_SMOKE_OUT'];
final _useStdout = !(Platform.isWindows && _out != null);

void _log(String line) {
  if (_useStdout) stdout.writeln(line);
  if (_out != null) {
    File(_out!).writeAsStringSync('$line\n', mode: FileMode.append);
  }
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
  // The last line marks the end of the run. The app exits right after it.
  _log('SMOKE done, exit code $code');
  if (_useStdout) {
    await stdout.flush().timeout(const Duration(seconds: 2), onTimeout: () {});
  }
  exit(code);
}

Future<int> _smoke() async {
  _log(
    'SMOKE platform ${Platform.operatingSystem} '
    '${Platform.version.split(' ').last}',
  );
  final startup = Stopwatch()..start();
  await ScreenCopy.load();
  final ctx = gpu.gpuContext;
  final vertex = ScreenCopy.loaded!.vertex;
  final fragment = ScreenCopy.loaded!.fragment;
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
    texel.setAll(i, [10, 200, 30, 255]);
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

  gpu.RenderPass pass(gpu.CommandBuffer cb) => cb.createRenderPass(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: target, clearValue: Vector4(0, 0, 0, 1)),
    ),
  );

  // The render check.
  var cb = ctx.createCommandBuffer();
  var p = pass(cb)
    ..bindPipeline(pipeline)
    ..bindVertexBuffer(vb)
    ..bindTexture(slot, source, sampler: sampler)
    ..draw(6);
  // Waits for the GPU. GLES runs the pass on the raster thread later.
  final done = Completer<bool>();
  cb.submit(completionCallback: (ok) => done.complete(ok));
  _log(
    'SMOKE submit ${await done.future ? 'completed' : 'FAILED'}, '
    'first draw done ${startup.elapsedMilliseconds} ms after init began '
    '(shader and pipeline compiles included)',
  );
  // Read back through a Picture. On GLES (Linux, Windows/ANGLE)
  // `asImage().toByteData()` straight on a Flutter GPU texture returns zeros,
  // while drawing it into a picture and reading that gives the pixels.
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImage(target.asImage(), ui.Offset.zero, ui.Paint());
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  picture.dispose();
  final bytes = (await image.toByteData())!;
  image.dispose();
  final c = bytes.buffer.asUint8List(
    bytes.offsetInBytes + (32 * 64 + 32) * 4,
    4,
  );
  var ok = c[0] == 10 && c[1] == 200 && c[2] == 30 && c[3] == 255;
  final firstEmpty = !ok && c.every((v) => v == 0);
  if (ok || !firstEmpty) {
    _log(
      'SMOKE pixel ${c.toList()} ${ok ? 'ok' : 'WRONG (want [10, 200, 30, 255])'}',
    );
  }

  // Timings in µs of CPU per draw, the best of 7 rounds of 2,000.
  double time(
    void Function(gpu.RenderPass) setup,
    void Function(gpu.RenderPass) draw,
  ) {
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
  final bind = time(
    (p) {
      p.bindPipeline(pipeline);
      p.bindVertexBuffer(vb);
    },
    (p) {
      p.bindTexture(slot, source, sampler: sampler);
      p.draw(6);
    },
  );
  _log(
    'SMOKE draw ${bare.toStringAsFixed(3)} us, '
    'draw+texture bind ${bind.toStringAsFixed(3)} us',
  );
  final release7 = await release7Checks(_log);
  final release9 = await release9Checks(_log);
  final release10 = await release10Checks(_log);
  final release11 = await release11Checks(_log);
  final releasePrismarine1 = releasePrismarine1Checks(_log);
  if (firstEmpty) {
    // ANGLE on Windows gives an empty first readback on the stock engine too,
    // while later readbacks work. The same target is read again without
    // drawing first, which separates a read that came too early from a draw
    // that was lost. Then it renders and reads again.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final r0 = ui.PictureRecorder();
    ui.Canvas(r0).drawImage(target.asImage(), ui.Offset.zero, ui.Paint());
    final pic0 = r0.endRecording();
    final img0 = await pic0.toImage(64, 64);
    pic0.dispose();
    final b0 = (await img0.toByteData())!;
    img0.dispose();
    final c0 = b0.buffer.asUint8List(b0.offsetInBytes + (32 * 64 + 32) * 4, 4);
    _log(
      'SMOKE pixel re-read without drawing, 200 ms later: ${c0.toList()} '
      '${c0[1] == 200 ? '(the draw was there: the first read came too early)' : '(still empty: the draw was lost)'}',
    );
    cb = ctx.createCommandBuffer();
    pass(cb)
      ..bindPipeline(pipeline)
      ..bindVertexBuffer(vb)
      ..bindTexture(slot, source, sampler: sampler)
      ..draw(6);
    final again = Completer<bool>();
    cb.submit(completionCallback: (ok) => again.complete(ok));
    await again.future;
    final r = ui.PictureRecorder();
    ui.Canvas(r).drawImage(target.asImage(), ui.Offset.zero, ui.Paint());
    final pic = r.endRecording();
    final img = await pic.toImage(64, 64);
    pic.dispose();
    final b2 = (await img.toByteData())!;
    img.dispose();
    final c2 = b2.buffer.asUint8List(b2.offsetInBytes + (32 * 64 + 32) * 4, 4);
    ok = c2[0] == 10 && c2[1] == 200 && c2[2] == 30 && c2[3] == 255;
    _log(
      'SMOKE pixel ${c2.toList()} ${ok ? 'ok' : 'WRONG (want [10, 200, 30, 255])'} '
      '(the first readback came back empty; this is a second render and readback)',
    );
  }
  return ok &&
          release7 &&
          release9 &&
          release10 &&
          release11 &&
          releasePrismarine1
      ? 0
      : 2;
}
