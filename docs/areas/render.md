# prismarine_render

The package records frame plans of `prismarine_frame` on Flutter GPU. A `FrameRunner` creates the plan's targets and
buffers, then records each pass on one command buffer with each shader's constant blocks, textures, samplers and texel
buffers bound by name. It keeps what stays the same from frame to frame: a draw's pipeline and bindings, the blocks
that do not change and the passes whose retained stamp is unchanged. It needs the engine fork's flutter_gpu, which the
package's pubspec takes from `third_party/flutter_gpu`. `onGpuSubmit` receives the number of each command buffer that
the runner submits, before the submit, for a GPU pass log.

Flutter GPU has no timestamp queries. For the GPU time of parts of a frame you set `timedParts` to the passes that
start a part. The runner records each part into a command buffer of its own and submits them in order after the last
one. `lastPartGpuMs` then holds the time of each part of the last finished frame, the part before the first listed
pass first. A part is the time from the completion of the command buffer before it to its own completion, which
includes the latency of the completion handler, a few tens of µs. A part costs one more submit on the CPU.

A draw's `frontCounterClockwise` counts the winding on the render target with y down, as Direct3D does. The
counter-clockwise front faces of glTF and OpenGL in clip space are clockwise there and need `false`, the default.

## Assets

The runner asks a `RenderAssets` of your application for everything that a plan names by string: shaders by id with
their `ShaderRecord`, textures by stem and meshes by stem as a `RenderMesh`. Your implementation loads them on first
use and keeps them until a `release` after a scene closed. `RunnerShaders` gives the ids of the shaders that the runner
draws with besides a plan's own: an empty pixel shader, a pixel shader that clamps depth and the pair that copies a
stencil into a texture.

## Pulled passes

With a `Pulled` set, the runner draws the passes that its `PulledLayout` lists in pulled form. Their draws go into
rows of a cooked scene, which the GPU culls and draws by bucket. The layout gives the names that the runner reads a
draw by, such as the blocks of the camera, the object, the instance and the material, the material textures and the
object and instance rows of `prismarine_frame`. Material textures are named by a prefix and a number, or by a list of
names when the programs name them by their function; a texture's layer slot is its number or its place in the list.
With `keepOrder` a bucket holds one run of draws with the same key, so the buckets draw in the plan's order, for a game whose opaque draws test depth less-or-equal without a prepass. A draw left to its own record then ends the run before it and is drawn between the buckets made before and after it, and blended draws are pulled too, since their runs keep their place. A file texture that no array of the scene holds (a swapped texture, another scene's) binds as an array of its own, its plain texture viewed as one layer. A layout's `unculled` passes have draws with cameras of their own, such as a shadow atlas with a camera per tile: their buckets draw every cluster instead of culling by one view. The layout also gives the function that makes a view's frustum planes, which must be the builder's.

| Variable | Effect |
|---|---|
| `PRISMARINE_PULLED_MAIN` | `1` draws the layout's main pass in pulled form too. |
| `PRISMARINE_PULLED_ONLY` | A comma-separated list of label parts. Only the draws whose label holds one are pulled. |
| `PRISMARINE_PULLED_STATS` | `1` logs the time of the pulled passes' preparation every 120 preparations. |
| `PRISMARINE_RETAIN` | `off` records every pass, retained or not. |
| `PRISMARINE_FIRST_FRAME` | `off` makes no pulled forms and pipeline states ahead of a draw's first frame. `pulled` or `states` makes only the one. |
| `PRISMARINE_RENDER_TRACE` | `1` logs each draw as it is recorded. |
| `PRISMARINE_RENDER_PASS_LOG` | A file that receives the last frame's GPU work, an encoder a line. |
| `PRISMARINE_FRAME_LOG` | Set, logs what each run did for the first time. |

Each variable also reads its `MCSM_` form, such as `MCSM_PULLED_MAIN`, when the `PRISMARINE_` form is not set.

## Checks

Run `flutter test` in `packages/prismarine_render`.
