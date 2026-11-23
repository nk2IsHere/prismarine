# prismarine_frame

prismarine_frame describes the work of a frame as plain data and moves it between isolates. A builder on one isolate
makes a `FramePlan` and a runner on another isolate records it on the GPU with
[prismarine_render](../prismarine_render/README.md). The plan holds no GPU objects. You can check and compare it without
a GPU. The details are on [the area page](../../docs/areas/frame.md).

## Usage

A `FramePlan` lists the render targets of the frame as `TargetSpec` values, its GPU buffers and its passes in order. A
`RenderPassPlan` has colour and depth attachments and its draws. A `DispatchPlan` is a compute dispatch. A `DrawPlan`
gives its vertex and pixel shaders by id and holds its geometry, its `DrawState`, its viewport and the `StageResources`
of each stage, which are the constant blocks, textures, samplers and storage buffers. Formats have the form of DXGI
names without their prefix, such as `R8G8B8A8_UNORM`.

A `FrameRole` is a constant block that a draw binds by its role, such as the block of the camera. The plan gives the
bytes of each role for the frame in `frameBlocks`. A draw that binds only roles and blocks that stay the same can stay
the same object from frame to frame.

`PlanWriter.write` turns a plan into a `PlanMessage` for `SendPort.send`. `PlanReader.read` turns it back into a plan on
the other isolate. A draw that the builder keeps for two frames in a row crosses once and is kept on both sides. Use one
writer and one reader for one stream of plans. `planToJson` and `planFromJson` save a plan as JSON with its byte
payloads apart.

`RowLayout` and `RowTable` describe and fill the rows of GPU tables. `CookedScene` is the data model of a cooked scene.

## Example

The example builds a plan with one sky pass each frame and sends it to a runner isolate. It is
[`example/example.dart`](example/example.dart):

```dart
import 'dart:isolate';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';

/// The camera block that the sky draw binds. Its bytes change every frame.
final camera = FrameRole('camera');

/// A full-screen sky draw. The builder keeps it from frame to frame.
final sky = DrawPlan(
  vertex: 'Screen/fullscreen.vert',
  pixel: 'Sky/gradient.frag',
  geometry: const ScreenGeometry(3),
  state: const DrawState(cull: 'none', depthTest: false, depthWrite: false),
  viewport: [0, 0, 1280, 720, 0, 1],
  vertexResources: StageResources(),
  pixelResources: StageResources(blocks: {'Camera': camera.block}),
  label: 'sky',
);

FramePlan buildFrame(double time) => FramePlan(
  {'color': const TargetSpec(1280, 720, 'R8G8B8A8_UNORM')},
  [
    RenderPassPlan(
      'sky',
      [
        const Attachment('color', clear: [0, 0, 0, 1]),
      ],
      null,
      [sky],
    ),
  ],
  frameBlocks: {
    camera.block: Float32List.fromList([time, 0, 0, 0]).buffer.asUint8List(),
  },
);

/// A runner isolate. It reads each message back into a plan.
void runner(SendPort ready) {
  final messages = ReceivePort();
  ready.send(messages.sendPort);
  final reader = PlanReader();
  messages.listen((m) {
    final (plan, _) = reader.read(m as PlanMessage);
    if (plan == null) return messages.close();
    final draw = (plan.passes.single as RenderPassPlan).draws.single;
    final block = plan.block(draw.pixelResources.blocks['Camera']!);
    print('${draw.label} at ${Float32List.sublistView(block)[0]} s');
  });
}

Future<void> main() async {
  final ready = ReceivePort(), exit = ReceivePort();
  await Isolate.spawn(runner, ready.sendPort, onExit: exit.sendPort);
  final toRunner = await ready.first as SendPort;
  final writer = PlanWriter(sentThroughPort: true);
  for (var frame = 0; frame < 3; frame++) {
    toRunner.send(writer.write(buildFrame(frame / 60)));
  }
  toRunner.send(writer.write(null));
  await exit.first;
}
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools.
