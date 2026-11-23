# prismarine_pbr

The package is a forward renderer of glTF scenes. It builds the frame plan of a scene for
[prismarine_render](render.md), with glTF metallic-roughness materials and normal maps, alpha masks and alpha blending,
emission, a sun with a shadow map, up to 16 point lights with shadows from a cube atlas, fog lit by the sun and the
point lights, temporal anti-aliasing, auto exposure, bloom and a choice of tone maps. Its shaders are its own GLSL,
built with [prismarine_shaders](shaders.md). It is a Flutter package. `package:prismarine_pbr/builder.dart` holds the
builder without Flutter.

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
| `pointShadows` | `pointShadowAtlas`, D32_FLOAT | Six cube faces for each point light with a shadow slot, a row of the atlas each. |
| `opaque` | `hdr`, R16G16B16A16_FLOAT and `depth`, D32_FLOAT | Opaque draws, then masked draws, by material, with a jittered camera when TAA is on. The target clears to `settings.background`. |
| `blend` | `hdr` and `depth` | Blended draws from back to front, with depth tested and not written. |
| `markers` | `hdr` and `depth` | A disc in the colour of each point light at its place, added to the light. |
| `volumeInject`, `volumeIntegrate` | froxel volumes | Computes of the fog. |
| `volumeApply` | `hdr` | The fog in front of each pixel. |
| `taa` | `resolved`, R16G16B16A16_FLOAT | The temporal resolve. |
| `exposureHistogram`, `exposureAdapt` | `exposure`, R32_FLOAT | Computes of the auto exposure. |
| `bloomDown<n>`, `bloomUp<n>` | `bloom<n>`, R11G11B10_FLOAT | The bloom chain from half the view down. |
| `tonemap` | `backbuffer`, R8G8B8A8_UNORM and `taaHistory` with TAA | Bloom, exposure, the tone map, the sRGB encoding and a dither, then the shadow map views when `showShadowMap` is set. |

An effect that is off leaves its passes and targets out and the next pass reads the target before it. The lighting
uses a GGX distribution, Smith height-correlated visibility, Schlick Fresnel and a Lambert diffuse term. The specular
lobe widens where the normal turns within a pixel, which keeps the highlights of normal maps from sparkling. The sun's
shadow is a 3 by 3 filter of comparison samples with a depth bias and an offset along the normal. A point light falls
off with the range rule of `KHR_lights_punctual`. A sky and a ground colour stand in for indirect light. A material
without a texture reads a constant texture. A primitive must have `POSITION`, `NORMAL`, `TANGENT` and `TEXCOORD_0`, as
the prepare step of [prismarine_assets](assets.md) writes them. The draws have the default winding of a draw state,
which makes the counter-clockwise faces of glTF the front.

## Temporal passes

TAA moves the camera by a Halton offset each frame. `PbrBuilder.jitter` gives the offset in pixels,
`previousViewProjection` the last camera without jitter and `frameIndex` the count of frames, for the noise of other
temporal passes. The resolve reprojects the nearest depth of each pixel into the last frame and clips the history to
the colours around the pixel. Call `resetHistory` at a cut of the camera. It drops the histories of TAA, of the fog
and of the exposure. A new plan resets them too.

Auto exposure counts the luminance of the frame into a histogram, takes the mean without the darkest half and the
brightest 2 % and adapts towards a grey card at 0.18 with the compensation.

## Point light shadows

Each frame the builder gives the shadow slots of the budget to the lights with the most light at the camera among
those whose range touches the view. A light keeps its slot while it stays among the best. The six faces of a slot draw
the opaque and masked draws whose bounding sphere touches the face within the reach of the light. A one-sided material
draws its front faces only. The pass is retained while the lights hold still. Any stage can read a shadow with
`pointShadow(light, worldPos, normal)` of `shaders/programs/Pbr/bodies/point_shadow.glsl`, which needs the `Frame`
block, the texture `pointShadowAtlas` and the comparison sampler s4.

## Fog

The fog is a froxel grid along the view. A compute fills each froxel with the light that the fog scatters towards the
camera from the sun with its shadow map, from the point lights with their shadows and from the sky and ground colours,
with the Henyey-Greenstein phase function and blends it with the froxel of the last frame. A second compute sums each
column from near to far. The apply pass lays the sum over the scene by the depth of each pixel.

## Timed parts

