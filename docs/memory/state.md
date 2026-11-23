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
from the same checkout. `templates/scripts/` holds the first app script copied as a template, `universal_app.sh`.
The heavy-job and measure locks of each machine are the scripts in `tools/machine/`, which both repositories use. Steps 9 and 10 are done. `prismarine_loop`, `prismarine_debug`, `prismarine_scene` and
`prismarine_render` are Flutter packages outside the pub workspace. Step 9 adds `prismarine_debug`, the debug tools of
the player of mcsm with the shell of its debug panel. mcsm adds its own sections to the shell. Step 8 adds
`prismarine_audio` and `prismarine_audio_out`, and mcsm's mixer crate is built in place of the crate of
`prismarine_audio_out` and links it.
Step 11 brings the patched engine with its git history from mcsm: `third_party/flutter_engine` at release mcsm11,
`third_party/flutter_gpu` and `tools/gpu_smoke`, described in [engine](../areas/engine.md). mcsm reads the release and
flutter_gpu through its pin. Step 6 adds `prismarine_shaders`, the impellerc bundle build with its shard cache, the
precompiled Metal libraries and a command line. mcsm keeps the settings of its slices and calls it. Step 5 adds
`prismarine_render`, the runner that records frame plans behind a `RenderAssets` interface. Step 7 adds
`prismarine_assets`, the glTF builder and checker, the KTX2 and PNG writers, the BC decoders and the geometry pools
and texture arrays of the cook. GitHub workflows run the lints and the tests for a pull request and by hand, as
[CI](../areas/ci.md) describes. They are not yet enabled on GitHub.
Each package, the lints, the machine locks, gpu_smoke and the sample app have a README. The example of a package is in
its `example/` folder. `check_links` keeps the copy in the README equal to it. The root README has the workspace
setup and the build of the sample app for each platform, checked on macOS and Linux.
