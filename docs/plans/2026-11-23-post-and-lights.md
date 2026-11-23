# Post-processing and lights

The steps of [the design](../specs/2026-11-23-post-and-lights-design.md). Each step ends with the tests of the
touched packages, the alloc lint, code_shape and analyze. Steps 3 to 7 end with a look at the sample on Metal and on
Vulkan and with pictures of the change in the evidence folder of the work.

1. **Timed parts.** `FrameRunner.timedParts` and `lastPartGpuMs` in `prismarine_render`, with a test of the split
   into command buffers without a GPU where the runner allows it. The completion callbacks are made once.
2. **Settings and the post module.** `PbrQuality`, `PbrToneMap`, the settings groups `post`, `pointShadows` and
   `volume`. `PbrPost` makes the targets and passes after the scene. The tone map pass moves from the builder into it
   with the four tone maps and manual exposure. Builder tests for the pass lists of each switch.
3. **Exposure.** The histogram, adapt and keep computes, the exposure targets and the reset.
4. **TAA.** The jitter in `_writeFrame`, `jitter`, `previousViewProjection`, `frameIndex` and `resetHistory` on the
   builder, the resolve pass and the history as the second target of the tone map pass, the mip bias of the material
   sampler.
5. **Bloom.** The down and up chain and the mix in the tone map pass.
6. **Point light shadows.** The atlas, the light slots, the face matrices, the kept draw lists with culling,
   `bodies/point_shadow.glsl` and the lookup in the lit shader.
7. **Volumetric light.** The froxel targets, the inject and integrate computes and the apply pass.
8. **The sample.** The panel sections for each effect with its switch and quality, the timed parts in the frame graph,
   the smoke test with resets and 16 frames per view, the performance run with each effect on and off.
9. **Measure and tune.** Frame times at 1920 by 1080 on the Mac and on the RTX with each effect off and on at each
   quality. The defaults that keep 120 Hz on the Mac and 60 Hz on the RTX. The pbr area page, the sample README, the
   goals and the state.
