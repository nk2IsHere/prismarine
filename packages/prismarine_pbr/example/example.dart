import 'package:prismarine_pbr/prismarine_pbr.dart';
import 'package:prismarine_render/prismarine_render.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

/// Draws a prepared glTF from one of its cameras into a 1920 by 1080 frame.
/// [shaders] comes from the bundle that the cook of the app wrote.
Future<void> drawScene(String gltf, PbrShaderBundle shaders) async {
  final scene = GpuScene.load(gltf);
  final runner = FrameRunner(
    PbrAssets(shaders, {'hall': scene}),
    pbrRunnerShaders,
  );
  final builder = PbrBuilder([PbrScene('hall', scene.model)]);
  builder.lights.add(
    PointLight()
      ..position.setValues(0, 2, 0)
      ..color.setValues(1, 0.6, 0.3)
      ..intensity = 40,
  );
  final camera = PbrCamera();
  final eye = scene.model.cameras.first.world;
  camera.view.copyInverse(eye);
  camera.position.setFrom(eye.getTranslation());
  await runner.run(
    builder.frame(camera, 1920, 1080),
    present: PbrTargets.backbuffer,
  );
  // runner.presented now holds the frame.
}
