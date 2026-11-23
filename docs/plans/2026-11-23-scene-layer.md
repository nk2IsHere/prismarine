# Plan: the slim scene layer

From [the scene layer design](../specs/2026-11-23-scene-layer-design.md). The work is on branch `prismscene` in both
repositories. The coordinator merges prismarine first, then mcsm with the pin on the prismarine tip. The glTF code of
the sample, `GltfDocument` and `GltfModel`, is merged into the branch before steps 2 and 6.

## prismarine

1. `prismarine_scene` gets the GPU helpers. `gpuBackend` and `gpuFeatures`, `ScreenCopy` with its two shaders and the
   build hook in `build_hooks.dart`. A test runs the hook's pure parts: the backend choice, the include scan and the
   viewport index edit of a Metal source.
2. `prismarine_scene` gets `SceneNode` and `importSceneNodes` on `GltfDocument`. `GltfModel` reads its draws, cameras
   and lights from the nodes. Its tests pass unchanged. New tests cover TRS and matrix nodes, the world transform after
   a change, documents without scenes and extras. `GltfDocument` gets sparse accessors with a test.
3. `prismarine_render` calls `onGpuSubmit` before each submit of the runner. The area pages of render and debug say
   that the GPU pass log takes it.
4. gpu_smoke builds its bundle with `buildShaderBundle`, draws its copy with `ScreenCopy` and keeps the engine calls of
   its checks in its own file. `tool/scene.sh` and `flutter_scene_generated/` go. A macOS build and run of gpu_smoke
   and a Linux run on the workstation pass.
5. Docs. The area page of the scene layer is rewritten, the split design's "Later" item and the state are updated.

## mcsm

6. `tt_meshes.dart` packs on `GltfDocument`. A scratch test compares every primitive of every mesh and rig of every S1
   slice with the packing of flutter_scene before the copy goes.
7. The 22 GLSL files that the cooked S1 programs include are copied into `mcsm_look_scene/shaders/scene/`. The cook
   includes that folder. The treehouse is cooked into a private folder twice and compared with the live slice byte
   for byte.
8. `shared_targets.dart` decodes and uploads S1's PNGs itself. The unused `PassRun` goes.
9. The player drops the node tree of its hosts, the binding and its tests, the camera of flutter_scene and the
   diagnostics of flutter_scene's drawing. The frame history copies with `ScreenCopy`. The GPU pass log takes
   `onGpuSubmit`. The backend log line reads `gpuBackend` and `gpuFeatures`.
10. `mcsm_slice_scene` keeps its camera maths and paths. Its loader and runtime agents go.
11. `third_party/flutter_scene` goes. The scripts, the CI workflow and the docs follow. The pin moves to the prismarine
    tip.

## Checks per step

Each step runs the tests of the packages it touches, analyze, format, code_shape and the alloc lint in both
repositories. Steps 6 to 8 change code on the path of D1 frames. Each is its own commit. The coordinator runs D1 and the
gate on the result.
