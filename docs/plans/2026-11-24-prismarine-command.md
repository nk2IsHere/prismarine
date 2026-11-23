# Plan: the prismarine command

From [the prismarine command design](../specs/2026-11-24-prismarine-command-design.md). The work is on branch
`prismcli` of prismarine. mcsm does not change.

1. `prismarine_shaders` gets `programRecords`, the interfaces of a program tree with includes and `#ifdef` blocks
   resolved, with a test on a small tree.
2. `prismarine_cook` gets the project file, the engine locator with the search for the export, the shader cook and the
   asset steps with their stamps and `cookHook`. Its tests cover each part with faked engine folders.
3. `prismarine_cli` gets the commands, the checks of doctor behind a faked process runner and the paths of the built
   app. The launchers `bin/prismarine` and `bin/prismarine.bat` start it from a kernel snapshot.
4. `prismarine_scene` gets `engine_check.dart` and `prismarine_pbr` gets `pbrEngineFeatures` and the message for a
   missing shader. A test compares `prismarineEngineRelease` with `RELEASE`.
5. The sample gets `prismarine.yaml` and its hook and calls `requireEngine`. `tool/shaders.sh` and
   `tool/build_shaders.dart` of `prismarine_pbr` go.
6. Docs: `docs/building.md`, the sample README, the root README, the toolchain README and area page, the pbr and
   shaders pages, an area page for the command, state and the CI workflow paths.
7. Checks: the tests of every touched package, analyze, format, code_shape and the alloc lint. A fresh clone on macOS
   and on Linux runs `prismarine run` from nothing. A stale bundle and an old engine are shown to stop with their
   messages.

The landing gate in the private repository runs `bin/prismarine cook apps/prismarine_sample` in place of
`tool/shaders.sh`. The coordinator changes it at landing.
