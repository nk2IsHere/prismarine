---
name: state
description: The current state of prismarine on one page, rewritten by every merge that changes it
type: project
---

# State

The decisions are in [decisions](decisions.md). The design of the split is in
[the split design](../specs/2026-11-23-prismarine-split-design.md).

Migration steps 1 to 5 are done. The workspace, the lints with their config, the sample app and the gate in the
private repo are in place. The packages are `prismarine_kept`, `prismarine_snap`, `prismarine_math`,
`prismarine_jobs`, `prismarine_cargo`, `prismarine_pad`, `prismarine_frame` and `prismarine_render`, each with a page
in `docs/areas/`. mcsm pins prismarine by commit and uses these packages. mcsm runs the lints from its pinned checkout
with its own config. It runs the heap and allocation profiler of `tools/profiler`, the package `prismarine_profiler`,
from the same checkout. The `prismarine` command of `bin/`, the package `prismarine_cli`, does every build step on
macOS, Linux and Windows: doctor, the fetch, build, package and publish of the engine, the cook of an app from its
`prismarine.yaml` through `prismarine_cook`, and the build and run of an app. The build scripts, `env.sh` and the
template `universal_app.sh` are gone. An app checks the engine at its start with `requireEngine` of
`prismarine_scene`. The allocation lint also walks `prismarine_render` and `prismarine_loop`. Steps 9 and 10 are done. `prismarine_loop`, `prismarine_debug`, `prismarine_scene` and
`prismarine_render` are Flutter packages outside the pub workspace. Step 9 adds `prismarine_debug`, the debug tools of
the player of mcsm with the shell of its debug panel. mcsm adds its own sections to the shell. Step 8 adds
`prismarine_audio` and `prismarine_audio_out`, and mcsm's mixer crate is built in place of the crate of
`prismarine_audio_out` and links it.
Step 11 brings the patched engine with its git history from mcsm: `third_party/flutter_engine`,
`third_party/flutter_gpu` and `tools/gpu_smoke`, described in [engine](../areas/engine.md). mcsm reads the release and
flutter_gpu through its pin. The first engine release of prismarine, prismarine1, adds the compaction of the old space
on request with the heap figures and gives the exports and the Dart names of flutter_gpu their prismarine forms. Step 6 adds `prismarine_shaders`, the impellerc bundle build with its shard cache, the
precompiled Metal libraries and a command line. mcsm keeps the settings of its slices and calls it. Step 5 adds
`prismarine_render`, the runner that records frame plans behind a `RenderAssets` interface. Step 7 adds
`prismarine_assets`, the glTF builder and checker, the KTX2 and PNG writers, the BC decoders and the geometry pools
and texture arrays of the cook.
`prismarine_replay` follows [the replay design](../specs/2026-11-23-replay-design.md). It holds route recording and
replay with the hash chain, snapshot files with the schedule and pruning, the snapshot shadow and the corpus runner.
mcsm registers its route and snapshot formats and its game on it.
GitHub workflows run the lints and the tests for a pull request and by hand, as
[CI](../areas/ci.md) describes. They are not yet enabled on GitHub.
`prismarine_lua` is Lua 5.2.3 for Dart with double numbers by default and two float32
modes. `prismarine_lua_native` is its compiler in a double and a float32 build, as [lua](../areas/lua.md)
describes. mcsm's exe profiles are configurations of it in mcsm.
The audio engine of [its design](../specs/2026-11-23-audio-engine-design.md) is in `prismarine_audio`, with its Dart
render and in `prismarine_audio_out`, with its native render. mcsm's FMOD bank adapter and sound rules drive it
without a crate of their own. The Dart render without allocation is the next step of its plan.
Each package, the lints, the machine locks, gpu_smoke and the sample app have a README. The example of a package is in
its `example/` folder. `check_links` keeps the copy in the README equal to it. The root README has the workspace
setup and the build of the sample app for each platform, checked on macOS and Linux.
The sample app shows Intel's Sponza, which a script fetches outside git, through the new `prismarine_pbr`, a forward
renderer on `prismarine_render`, with `prismarine_scene` loading the glTF that `prepareGltf` of `prismarine_assets`
writes. Its `--smoke` mode is the smoke test of the gate and its `--perf` mode a performance scene, proven on macOS
and on Linux. The design is in [the sample scene design](../specs/2026-11-23-sample-scene-design.md).
`prismarine_pbr` has TAA, auto exposure, bloom, four tone maps, point light shadows from a cube atlas and froxel fog,
each switchable in the panel of the sample with its GPU time in the frame graph, as
[the post-processing design](../specs/2026-11-23-post-and-lights-design.md) describes. The runner of
`prismarine_render` times parts of a frame by their command buffers. Its indirect light, a procedural sky with
image-based light, irradiance probes traced in compute through a voxel copy of the scene, ambient occlusion and
screen-space reflections, follows [the indirect light design](../specs/2026-11-23-indirect-light-design.md). A
path-traced reference of Sponza in sun and sky light matches it within about a quarter of its brightness.
The slim scene layer of [its design](../specs/2026-11-23-scene-layer-design.md) is in place. `prismarine_scene` has
glTF scene nodes under `GltfModel`, the screen copy, the build hook for shader bundles and the backend of the engine.
The runner of `prismarine_render` calls `onGpuSubmit` for the GPU pass log. mcsm and gpu_smoke use no flutter_scene.