`PbrBuilder.partLabels` and `timedPasses` split the plan into parts for `FrameRunner.timedParts`. The parts are
`shadows`, `point shadows`, `scene`, `fog`, `taa`, `exposure and bloom` and `tone map`, each present when its passes
are. `lastPartGpuMs` of the runner then holds the GPU time of each part by the index of its label.

## Settings

| Setting | Effect |
|---|---|
| `shadowSize` | The side of the shadow map, 2048 by default. A change makes a new plan. |
| `shadows` | Draws the sun's shadows. On by default. |
| `exposure` | The factor of the light before the tone map without auto exposure, 1 by default. |
| `sunDirection`, `sunColor`, `sunIntensity` | The direction towards the sun, its linear colour and its intensity, 8 by default. |
| `sky`, `ground` | The ambient colours from above and from below. |
| `background` | The colour where no geometry is drawn, read when a plan is made. |
| `lightMarkers`, `markerSize` | Draws a disc at each point light, on by default, and its radius, 0.2 m by default. |
| `showShadowMap` | Shows the depth of the shadow map in the top left corner and the point shadow atlas below it. Off by default. A change makes a new plan. |
| `shadowBias`, `normalOffset` | The depth bias of the shadow test and the offset along the normal in metres. |
| `post.taa`, `post.taaQuality` | TAA, on at medium by default. Low clamps the history to five neighbours, medium clips it to the deviation of nine, high adds a Catmull-Rom history and 16 offsets. |
| `post.bloom`, `post.bloomQuality`, `post.bloomStrength` | Bloom with 5, 6 or 7 levels, on at medium with a strength of 0.04 by default. |
| `post.autoExposure`, `post.compensation` | Auto exposure, on by default and its compensation, -0.5 EV by default. |
| `post.minEv`, `post.maxEv`, `post.adaptUp`, `post.adaptDown` | The limits of the adapted log2 luminance, -4 and 8 and the speed of adaptation per second, 3 up and 1.5 down. |
| `post.toneMap` | `agx` by default, or `acesFit`, `aces` or `neutral`. |
| `pointShadows.budget`, `pointShadows.quality` | The lights that cast shadows, 2 by default and at most 8 and the face size, 256, 512 or 1024 texels, medium by default. |
| `pointShadows.reach`, `pointShadows.bias` | The share of a light's range within which objects cast shadows, 0.5 and the depth bias in texels, 1.5. |
| `volume.enabled`, `volume.quality` | The fog, on at medium by default, with 96 by 54 by 64, 160 by 90 by 64 or 240 by 135 by 128 froxels. |
| `volume.density`, `volume.heightFalloff`, `volume.base` | The extinction per metre, 0.006, its falloff per metre of height, 0.08 and the height of the full density, 0. |
| `volume.anisotropy`, `volume.range` | The forward scattering, 0.5 and the far end of the grid, 60 m. |
| `volume.sun`, `volume.points`, `volume.ambient`, `volume.history` | The factors of the light in the fog, 1, 1 and 0.5 and the share of the last frame in each froxel, 0.9. |

A change of a switch, a quality or the point shadow budget makes a new plan. The other values apply to the next frame.

## Costs

The GPU time of each effect at 1920 by 1080 in the performance run of the sample, as the difference of the totals
with the effect on and off. The runs vary by about 0.2 ms.

| Effect | Mac, M2 Pro, Metal | Linux, RTX 4060 Ti, Vulkan |
|---|---|---|
| TAA, auto exposure, bloom and tone map at default | about 0.35 ms | about 0.15 ms |
| Fog at medium | about 0.15 ms | about 0.25 ms |
| Point shadows, each shadowed light at medium | about 1.2 to 1.5 ms | about 0.2 ms |

## Shaders

The sources are in `shaders/programs/Pbr/`. `dart tool/build_shaders.dart <out>` builds them with the impellerc of the
patched engine into `<out>/bundle/<backend>/Pbr.0.shaderbundle.gz` for Metal and Vulkan and writes the interface of
each shader into `<out>/records.json`. An app carries both as assets and passes them to `PbrShaderBundle.load`.

## Checks

Run `flutter test` in `packages/prismarine_pbr`. The tests build the plan of a generated scene without a GPU. The
sample app renders the plan on Metal and on Vulkan, see [the sample](../../apps/prismarine_sample/README.md).
