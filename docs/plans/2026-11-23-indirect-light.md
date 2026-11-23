# Plan: indirect light

From [the indirect light design](../specs/2026-11-23-indirect-light-design.md). One branch, one landing in prismarine.
mcsm does not change.

## Steps

1. **Voxel copy.** `buildGiVolume` in `prismarine_pbr`: voxelisation of the glTF files with base colours from small
   mips, the distance passes, the flood fill, the probe grid with moved probes and the list of probes that are on.
   Tests on a generated glTF of a closed box with a wall: the marked cells, the distances, the solid cells inside the
   wall and the probes moved out of it.
2. **Targets and blocks.** `PbrGiSettings` with the presets, the `Indirect` block, the new targets and the MRT of
   `opaque`. The lit shaders write the three targets. A `lit_blend.frag` variant keeps one target. Tests of the plan
   without a GPU: passes per switch, targets, the bytes of the block.
3. **Sky.** `gi.sky`, its mips, `gi.skySpecular`, `gi.skyIrradiance`, `gi.brdf` and the `sky` pass, retained by a
   stamp of the sun and the sky settings.
4. **Indirect pass.** `indirect` with the sky irradiance and the prefiltered sky, as the first visible result.
5. **Probes.** `gi.trace`, `gi.blend`, `gi.copy` and `bodies/gi_probes.glsl` in `indirect` and in the blended
   shader. The probe view of `debugView`.
6. **Occlusion.** `ao` and `aoBlur`.
7. **Reflections.** `ssr` and the `history` mips.
8. **Sample.** The voxel copy at load, a "Global illumination" section of the panel with the switches, the quality,
   the debug views and the sliders, and options `--gi=off`, `--quality=<preset>` and `--debug-view=<view>` for
   pictures.
9. **Measure and tune.** Frame times at 1920 by 1080 on the Mac and on the RTX for each preset and with each effect
   off. The defaults follow the measurement.
10. **Pictures.** Before and after pictures from the cameras of the scene on Metal and Vulkan, and a path-traced
    reference of one camera from Blender's Cycles on a copy of the prepared scene with PNG textures. They go into
    mcsm's `data/evidence/demogi/`.
11. **Docs.** The page of `prismarine_pbr`, the README of the sample, `goals.md`, `state.md` and the alloc roots.

## Checks

The tests of `prismarine_pbr` and of the sample, the lints (privacy, links, code_shape, alloc, analyze and format),
the smoke mode on macOS and Linux with new references, and the performance mode on both.

## At landing

The smoke references of the sample change on every machine. The coordinator records them again with
`--smoke --record` after the landing.
