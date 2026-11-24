---
name: goals
description: Work wanted in prismarine that no current step covers, one entry each, removed when done
type: project
---

# Goals

Each entry is wanted work that no plan covers yet. A done entry is removed. The order of the next steps is in
[state](state.md).

## Renderer

- **Shadowed point lights in the probes for every light.** The rays of the probes see the shadows of the point lights
  that have a slot in the atlas, two by default. The light of the others reaches the probes through walls.
- **Moving geometry in the indirect light.** The voxel copy is made once at load. Moving objects need a copy that the
  GPU updates.
- **Texture compression.** A BC encoder for prepared textures, which are RGBA8 with mips today.
- **Skinning and animation.** Skinned meshes and animation playback in the generic renderer.
- **A runner without allocation per frame.** About 70 places of `prismarine_render` in the alloc lint run each frame.
  They are the async run with its Completer, Stopwatch and completion closure, the present copy regions, a ByteData and
  a BufferView per uniform emplace, flush and pulled buffer, the cull uniform and the prepared record of a pulled pass,
  the string keys of target views, the stencil copy pass and the read-backs. Kept views and records would remove most.

## Audio

- **The Dart render without allocation.** The Dart render of the audio engine counts 547 places in the alloc lint. Its
  rewrite, step 5 of [the audio plan](../plans/2026-11-23-audio-engine.md), brings the count to the starts of
  instances.
- **A JSON form of audio projects.** A game builds a project in code today. A JSON form with defaults for the fields
  of behaviour lets sound designers edit projects without code.

## Packages

- **The window surface reader on Wayland.** `WindowSurfaceReader` reads a GTK window on X11 only. A window on a
  Wayland display of GDK has no reader.
- **Unboxed Lua numbers.** The stack of `prismarine_lua` holds every number as a boxed double, and a Lua-heavy frame
  spends much of its time there. A stack of numbers beside the stack of values would remove the boxes.
