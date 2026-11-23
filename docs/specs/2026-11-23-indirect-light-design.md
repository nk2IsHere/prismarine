# Indirect light

This spec adds indirect light to `prismarine_pbr`: a sky with image-based light, dynamic global illumination from
irradiance probes, ambient occlusion and reflections. It covers the goal "Global illumination and reflections" of
[goals](../memory/goals.md). The sample shows it in Intel's Sponza, where the sun and the coloured point lights bounce
off the curtains, the floors and the walls.

## Goals

- A procedural sky in place of the clear colour, with a prefiltered environment map for specular light, a diffuse
  irradiance map and a BRDF lookup table.
- Dynamic diffuse global illumination from the sun, the point lights and the sky, with several bounces. Moving lights
  and a moving sun update it within a fraction of a second. The camera can be anywhere in the scene.
- Ambient occlusion from the depth buffer.
- Reflections on smooth surfaces from the screen, with the probes and the environment where the screen has no answer.
- Each effect can be switched on and off in the debug panel. Each has its passes in the frame graph and a quality
  setting.
- The sample holds 120 Hz at 1920 by 1080 on the Mac with an M2 Pro and 60 Hz on the workstation's RTX 4060 Ti at the
  default quality.
- No allocation per frame. The new per-frame entries are roots of the alloc lint.

## Not in scope

- Moving geometry in the GI. The voxel copy of the scene is made once at load. Moving lights, the sun and the camera
  are dynamic.
- Hardware ray tracing. Flutter GPU has no ray queries.
- Local reflection probes made by rasterising cube maps. Their draw count would be the scene's for each of six faces.
- Emissive surfaces as light sources in the GI.
- Bloom, anti-aliasing, point light shadows, fog and auto exposure. A neighbouring branch adds these in
  `prismarine_pbr` with its own spec.

## Choice of the GI technique

Flutter GPU on the engine fork has compute shaders, storage images and buffers, texture arrays, 3D textures and
multiple render targets. It has no ray queries and no geometry shaders. The candidates were these.

| Technique | Cost | Off-screen light | Leaks | Fit |
|---|---|---|---|---|
| Screen-space GI | Per pixel, grows with the resolution | None, light behind the camera is lost | Few | Cheap, but curtains out of view light nothing |
| Rasterised probe capture | Six passes of every draw per probe | Yes | Few | About 5,400 draws per probe, too many for a scene of 900 draws |
| Voxel cone tracing | Per pixel cones through a mipmapped 3D radiance volume, plus voxelisation each frame | Yes | Many with coarse voxels | Voxelisation needs pixel shaders that write storage images |
| Irradiance probes traced in compute through a voxel copy of the scene, DDGI-like | Per probe and ray, independent of the resolution | Yes | Few with the visibility test | Compute only, the CPU voxelises a static scene once |

The last row is the choice. Its cost does not grow with the resolution. A pixel reads eight probes, which costs about
the same at 1080p as the constant ambient term. The probes hold several bounces, since a ray hit reads the probes of
the last update. Rays that leave the scene return the sky. A probe therefore also holds the visibility of the sky,
which the reflections reuse.

## Frame

The passes of the neighbouring branch, point light shadows, fog, anti-aliasing, bloom and the tone map, keep their
places around these passes. The order agreed with it is: `shadow`, point light shadows, the GI passes, `opaque`, the
passes after opaque below, `blend`, `markers`, then fog, anti-aliasing, bloom and the tone map.

