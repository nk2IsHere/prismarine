# Post-processing and lights

The sample scene of `prismarine_pbr` gets the effects of a current game renderer after its lighting: temporal
anti-aliasing, bloom from the HDR image, auto exposure with a choice of tone maps, shadows for the coloured point
lights and volumetric light through the hall from the sun and the point lights. Each effect is switchable in the debug
panel of the sample, has a quality option and shows its GPU time in the frame graph. A frame allocates nothing.

Image-based light, dynamic global illumination, ambient occlusion and reflections are a separate design in the same
package. Both designs share the HDR target, the depth target, the pass order below and the jitter of the camera.

## Goals

- Anti-aliasing that resolves the fine threads of the curtains, the alpha-masked leaves and the specular highlights of
  the normal maps without crawling while the camera moves.
- Bloom that spreads bright light without a threshold and keeps the energy of the image.
- Auto exposure from the luminance of the frame, with compensation, limits and a speed of adaptation and the tone maps
  ACES fitted, the current fit of Narkowicz, AgX and the Khronos PBR Neutral curve.
- Shadows for the point lights with a budget of lights that cast them.
- Light shafts and fog from the sun and the point lights, shadowed by both shadow maps.
- The GPU time of each effect in the frame graph, from timed parts of the frame.
- The sample keeps 60 Hz at 1920 by 1080 on the workstation's RTX 4060 Ti and 120 Hz on the Mac with an M2 Pro with
  the default quality.

## Not in scope

- Motion vectors of moving objects. The scene is static apart from the camera and the lights. The anti-aliasing
  reprojects through the depth and the camera of the last frame.
- Upscaling and a render scale.
- Shadows for spot lights. The scene has none.
- Depth of field, motion blur, lens flares and lens dirt.

## Pass order

| Pass | Kind | Target | Contents |
|---|---|---|---|
| `shadow` | render | `shadowMap` | The sun, retained while the sun holds still. |
| `pointShadows` | render | `pointShadowAtlas`, D32_FLOAT | Six faces for each point light with a shadow slot. |
| GI passes | compute and render | their own | The probes and the environment of the other design. |
| `opaque` | render | `hdr`, R16G16B16A16_FLOAT, `depth`, D32_FLOAT and the G-buffer of the other design | The lit draws with a jittered projection. |
| indirect passes | render | `hdr` | Ambient occlusion, reflections and the indirect light of the other design. |
| `blend`, `markers` | render | `hdr` | As before. |
| `volumeInject`, `volumeIntegrate` | compute | `volumeScatter`, `volumeIntegrated`, `volumeHistory` | The froxel grid. |
| `volumeApply` | render | `hdr` | The fog in front of each pixel. |
| `taa` | render | `resolved`, R16G16B16A16_FLOAT | The temporal resolve. |
| `exposureHistogram`, `exposureAdapt` | compute | `exposure` | The auto exposure. |
| `bloomDown<n>`, `bloomUp<n>` | render | `bloom<n>` | The bloom chain. |
| `tonemap` | render | `backbuffer` and `taaHistory` with TAA on | Exposure, bloom, the tone map and the sRGB encoding, then the overlays. |

An effect that is off leaves its passes out of the plan and the next pass reads the target before it. Without TAA the
bloom and the histogram read `hdr`. A switch of an effect or of its quality makes a new plan. Values such as the bloom
strength or the fog density apply to the next frame.

## Timed parts of the frame

Flutter GPU has no timestamp queries. The runner of `prismarine_render` gets a list of pass names where a timed part of
the frame starts. It records each part into a command buffer of its own and submits the buffers in order after the
last one. The time from the completion of one buffer to the completion of the next is the GPU time of the part. The
first part counts from its submission. `FrameRunner.lastPartGpuMs` holds the times of the last frame by part. The
builder gives its parts in `PbrBuilder.timedParts`, such as `shadows` from `shadow`, `scene` from `opaque`, `volume`
from `volumeInject`, `taa`, `bloom` from `exposureHistogram` and `tone map`. A part costs one more submission on the
CPU, about 20 µs. The sample turns the parts on while its panel shows and in the performance run.

## Anti-aliasing

