# Plan: the sample scene

From [the sample scene design](../specs/2026-11-23-sample-scene-design.md). One branch, one landing in prismarine.
mcsm does not change.

## Steps

1. **Assets.** `prismarine_assets` gets `GltfDocument` with accessor reads, `readKtx2`, mip generation and
   `prepareGltf`, with tests on generated glTF files: a primitive with 32-bit indices and 70,000 vertices splits into
   chunks that draw the same triangles, missing tangents are made, KTX2 files read back what `encodeKtx2` wrote.
2. **Fetch.** `apps/prismarine_sample/tool/fetch.dart` downloads the glTF part of each package by range requests,
   checks the CRC of each file, keeps `credits_license.txt` and runs `prepareGltf`. A test reads a local zip through
   the same reader.
3. **Shader interface.** `prismarine_shaders` gets `shaderInterface`, tested against `ShaderRecord` on sources of
   each naming rule.
4. **Scene on the GPU.** `prismarine_scene` gets `GpuScene`: buffers, KTX2 textures, the draw list with world
   matrices and bounds, cameras and lights. Its tests run the parts that do not need a GPU.
5. **Renderer.** `prismarine_pbr`: the GLSL with its bundle tool, `PbrAssets`, the builder with its kept draws and
   frame role, sorting of blended draws and the retained shadow pass. Tests check the plan of a generated scene
   without a GPU: passes, targets, the order of draws, the bytes of the frame role and no allocation per frame in the
   alloc lint.
6. **App.** The view, the fly camera, the gamepad, the loop, the debug panel and the credits. The runners of Linux and
   Windows turn on Impeller and Flutter GPU and take `--background`. The macOS runner takes it too.
7. **Smoke and performance.** `--smoke` with `--record`, `--perf=<seconds>`. A `tool/smoke.sh` builds the shaders,
   builds the app and runs the headless mode for the gate.
8. **Platforms.** macOS on a Mac slot: build, smoke, perf, screenshots. Linux on the workstation in the
   `mcsm-linux-player` container, run on the RTX under the headless GNOME Shell: build, smoke, perf, screenshots.
   Windows: a release build on the VM if it is free.
9. **Docs.** A page for `prismarine_pbr` in `docs/areas/`, the new parts in the pages of assets, shaders and scene,
   the README of the sample, `state.md` and the alloc roots.

## Checks

The tests of every package touched, the lints (privacy, links, code_shape, alloc, analyze and format), the headless
mode on macOS and Linux, and the screenshots in mcsm's `data/evidence/prismsample/`.

## At landing

The gate in the private repo gains two steps after the sample build: the shader build of the sample and
`--smoke` on the Mac. Both need the prepared scene in `PRISMARINE_SAMPLE_DATA` on the machine of the gate.
