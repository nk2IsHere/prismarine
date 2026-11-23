# The sample scene

The sample app becomes a real example of prismarine. It shows Intel's Sponza, the palace atrium with arches, columns
and coloured curtains, lit by a sun with a shadow map and by coloured point lights that move through the hall. You
fly through it with the mouse and keyboard or with a gamepad. The same app is the smoke test of the gate and a
performance scene on macOS, Linux and Windows.

## Goals

- A scene that every engine uses as its test bed, drawn only through prismarine: the scene layer loads the glTF, a
  small generic builder makes the frame plan and `prismarine_render` records it.
- glTF metallic-roughness materials with normal maps, alpha masks, alpha blending and emission, a directional light
  with a shadow map, coloured point lights and a tone map, in our own GLSL built with `prismarine_shaders`.
- A fly camera, the real-time loop of `prismarine_loop`, the debug panel and frame graph of `prismarine_debug` and
  gamepads through `prismarine_pad`.
- A headless mode that renders fixed frames and checks them against stored hashes with a tolerance, and a performance
  mode that logs frame times.
- Code that a frame runs does not allocate. The entry points of the builder are roots of the alloc lint.

## Not in scope

- Global illumination, reflections, image-based light, bloom and anti-aliasing beyond the hardware.
- Point light shadows. Only the sun casts shadows.
- Texture compression. The prepared textures are RGBA8 with mips. A BC encoder can come later.
- Skinning and animation. The scene is static apart from the camera and the lights.

## Model and licence

The model is Intel's Sponza from the Intel Graphics Research samples, the 2022 remake commissioned by Frank Meinl.
The page of the samples states "Downloads are available under the Creative Commons Attribution license." The
`credits_license.txt` file of each package holds the credit and the text of the Creative Commons Attribution 4.0
International Public License. The README of the sample and the panel of the app quote its credit lines exactly, with
the line on use that comes before the licence, and link the source page and the licence.

Nothing of the model enters git. A fetch script downloads it into a directory that git ignores, by default
`data/sample` of the repository, or the directory in `PRISMARINE_SAMPLE_DATA`. Each package is a zip archive with
every format of the scene. The script reads the central directory of the archive with HTTP range requests and
downloads only the glTF, its buffer and the textures that the glTF uses.

| Package | Archive | glTF part | Default |
|---|---|---|---|
| Sponza base scene | 3.99 GB | 2.12 GB, 72 textures in 4K, 3.7 million triangles | yes |
| Colorful curtains | 0.79 GB | 0.24 GB, 8 textures, 2.0 million triangles | yes |
| Ivy | 1.29 GB | 0.14 GB, 3 textures, 5.1 million triangles | no, `--ivy` |

The base scene has no alpha-masked material and one blended decal. The curtains and the ivy are opaque and double
sided. The tests of the builder cover the alpha masks with a small generated glTF.

## Data flow

```
fetch.dart  ->  data/sample/source/<package>/       the glTF, its buffer and PNG textures as shipped
prepare     ->  data/sample/prepared/<package>/     scene.gltf, scene.bin, textures/<n>.ktx2
app         ->  prismarine_scene loads each prepared glTF onto the GPU
```

The prepare step turns any glTF 2.0 file into one that the GPU loads without work. It is generic and is in
`prismarine_assets`.

- Each primitive with more than 65,535 vertices or with 32-bit indices is split into chunks with 16-bit indices, the
  index type of the runner. A chunk keeps the material and the node of its primitive.
- Each chunk gets one interleaved vertex buffer of position, normal, tangent and the first UV set, 48 bytes a vertex.
  A primitive without tangents gets tangents from its UVs. A primitive without UVs gets zero UVs.
- Each texture becomes a KTX2 file of RGBA8 with every mip level. A texture larger than `--texture-size`, 1024 by
  default, is scaled down first. The mips of a base colour or emissive texture are filtered in linear light. A normal
  map is renormalized at each level.
- The output is a glTF 2.0 file whose images are KTX2 files with the media type `image/ktx2`. Core glTF 2.0 lists
  only PNG and JPEG images, so a general glTF viewer shows the geometry without these textures.