| Pass | Kind | Target | Runs |
|---|---|---|---|
| `gi.brdf` | compute | `brdfLut`, R16G16_FLOAT, 64 by 64 | Once |
| `gi.sky` | compute | `skyEnv`, R16G16B16A16_FLOAT, 256 by 128 with mips | When the sun or the sky settings change |
| `gi.skyMip1` … | compute | the next mip of `skyEnv` | With `gi.sky` |
| `gi.skySpecular0` … | compute | one mip of `skySpecular`, 128 by 64 with 6 mips | With `gi.sky` |
| `gi.skyIrradiance` | compute | `skyIrradiance`, 32 by 16 | With `gi.sky` |
| `gi.trace` | compute | `giRays`, one row of rays per probe of this frame | Each frame |
| `gi.blend` | compute | `giIrradianceNext` and `giDistanceNext` | Each frame |
| `gi.copy` | compute | `giIrradiance` and `giDistance`, with the borders of the tiles | Each frame |
| `opaque` | draws | `hdr`, `gbufferNormal`, `gbufferAlbedo`, `depth` | Each frame |
| `sky` | one triangle | `hdr` where `depth` is 1 | With the sky on |
| `ao` | one triangle | `aoRaw`, R8_UNORM at half size | With occlusion on |
| `aoBlur` | one triangle | `ao`, R8_UNORM at half size | With occlusion on |
| `ssr` | one triangle | `ssr`, R16G16B16A16_FLOAT at half or full size | With reflections on |
| `indirect` | one triangle | `hdr`, added | Each frame |
| `history`, `historyMip1` … | one triangle | `history`, R16G16B16A16_FLOAT at half size with 5 mips | With reflections on |

The pass `opaque` writes the direct light of the sun and the point lights and the emission into `hdr`. Its two more
targets hold what `indirect` needs. `gbufferNormal` is R16G16B16A16_FLOAT with the normal in octahedral form, the
roughness and the metallic value. `gbufferAlbedo` is R8G8B8A8_UNORM with the base colour. The pass `indirect` reads
them with the depth and adds the diffuse light of the probes times the occlusion and the specular light of the
reflections into `hdr`. The blended draws come after it and compute their indirect light in their own pixel shader.

A switched-off effect leaves its passes out of the plan. A change of a switch, of the quality or of the debug view
makes a new plan.

## The voxel copy

The builder gets the copy from `buildGiVolume`, which runs in an isolate after the scenes load. It reads each glTF file
again, walks its draws with their world matrices and marks the cells of a regular grid that a triangle touches. The
cell size gives about two million cells for the bounds of the scenes, 0.2 m for Sponza. A triangle larger than a cell
is sampled at half the cell size. Each cell gets the average base colour of its triangles, read at the texture
coordinate of the sample from a mip level of at most 64 by 64 texels of the base colour texture, times the base
colour factor. It also gets the average normal weighted by area and a flag for double-sided materials. Blended
materials are left out. Masked materials test the alpha of the sample.

Two passes over the grid make the Chebyshev distance of each empty cell to the next marked cell in cells, up to 255.
A flood fill from the faces of the grid through empty cells marks the empty cells that it does not reach as solid.
These are inside walls and columns. A cell holds two words in a storage buffer.

| Word | Bits |
|---|---|
| 0 | red, green and blue of the base colour, then the distance, 0 for a marked or solid cell |
| 1 | the normal in octahedral form as two signed bytes, then the flags: double-sided, solid |

A ray steps through the grid by the distance of its cell less one, or to the next cell boundary when the distance is
1. A cell with distance 0 is a hit.

## Probes

The probes form a grid over the GI bounds, the bounds of the scenes or the box that the app sets. The spacing gives
at most `maxProbes` probes, 4,096 by default. The CPU moves each probe within its cell away from the surfaces, to the
point with the largest distance among 27 candidates. A probe without a candidate in an empty, reachable cell is off.
The probe data is a texel buffer of RGBA32F with the offset and the state of each probe, then the list of the probes
that are on.

Each frame `gi.trace` traces the rays of `probesPerFrame` probes of the list, the next ones after those of the last
frame. A probe casts `raysPerProbe` rays in a spherical Fibonacci pattern, rotated at random each frame. A hit gets
the light of the sun through the shadow map, the light of the point lights without shadows, and the light of the
probes of the last update times the bounce factor, each times the base colour of the cell over pi. A miss gets the
radiance of the sky in its direction. `gi.blend` weighs the rays into each texel of a probe's tiles and blends the
result with the old value by the hysteresis. `gi.copy` copies the updated tiles into the textures that the passes
read and fills their borders for bilinear reads.

| Texture | Tile | Contents |
|---|---|---|
| `giIrradiance` | 8 by 8 texels, 6 by 6 inside | The irradiance in octahedral form, with the share of the sky in alpha |
| `giDistance` | 16 by 16 texels, 14 by 14 inside | The mean distance to a hit and the mean of its square |