TAA follows the common design of Karis and of the INSIDE renderer. Each frame moves the projection by a sub-pixel
offset from the Halton sequence in bases 2 and 3, with 8 offsets at low and medium quality and 16 at high quality. The
`Frame` block carries the jittered view-projection. `PbrBuilder.jitter` gives the offset in pixels,
`previousViewProjection` the last frame's view-projection without jitter and `frameIndex` the count of frames, for the
temporal noise of other passes.

The resolve finds the nearest depth of each pixel and its four diagonal neighbours and reprojects that point into the
last frame with the matrices without jitter. A static camera then reads the history at the same pixel. The history is read with a
five-tap Catmull-Rom filter at high quality and bilinear filtering below it. The 3 by 3 neighbourhood of the current
frame in YCoCg gives the mean and the deviation and the history is clipped towards the mean into the box of 1.25
deviations. Colours are weighted by the inverse of their luminance before the blend, which keeps a single bright pixel
from flickering. A colour that is not a finite number counts as black and does not enter the history. The blend takes
1/12 of the current frame. A history outside the view or a reset takes the current frame alone. Low quality uses a clamp
to the minimum and maximum of the 5 neighbours of a cross.

The history is `taaHistory`, a copy of `resolved` that the tone map pass writes as its second colour target. A copy
pass is not needed. The material sampler gets a mip bias of -0.5 with TAA on, which the history averages back into a
sharp and stable texture. `PbrBuilder.resetHistory` drops the histories of TAA, of the volume and of the exposure, for
a cut of the camera.

SMAA was considered. It finds edges in the final image only and does not see the sub-pixel threads of the curtains or
the shimmer of specular highlights. Both are the main aliasing of the scene.

## Bloom

Bloom follows the method of Jimenez for Call of Duty. A chain of targets at half, quarter and smaller sizes, 5 at low,
6 at medium and 7 at high quality, in R11G11B10_FLOAT. Each down pass reads the larger level with 13 bilinear taps.
The first one weights its taps by the inverse of their luminance, the Karis average, which removes fireflies. Each up
pass reads the smaller level with a 3 by 3 tent filter and adds it to the larger one with an additive blend. The tone
map pass mixes the image with the first level divided by the number of levels, by the strength, 0.04 by default. The
bloom has no threshold. The mix keeps the energy of the image.

## Exposure and tone maps

`exposureHistogram` reads every second pixel in each direction of `resolved` and counts the log2 of its luminance into
256 bins between -10 and 6 EV, with a weight that falls from the centre of the view. The bins are a frame buffer whose
zeros the CPU uploads each frame. `exposureAdapt` is one group that drops the darkest 50 % and the brightest 2 % of the
weight, takes the mean of the rest and gives the exposure of a grey card at 0.18 with the compensation. It moves the
exposure of the last frame towards it at the speed of adaptation, 3 per second up and 1.5 per second down and clamps
it to the limits. A reset or the first frame takes the target at once. `exposure` is a 1 by 1 R32_FLOAT storage target
that the adapt pass reads and writes. A value that is not a finite number counts as a reset. With auto exposure off,
the tone map uses `settings.exposure`.

The tone map pass reads the exposure, adds the bloom, applies the tone map of `settings.post.toneMap` and encodes sRGB.

| Tone map | Curve |
|---|---|
| `acesFit` | The fit of Narkowicz to the ACES RRT and ODT, the curve of the first renderer. |
| `aces` | The fit of Hill to the ACES RRT and ODT with the input and output matrices of AP1, which desaturates bright colours as ACES does. |
| `agx` | AgX of Sobotka with the polynomial fit of the base contrast. Bright colours of the point lights go to white without a change of hue. |
| `neutral` | The Khronos PBR Neutral curve, which keeps the base colours of materials. |

## Point light shadows

A budget, 2 by default, sets the most point lights that cast shadows. The sample starts with none on macOS, where
each shadowed light costs about 1.5 ms of the GPU of an M2 Pro. Each frame the builder scores the lights whose
sphere of range touches the view by intensity over the squared distance to the camera and gives the shadow slots to
the best. A light that holds a slot keeps it while it stays in the budget. `lightColor[i].w` of the `Frame` block holds
the slot of light i plus one, 0 for none.