The prepare step of the base scene with the curtains takes about a minute with six jobs on the workstation. The
prepared files take 0.6 GB, 0.5 GB for the base scene and 0.1 GB for the curtains.

## Packages

| Package | Added parts |
|---|---|
| `prismarine_assets` | `GltfDocument`, a reader of glTF and GLB with typed accessors. `readKtx2`, the reader of the KTX2 files that `encodeKtx2` writes. `prepareGltf`, the prepare step above. Image decoding through `package:image`. |
| `prismarine_shaders` | `shaderInterface`, the interface of a GLSL source as the JSON that `ShaderRecord` reads: its uniform blocks with their std140 rows, textures, samplers and vertex inputs, by the naming rules below. |
| `prismarine_scene` | `GpuScene`, a prepared glTF on the GPU: a device buffer per buffer view, KTX2 textures loaded on first use, the draws of its node tree with world matrices and bounds, its cameras and its punctual lights. |
| `prismarine_pbr` | New. The forward renderer: the frame plan builder, the shaders and a `RenderAssets` over scenes and a shader bundle. |

`prismarine_pbr` depends on `prismarine_frame`, `prismarine_render`, `prismarine_scene` and `prismarine_kept`. It is a
Flutter package outside the pub workspace, like `prismarine_render`. The builder part imports no Flutter. The app
depends on the five packages and on `prismarine_loop`, `prismarine_debug` and `prismarine_pad`.

## Frame

The builder makes one `FramePlan` for a scene, a view size and the settings. The plan holds every draw once and stays
the same object from frame to frame. Each frame the builder writes the camera, the sun and the point lights into the
bytes of one frame role and returns the same plan. A new view size, a new shadow map size or a new scene makes a new
plan.

| Pass | Target | Contents |
|---|---|---|
| `shadow` | `shadowMap`, D32_FLOAT, 2048 by default | Every opaque and masked draw from the sun, with an orthographic projection that fits the bounds of the scene. Masked draws test alpha. The pass is retained with a stamp of the sun direction and of the shadow settings. A still sun records it once. |
| `opaque` | `hdr`, R16G16B16A16_FLOAT, and `depth`, D32_FLOAT | Opaque draws, then masked draws, sorted by material to keep pipeline and texture changes few. Back faces are culled unless the material is double sided. |
| `blend` | `hdr` and `depth` | Blended draws, sorted from back to front once per frame with a kept order. Depth is tested and not written. |
| `markers` | `hdr` and `depth` | A disc in the colour of each point light at its place, added to the light, switchable in the panel. |
| `tonemap` | `backbuffer`, R8G8B8A8_UNORM | One triangle over the view. Exposure, the ACES fit of Narkowicz and the sRGB encoding. With the shadow map view on, the depth of the shadow map in the top left corner. |

The lighting is the glTF metallic-roughness model: GGX normal distribution, Smith height-correlated visibility and
Schlick Fresnel, with a Lambert diffuse term. The sun uses a 3 by 3 PCF over the shadow map with a slope-scaled depth
bias. Up to 16 point lights use the range falloff of `KHR_lights_punctual`. A constant ambient term with a sky and a
ground colour stands in for indirect light. Emissive factors and textures add to the result. `COLOR_0` is ignored.

A material without a texture binds a constant texture, white for base colour, metallic-roughness and emission and a
flat normal for normal maps. The pixel shader has a variant for masked materials. Every prepared primitive has
tangents.

### Blocks

| Block | Role | Contents |
|---|---|---|
| `Frame` | a `FrameRole`, its bytes written each frame | view-projection, camera position, sun direction and colour, the sun's shadow matrix, ambient colours, exposure, the count of point lights and per light the position, range, colour and intensity |
| `Draw` | bytes of the draw, made once | model matrix, normal matrix, base colour factor, metallic, roughness, alpha cutoff, normal scale and emissive factor |

## Shaders

The GLSL sources are in `packages/prismarine_pbr/shaders/programs/Pbr/`, with the shared code in a `bodies` folder.
A tool of the package builds them with `buildShaderBundles` into one gzip-compressed bundle per backend and writes the
interface of each shader into `records.json` next to the bundles. The app carries the bundles as Flutter assets.
The bundles are build output and are not in git.

