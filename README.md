<img alt="prismarine" src="docs/logo/lockup.png" height="96">

prismarine is a toolkit for making games with Flutter and Dart. It provides a renderer on Flutter GPU, a patched
Flutter engine and the parts that a real-time game needs around them, from worker threads to deterministic replay.
Every part runs on macOS, Linux and Windows.

## Packages

| Package | Contents |
|---|---|
| `prismarine_frame` | Frame plans of passes, targets and buffers, with a codec that moves a plan between isolates |
| `prismarine_render` | The runner that records a frame plan on Flutter GPU and skips a pass whose inputs are unchanged |
| `prismarine_scene` | A glTF importer, a scene-node layer and paced loading of assets |
| `prismarine_shaders` | Shader bundles for impellerc, a cache of compiled shaders and precompiled Metal libraries |
| `prismarine_assets` | Readers and writers for glTF, KTX2 and PNG, with decoding of BC textures |
| `prismarine_jobs` | A pool of worker isolates with priorities and cancellation, thread roles per OS and a check of free memory |
| `prismarine_kept` | Maps, sets and lists that keep their storage when cleared |
| `prismarine_snap` | Binary snapshots of object graphs that preserve the references between objects |
| `prismarine_replay` | Recording of input, deterministic replay and a schedule of snapshots |
| `prismarine_math` | Maths functions that give the same bits on every OS |
| `prismarine_lua` | An embeddable Lua 5.2 for Dart |
| `prismarine_audio` | Audio interfaces and an engine of events and buses |
| `prismarine_audio_out` | Audio output, decoding of MP3 and Vorbis and a cache of decoded sounds |
| `prismarine_pad` | Gamepads through SDL3 |
| `prismarine_loop` | Frame pacing, GC pacing, a frame limiter, window focus, cursor capture and mouse look |
| `prismarine_debug` | Frame history, a profiler per frame, a log of GPU passes, glitch capture and a debug panel |
| `prismarine_cargo` | A build hook that compiles the Rust crate of a package |

## Engine

The patched Flutter engine extends Flutter GPU with cheaper draws, retained draws, multiple render targets,
instancing, compute, texel buffers, texture arrays and 3D textures. It adds Vulkan for Linux and Windows. The Dart VM
gets collections at idle points of the frame and heap figures for the debug tools.

## Platforms

prismarine draws through Metal on macOS and through Vulkan on Linux and Windows. OpenGL ES is not supported.

## Tools

The repository carries the lints that keep frames free of allocation, a heap and allocation profiler, a GPU smoke
tool that checks the features of the engine on a machine and the release scripts of the engine.

## Licence

prismarine is licensed under the [BSD-3 licence](LICENSE).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo/flutter/built_with_flutter_white.svg">
  <img alt="Built with Flutter" src="docs/logo/flutter/built_with_flutter.svg" height="40">
</picture>
