---
name: goals
description: Work wanted in prismarine that no current step covers, one entry each, removed when done
type: project
---

# Goals

Each entry is wanted work that no plan covers yet. A done entry is removed. The order of the next steps is in
[state](state.md).

## Renderer

- **Global illumination and reflections.** Image-based light, reflections and a form of global illumination for the
  generic renderer.
- **Bloom and anti-aliasing.** Bloom, and anti-aliasing beyond what the hardware gives.
- **Point light shadows.** Shadows for point lights. The sample renderer casts shadows from the sun only.
- **Texture compression.** A BC encoder for prepared textures, which are RGBA8 with mips today.
- **Skinning and animation.** Skinned meshes and animation playback in the generic renderer.

## Packages

- **One PNG encoder.** `prismarine_debug` and `prismarine_assets` each have an `encodePng`, with different
  compression levels and formats. One encoder with options replaces both.
- **Memory readings on every OS.** `physFootprint` returns no value outside macOS, and the window surface reader runs
  on macOS only. Both need real paths on Linux and Windows.
