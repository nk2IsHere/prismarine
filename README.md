<img alt="prismarine" src="docs/logo/lockup.png" height="96">

# prismarine

A toolkit for making games with Flutter and Dart.

- A renderer on Flutter GPU: frames described as plans of passes, recorded without per-frame allocation.
- A patched Flutter engine: faster GPU draws, compute, texture arrays and 3D textures, Vulkan on Linux and Windows.
- Jobs on worker isolates, with thread priorities per OS.
- Collections that keep their storage, for allocation-free frames.
- Snapshots of object graphs, and deterministic replay.
- Audio output and decoding, gamepads, a real-time loop with frame and GC pacing.
- Debug tools: frame history, a profiler, glitch capture.

BSD-3 licensed.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo/flutter/built_with_flutter_white.svg">
  <img alt="Built with Flutter" src="docs/logo/flutter/built_with_flutter.svg" height="40">
</picture>