The interface follows the naming rules of the runner. A uniform block is `uniform Frame { … } cb0;` and is bound by
its name. A texture is `uniform texture2D baseColor; // t0`, with a separate sampler `uniform sampler s0;` and the
line `#define baseColor_S s0` that pairs them. A comparison sampler is `uniform samplerShadow s4;`. A vertex input is
`layout(location = 0) in vec3 vsi0_POSITION0;`, its register, semantic and index in the name.

## App

| Part | Behaviour |
|---|---|
| Camera | Starts at the first camera of the scene. Mouse drag with the left or right button turns it, W, A, S and D move it, Q and E move it down and up, Shift moves faster and the wheel sets the speed. A gamepad moves with the left stick, turns with the right stick and moves down and up with the triggers. |
| Lights | Eight coloured point lights move on ellipses at two heights. The ellipses follow the box of the point lamps of the glTF files when there are two or more, which marks the hall, else the box of the scene. The sun has the direction of the scene's first directional light with an intensity above 0, else a default high sun. Sponza's sun has intensity 0 and would leave the ground floor in the shade of the roof. |
| Loop | A ticker steps the camera and the lights with the step of `FramePace`, builds the frame and records it on the runner while the GPU has fewer than two frames in flight. `GcPacing` and the Metal frame limiter run as in a game. |
| Panel | F1 shows `DebugPanelShell`: header lines with the frame rate, the draws and the GPU time, the frame graph, then sections for the lights, the sun, exposure, the shadow map size, the camera speed and the credits. |
| Credit | The credit line of the model shows at the bottom of the view for the first ten seconds and in the panel. |

### Headless mode

`--smoke` renders fixed frames without input: each camera of the scene, or three default views when it has none, at
1280 by 720 with the lights at fixed times. It reads back each frame, writes it as a PNG into `smoke/last` of the data
directory and compares it with the reference of the OS in `smoke/<os>`. A frame passes when its hash matches. It also passes when no
more than 0.1 % of its pixels differ by more than 2 levels in any channel, which covers the drivers that round
differently between runs. `--smoke --record` writes new references. The app exits with 0 when every frame passed and
prints one `SMOKE` line per frame. The references are renders of the model and stay in the data directory with it.
The window stays small and does not take focus, as gpu_smoke does.

### Performance mode

`--perf=<seconds>` flies a fixed path through the hall at 1920 by 1080 and writes the frame times with
`FrameProfiler`: `frames.jsonl` per frame, `summary.txt` with p50, p95 and the maximum of each section. It prints a
summary line with the frame interval, the CPU time to build and record and the GPU time. `--shot=<png>` lays the view
out at 1600 by 900 points, with the panel open when `--panel` is given, and writes it after a few seconds.

## Platforms

The app runs on Metal on macOS and on Vulkan on Linux and Windows, on the patched engine. The Linux and Windows
runners turn on Impeller and Flutter GPU and take `--background` for the small window that does not take focus. The
checks are a release build and the headless mode on each platform, with the performance mode on the Mac and on the
workstation's RTX GPU under the headless GNOME Shell.

## Allocation

The builder keeps every draw, block and list. Its per-frame entry writes floats into kept bytes and sorts the blended
draws in a kept list. The camera and light updates of the app work on kept vectors and the trigonometry
of `prismarine_math`. The gamepad is read in place with `HostPads.readInto`. The alloc lint lists the builder's frame
entry and the tickers of the app as roots and reads `prismarine_scene`, `prismarine_pbr` and the app. A place that must allocate, such as the image of the presented
frame, carries `// alloc: <reason>`.

## Risks

- The 16-bit index rule of the runner forces the split into chunks. The ivy alone gives about 48 chunks, which is
  fine for the CPU cost of a draw on the patched engine.
- 4K textures scaled to 1024 lose detail up close. `--texture-size=2048` gives more detail for about four times the
  memory.
- Frames differ between GPUs and drivers. Metal on an Apple GPU and Vulkan on an RTX GPU differ by one to two levels
  on average, with up to 16 % of the pixels more than two levels apart. The references are per OS and machine and the
  tolerance covers rounding, not a changed picture.
- The download depends on Intel's servers and their signed links, which expire after a few minutes. The script asks
  for a new link before each file and resumes files that are complete.
