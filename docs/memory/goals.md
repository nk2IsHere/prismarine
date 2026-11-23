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

## Audio

- **The Dart render without allocation.** The Dart render of the audio engine counts 547 places in the alloc lint. Its
  rewrite, step 5 of [the audio plan](../plans/2026-11-23-audio-engine.md), brings the count to the starts of
  instances.
- **A JSON form of audio projects.** A game builds a project in code today. A JSON form with defaults for the fields
  of behaviour lets sound designers edit projects without code.

## Packages

- **One PNG encoder.** `prismarine_debug` and `prismarine_assets` each have an `encodePng`, with different
  compression levels and formats. One encoder with options replaces both.
- **Memory readings on every OS.** `physFootprint` returns no value outside macOS, and the window surface reader runs
  on macOS only. Both need real paths on Linux and Windows.
- **Unboxed Lua numbers.** The stack of `prismarine_lua` holds every number as a boxed double, and a Lua-heavy frame
  spends much of its time there. A stack of numbers beside the stack of values would remove the boxes.