A pixel reads the eight probes around it. A probe's weight is the trilinear weight times a term for the side of the
surface that it is on, times the Chebyshev visibility from the distance moments, times its state. The point that is
read is moved along the normal and towards the camera by a share of the spacing. `bodies/gi_probes.glsl` holds the
read as `giIrradiance(position, normal, view)`. A zero normal and a zero view direction leave out the side term and
the move, for a reader without a surface such as fog.

## Sky and environment

`gi.sky` evaluates single scattering in an atmosphere of Rayleigh and Mie particles for each texel of an
equirectangular map. It uses 16 steps along the view and 8 towards the sun. Below the horizon it returns a ground of
grey albedo, lit by the sun and the sky. The sun's disc is left out of the map. The `sky` pass draws the map at the
far plane with the disc added. The map is in the units of the sun's light, times `skyIntensity`.

`gi.skySpecular` filters the map for six roughness values from 0 to 1, one mip each, with 64 GGX samples per texel
that read the mip of the source that their solid angle covers. `gi.skyIrradiance` convolves a small mip of the map
with the cosine. `gi.brdf` integrates the split-sum scale and bias of GGX with Smith visibility into a table over the
cosine of the view and the roughness.

## Ambient occlusion

`ao` estimates the occlusion at half size from the depth and the normals in the manner of ground-truth ambient
occlusion. Each pixel searches the horizon in two to four directions with three to eight steps each, within
`aoRadius` in world units, rotated by a 4 by 4 pattern and the frame index. `aoBlur` filters the 4 by 4 pattern with
weights by depth. The occlusion scales the diffuse indirect light. The specular indirect light gets the specular
occlusion that follows from it, the roughness and the angle of view.

## Reflections

`ssr` marches the reflected ray of each pixel with a roughness below 0.6 through the depth buffer in screen space and
refines a hit by bisection. A hit reads `history`, the light of the last frame at half size, at the place of the hit
in the last frame and at a mip that follows the roughness and the length of the ray. Its weight falls off at the edges
of the screen and with the roughness. The rest of the specular light comes from the probes and the sky: the radiance
of the probes in the direction of the reflection, mixed towards the prefiltered sky by the share of the sky in that
direction. The split-sum table scales the sum.

## Blocks

The fields of the GI are in a block of their own, `Indirect`, bound by the role `pbr.indirect`. The neighbouring branch
adds no fields to it. It holds the inverse of the view-projection, the view-projection of the last frame, the size of
the view, the probe grid, the tile layout, the ray rotation and probe range of this frame, the sky and the settings of
the effects.

## Settings

The settings are a group `PbrGiSettings` in `PbrSettings.gi`. `quality` sets the numbers below to its preset. A field
can be changed after it.

| Setting | Low | Medium, the default | High |
|---|---|---|---|
| `raysPerProbe` | 64 | 96 | 192 |
| `probesPerFrame` | 128 | 256 | 768 |
| `aoDirections`, `aoSteps` | 2, 4 | 2, 6 | 4, 8 |
| `ssrSteps` | 16 | 32 | 64 |
| `ssrFullSize` | no | no | yes |

The switches are `sky`, `probes`, `ambientOcclusion` and `reflections`, each on by default. With `probes` off the
diffuse indirect light comes from the sky irradiance, which also lights rooms without a view of the sky. With `sky`
off the sky and the indirect light take the flat colours `sky` and `ground` of the settings. `debugView` shows the
indirect diffuse light, the occlusion, the reflections or the probes as spheres in place of the picture.

## Risks

- A voxel of 0.2 m misses thin parts and lets rays through gaps. The flood fill closes thick walls. Thin parts leak a
  little light.
- Probes in a regular grid leak light through walls thinner than their spacing. The visibility test and the moved
  probes reduce it. The spacing in Sponza is about 1.6 m.
- The point lights reach the probes without shadows. Light reaches the far side of a column. Shadowed point lights in
  the trace follow once point light shadows are in the plan.
- Reflections of things off the screen or hidden behind others fall back to the probes, which are blurred.
- The cost of the trace on the Mac decides the default numbers. They are set by measurement.
