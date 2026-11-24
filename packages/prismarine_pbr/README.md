# prismarine_pbr

prismarine_pbr is a forward renderer of glTF scenes. It builds the frame plans that prismarine_render records, with
metallic-roughness materials and normal maps, alpha masks and blending, a sun with a shadow map, up to 16 point lights
and a tone map. The details are on [the area page](../../docs/areas/pbr.md).

## Usage

Load each scene with `GpuScene.load` of prismarine_scene and the shaders with `PbrShaderBundle.load` from the files
that the cook of your app writes from its `prismarine.yaml`, as [the build page](../../docs/building.md#your-own-app)
describes. Call `requireEngine(pbrEngineFeatures)` of prismarine_scene first. `PbrAssets` serves both to a
`FrameRunner` with `pbrRunnerShaders`. Each frame, set the fields of a `PbrCamera`, of the point lights in
`PbrBuilder.lights` and of `PbrBuilder.settings`, then run the plan that `frame` returns. The plan stays the same object
while the size of the view holds, and a frame allocates nothing.

## Example

The example draws a scene from its first camera. It is [`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The package runs in Flutter apps on the patched engine, on macOS with Metal and on Linux and Windows with Vulkan. The
sample app checks it on macOS and Linux.
