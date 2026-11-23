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
