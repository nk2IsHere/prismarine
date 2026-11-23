# The slim scene layer

This spec replaces the vendored flutter_scene of mcsm with a small layer in prismarine. The decision is in
[decisions](../memory/decisions.md), "A slim scene layer in place of flutter_scene". The layer is `prismarine_scene`,
a Flutter package on Flutter GPU. It holds what a game on prismarine needs from a scene library and nothing of the
look that flutter_scene drew.

## Goals

- prismarine carries no flutter_scene. mcsm drops its vendored copy, flutter_scene 0.24.3 with the patches P0 to P46.
  gpu_smoke drops `tool/scene.sh`.
- `prismarine_scene` holds a glTF scene with its nodes and transforms, a full-screen copy and a build hook for shader
  bundles. The sample and the debug tools use them.
- The outputs of mcsm stay byte-identical. These are the D1 frames and audio, the corpus and the slices. A reslice of
  the S1 treehouse matches the live slice byte for byte.

## Not in scope

- Drawing. The renderer of prismarine draws every frame from a frame plan. The scene layer draws nothing.
- Materials, lights and shadows of flutter_scene, its physics, audio, particles, splats and editor.
- The `.fscene` format. mcsm writes and reads its scene documents with `package:scene`, a pure-Dart package on pub.
  That stays a dependency of mcsm.
- Skinning and animation of glTF. They are goals of the renderer.

## The uses in mcsm

A search of both repositories found these uses of flutter_scene. The player has drawn nothing through it since the
renderer of prismarine draws every frame.

| Use | Where | Reaches the outputs | Outcome |
|---|---|---|---|
| glTF parse and the 72 or 104 byte vertex packing of S1 meshes | `mcsm_look_scene` `tt_meshes.dart` | D1 frames | Packing in mcsm on `GltfDocument` of `prismarine_assets`, the same bits |
| Engine GLSL that the cooked S1 programs include, 22 files | the cook of `tools/mcsm` | slices | Copied verbatim into `mcsm_look_scene/shaders/scene/` with the MIT notice |
| PNG decode and upload of S1 textures | `shared_targets.dart` | D1 frames | The same decode and texture in mcsm |
| Node tree of each scene host, its binding, runtime agents | the player, `mcsm_slice_scene` | none, no caller reads the nodes | Removed in mcsm |
| `PerspectiveCamera` as a value for the review and the frame recorder | the player | debug files | A camera value of mcsm |
| Pipeline stalls, ring hazards, stale images, render target report, joint pool | the player | log lines | Removed, they measure flutter_scene's own drawing |
| Mip workers' thread role | the player | none | Removed, no mip chain is made |
| Full-screen copy for the frame history | the player | debug files | `ScreenCopy` of `prismarine_scene` |
| Submission hook of the GPU pass log | the player | debug files | A submission hook of `prismarine_render` |
| Backend and feature bits of the engine | the player's log, gpu_smoke | log lines | `gpuBackend` and `gpuFeatures` of `prismarine_scene` |
| Build hook, base shaders, engine calls | gpu_smoke | none | The hook and copy of `prismarine_scene`, engine calls in gpu_smoke |

The patches of the old look go with the copy. Among them are P3 (shadow binder), P16 (display tone mapping), P25 (render
textures) and P42 (translucent depth). P1 and P9 backed byte-identical captures of the old drawing path. The renderer
does not use that path. The camera maths that P9 made portable are kept where mcsm still checks against them.

## glTF scenes

`GltfDocument` of `prismarine_assets` is the one glTF reader of prismarine. It reads `.gltf` and `.glb` files with
their buffers and reads accessors as floats or unsigned integers. Normalized integers become values from 0 to 1, or
from -1 to 1 when signed. For dense accessors these are the same bits as the reads of flutter_scene's importer. Sparse
accessors are added to it.

`prismarine_scene` adds scene nodes on it. `SceneNode` has a name, a local transform from a matrix or from translation,
rotation and scale, its children and its parent. A node keeps its world transform and computes it again only after its
local transform or an ancestor changed. A node refers to a mesh, a camera, a light and a skin of the document by index
and keeps its `extras`. `importSceneNodes` returns the roots of the default scene. A document without scenes gives
every node that is no child as a root.

`GltfModel` reads its draws, cameras and lights from these nodes. Its outputs and its tests stay the same. A vertex
layout is the choice of a renderer. The layer gives the accessor reads and the nodes and packs no vertices.

The matrices are double precision, as `GltfModel` has them.

## GPU helpers

`ScreenCopy` draws a texture over the whole target. Its vertex stage takes two triangles of 2D clip-space positions.
Its fragment stage samples `source_texture`. It has a `pipeline` and the `source` slot, the form that the frame history
of `prismarine_debug` takes.

`gpuBackend` reads the backend of Flutter GPU from the engine, `metal` or `vulkan`. It is null on an engine without
the call. `gpuFeatures` reads the feature bits of the patched engine, 0 on another engine.

`package:prismarine_scene/build_hooks.dart` has `buildShaderBundle` for the build hook of a package. It compiles the
bundle of a manifest with `flutter_gpu_shaders`, keeps the backends of the target, gives a vertex output
`mcsm_viewport_index` the viewport index attribute on Metal and adds precompiled Metal libraries on macOS with
`prismarine_shaders`. Every file that a shader of the manifest includes is a dependency of the hook. The bundle is
written to `build/shaderbundles/` of the package, which the package lists as an asset. `ScreenCopy` uses it for its own
two shaders and gpu_smoke for its smoke bundle.

The runner of `prismarine_render` calls `onGpuSubmit` with a running number before each command buffer it submits.
The GPU pass log of `prismarine_debug` takes it.

## mcsm

The player keeps its scene hosts as the lifecycle of the shown scene and the prefetch of the agents' entries. It loads
no `.fscene` into nodes and has no binding. Its camera for the review and the frame recorder is a value with eye,
target, up, field of view and clip planes. The test that pins the camera of the renderer to the old camera keeps its
reference maths in the test.

`tt_meshes.dart` packs each primitive as before. Position, normal, two UV sets, colour and tangent, then joints and
weights for a skinned primitive. A primitive without normals gets flat normals on unshared vertices. Z is negated and
the winding swapped. A missing colour is opaque white. A test compares the bytes with the old packing on every mesh of
the treehouse slice before the copy goes.

The cook includes `mcsm_look_scene/shaders/scene/` in place of the shader folder of flutter_scene. The file names, the
order of the include folders and the entry names stay the same.

## Checks

- The tests of `prismarine_scene`, `prismarine_assets`, `prismarine_render`, `prismarine_debug` and gpu_smoke's build
  on macOS and Linux.
- In mcsm, the tests of every touched package, analyze, format, code_shape and the alloc lint.
- The S1 mesh bytes against the old packing, before the copy is deleted.
- The cook of the treehouse into a private directory, compared byte for byte with the live slice. The second run starts
  from an APFS clone of the shader cache of the first.
- The coordinator runs D1 and the gate.

## Risks

- A cooked program that embeds a source path would change the slice. The reslice check catches it.
- The node tree of the player could have a reader that the search missed. The analyzer of mcsm finds any after the
  removal.
- The build hook writes into the package directory. In a pub cache that directory is per commit, as it is for any git
  dependency.
