// The smallest app on the patched engine. It opens a window, clears one
// frame through Flutter GPU and shows that frame.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

void main() => runApp(const SampleApp());

/// The colour of the cleared frame.
final clearColour = Vector4(0.06, 0.42, 0.45, 1);

class SampleApp extends StatefulWidget {
  const SampleApp({super.key});

  @override
  State<SampleApp> createState() => _SampleAppState();
}

class _SampleAppState extends State<SampleApp> {
  ui.Image? _frame;

  @override
  void initState() {
    super.initState();
    unawaited(_clear(256, 256).then((i) => setState(() => _frame = i)));
  }

  @override
  Widget build(BuildContext context) =>
      Center(child: RawImage(image: _frame, fit: BoxFit.contain));
}

/// Clears a [width] by [height] texture to [clearColour] in one render pass.
/// Returns the texture as an image.
Future<ui.Image> _clear(int width, int height) async {
  final ctx = gpu.gpuContext;
  final target = ctx.createTexture(
    gpu.StorageMode.devicePrivate,
    width,
    height,
    format: gpu.PixelFormat.r8g8b8a8UNormInt,
    enableRenderTargetUsage: true,
    enableShaderReadUsage: true,
  );
  final cb = ctx.createCommandBuffer();
  cb.createRenderPass(
    gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(texture: target, clearValue: clearColour),
    ),
  );
  final done = Completer<bool>();
  cb.submit(completionCallback: done.complete);
  if (!await done.future) throw StateError('the clear pass failed on the GPU');
  return target.asImage();
}
