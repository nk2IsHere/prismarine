<img alt="prismarine" src="docs/logo/lockup.png" height="96">

# prismarine

A toolkit for building games on Flutter and Dart: a frame-plan renderer on Flutter GPU and a patched Flutter engine, a job system with per-OS thread roles, allocation-free collections, snapshots and deterministic replay, audio output, gamepads, a real-time loop and debug tools.

It grows out of mcsm (a port of Minecraft: Story Mode), which moves its generic parts here unit by unit ([the split](docs/specs/2026-11-23-prismarine-split-design.md)).

Licensed BSD-3 ([LICENSE](LICENSE)).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo/flutter/built_with_flutter_white.svg">
  <img alt="Built with Flutter" src="docs/logo/flutter/built_with_flutter.svg" height="40">
</picture>

## Logo

`docs/logo/`: the mark (`mark.png`), the lockup (`lockup.png`) and the "Built with prismarine" chip (`built_with.png`, and `built_with_light_bg.png` with a darker "Built with" for light backgrounds) for games built on it; all transparent PNGs.
The mark is rendered from game data, a deliberate exception ([decisions](docs/memory/decisions.md) "Logo"); the word is set in Google Sans (SIL OFL 1.1).
`docs/logo/flutter/` holds Flutter's own "Built with Flutter" lockup (grey and white text), unaltered from Flutter's brand assets (flutter.dev/brand) and used under its rules: never altered, never more prominent than our own mark, a margin of one "F" around it.
