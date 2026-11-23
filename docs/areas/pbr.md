# prismarine_pbr

The package is a forward renderer of glTF scenes. It builds the frame plan of a scene for
[prismarine_render](render.md), with glTF metallic-roughness materials and normal maps, alpha masks and alpha blending,
emission, a sun with a shadow map, up to 16 point lights and a tone map. Its shaders are its own GLSL, built with
[prismarine_shaders](shaders.md). It is a Flutter package. `package:prismarine_pbr/builder.dart` holds the builder
without Flutter.

## Use

You load each scene as a `GpuScene` of [prismarine_scene](scene.md) and the shaders as a `PbrShaderBundle`. A
`PbrAssets` serves both to a `FrameRunner` with `pbrRunnerShaders`. A `PbrBuilder` gets a `PbrScene` for each scene,
with the prefix that its stems start with. Each frame you set the fields of a `PbrCamera`, of the `PointLight`s in
`PbrBuilder.lights` and of `PbrBuilder.settings`, then call `frame` with the size of the view and run the plan with
`present: PbrTargets.backbuffer`.

```dart
final assets = PbrAssets(shaders, {'hall': scene});
final runner = FrameRunner(assets, pbrRunnerShaders);
final builder = PbrBuilder([PbrScene('hall', scene.model)]);
camera.view.setFrom(view);
await runner.run(builder.frame(camera, 1920, 1080), present: PbrTargets.backbuffer);
```

The builder makes the plan once for a view size and shadow map size and returns the same plan in later frames. A
frame writes the camera, the sun and the lights into the bytes of its frame roles and sorts the blended draws from
back to front in place. A frame allocates nothing. The shadow pass carries a retained stamp of the sun direction. The
runner leaves the pass out while the sun holds still.

## Frame

| Pass | Target | Draws |
|---|---|---|
| `shadow` | `shadowMap`, D32_FLOAT | Every opaque and masked draw from the sun, with an orthographic projection around the scenes. Masked draws test alpha. |
| `opaque` | `hdr`, R16G16B16A16_FLOAT, and `depth`, D32_FLOAT | Opaque draws, then masked draws, by material. The target clears to `settings.background`. |
| `blend` | `hdr` and `depth` | Blended draws from back to front, with depth tested and not written. |
| `markers` | `hdr` and `depth` | A disc in the colour of each point light at its place, added to the light. |
| `tonemap` | `backbuffer`, R8G8B8A8_UNORM | Exposure, the ACES fit of Narkowicz and the sRGB encoding, then the shadow map in the top left corner when `showShadowMap` is set. |

The lighting uses a GGX distribution, Smith height-correlated visibility, Schlick Fresnel and a Lambert diffuse term.
The sun's shadow is a 3 by 3 filter of comparison samples with a depth bias and an offset along the normal. A point
light falls off with the range rule of `KHR_lights_punctual`. A sky and a ground colour stand in for indirect light. A
material without a texture reads a constant texture. A primitive must have `POSITION`, `NORMAL`, `TANGENT` and
`TEXCOORD_0`, as the prepare step of [prismarine_assets](assets.md) writes them. The draws have the default winding of
a draw state, which makes the counter-clockwise faces of glTF the front.

| Setting | Effect |
|---|---|
| `shadowSize` | The side of the shadow map, 2048 by default. A change makes a new plan. |
| `shadows` | Draws the sun's shadows. On by default. |
| `exposure` | The factor of the light before the tone map, 1 by default. |
| `sunDirection`, `sunColor`, `sunIntensity` | The direction towards the sun, its linear colour and its intensity, 8 by default. |
| `sky`, `ground` | The ambient colours from above and from below. |
| `background` | The colour where no geometry is drawn, read when a plan is made. |
| `lightMarkers`, `markerSize` | Draws a disc at each point light, on by default, and its radius, 0.2 m by default. |
| `showShadowMap` | Shows the depth of the shadow map in the top left corner. Off by default. A change makes a new plan. |
| `shadowBias`, `normalOffset` | The depth bias of the shadow test and the offset along the normal in metres. |

## Shaders

The sources are in `shaders/programs/Pbr/`. `dart tool/build_shaders.dart <out>` builds them with the impellerc of the
patched engine into `<out>/bundle/<backend>/Pbr.0.shaderbundle.gz` for Metal and Vulkan and writes the interface of
each shader into `<out>/records.json`. An app carries both as assets and passes them to `PbrShaderBundle.load`.

## Checks

Run `flutter test` in `packages/prismarine_pbr`. The tests build the plan of a generated scene without a GPU. The
sample app renders the plan on Metal and on Vulkan, see [the sample](../../apps/prismarine_sample/README.md).