The atlas has a row for each slot and six tiles in each row, one per face of a cube. A tile is 256, 512 or 1024 texels
at low, medium and high quality. A face draws with the shadow shaders of the sun and a perspective projection of 90
degrees from 0.05 m to the range of the light. Its draws are the opaque and masked draws whose bounding sphere is
inside the reach of the light, half its range by default, and touches the frustum of the face. A one-sided material
draws its front faces only. A kept list holds the draws of the atlas, refilled each frame with no allocation. The
draws of a face are made on its first use and kept. The pass is retained with a stamp of the slots and the places of
their lights, which skips it while the lights hold still.

`bodies/point_shadow.glsl` has `pointShadow(light, worldPos, normal)`, which reads only the `Frame` block and the atlas
with the comparison sampler s4. It works in any stage. It finds the major axis, turns the distance along it into the
depth of the face's projection and filters four bilinear comparison taps inside the tile with a border of one texel.
The bias grows with the distance as the texels do.

A cube of six render targets or a dual-paraboloid map were considered. A cube of targets costs a pass for each face. A
paraboloid bends straight edges of large triangles. The atlas draws every face in one pass with one depth target.

## Volumetric light

The fog is a froxel grid aligned to the view, 96 by 54 by 64 at low, 160 by 90 by 64 at medium and 240 by 135 by 128
at high quality, with slices that grow exponentially from 0.25 m to the range of the fog, 60 m by default.

`volumeInject` is a compute pass over every froxel. It places a point in the froxel with a depth offset from the frame
index, takes the density of a uniform fog with an exponential falloff over height and adds the light of the sun with
its shadow map, of each point light with its range falloff and its point shadow and an ambient term from the sky and
ground colours, each with the Henyey-Greenstein phase function of the anisotropy setting, 0.4 by default. The result
is blended with the last frame's froxel at the reprojected point, 1/10 of the new value, in `volumeScatter`.
`volumeIntegrate` walks each column from near to far with the energy-conserving integration of Hillaire and writes the
in-scattered light and the transmittance into `volumeIntegrated` and the froxel values into `volumeHistory` for the
next frame. Both are RGBA16_FLOAT volume textures. `volumeApply` is a full-screen draw that reads the depth of each
pixel, finds its froxel with trilinear filtering and blends the light in front of the pixel over `hdr`.

Ray marching each pixel at half resolution was considered. It costs one walk per pixel and point light. The froxel grid
costs one sample per froxel and light, about a tenth of the work at 1920 by 1080 and handles any number of lights.

## Settings

The settings are groups of `PbrSettings`: `post` for TAA, bloom, exposure and the tone map, `pointShadows` and
`volume`. `PbrQuality` has `low`, `medium` and `high`. The defaults are TAA on at medium, bloom on at medium, auto
exposure on with a compensation of -0.5 EV, the tone map AgX, two point light shadows at medium and the fog on at
medium with an extinction of 0.006 per metre. The owner chose AgX. The measured costs are in
[the pbr area page](../areas/pbr.md#costs).

## Specular anti-aliasing

TAA averages a highlight that moves between pixels. It does not remove a highlight that a normal map makes smaller
than a pixel, such as the pits of the stone. The lit shader widens the GGX lobe by the change of the normal within the
pixel, after Kaplanyan and Tokuyoshi, with the added roughness squared capped at 0.18.

## Allocation

Every target, draw, dispatch and block is made with the plan. A frame writes floats into kept blocks, refills the kept
draw lists of the point shadow faces and reads the GPU times into a kept list. The completion callbacks of the timed
parts are made once. The entry points stay `PbrBuilder.frame` and `FrameRunner.run`, which the alloc roots list.

## Smoke test

The smoke test resets the histories at each view and runs 16 frames of it with the lights still. TAA, the volume and
the exposure converge to a fixed image. The references of each OS change with this work and are recorded again.

## Risks

- The time between completions of command buffers includes the latency of the completion handlers. Small parts read
  a few tens of µs high. The performance run measures each effect by its switch as well.
- The point shadows draw the scene again for each face. The draws of Sponza are large chunks and a light with a range
  of 12 m reaches most of the hall. The budget and the tile size bound the cost.
- A storage image in a 3D texture and its sampling in the next pass need the layouts of Vulkan to change between the
  passes. The runner places barriers between dispatches. The first run on each backend checks it.
