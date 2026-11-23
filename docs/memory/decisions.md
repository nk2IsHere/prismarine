---
name: decisions
description: Product and technical decisions in force for prismarine, one short entry each with its date
type: project
---

# Decisions

Each entry is in force. A superseded decision is rewritten or removed. Designs are in `docs/specs/`. The split from
mcsm is in [the split design](../specs/2026-11-23-prismarine-split-design.md).

## Purpose

- **A toolkit for games on Flutter and Dart (2026-11-21, 2026-11-23).** Every generic part of mcsm moves here. The
  owner decides each unit against the inventory of mcsm. mcsm then builds on prismarine. A generic part reads no
  Telltale data, reproduces no behaviour of a shipped exe and has no game words in its code or names.
- **Private, BSD-3 (2026-11-23).** The repository is private for now. It carries the BSD-3 licence from its first
  commit.
- **A private repository of its own (2026-11-23).** `private/` is ignored by git and holds a separate repository for
  prismarine. Machine notes and privacy patterns are copied into it from mcsm and are not shared.

## Layout

- **One package per function (2026-11-23).** Packages have the form `prismarine_<function>`. Code without Flutter
  stays usable from pure-Dart isolates and tools. No umbrella package exists.
- **Environment variables (2026-11-23).** Variables have the form `PRISMARINE_*`. A moved variable also reads its old
  `MCSM_*` form for one release.

## Use from mcsm

- **A pinned git dependency (2026-11-23).** mcsm depends on prismarine packages through git, pinned by commit. A
  `pubspec_overrides.yaml`, ignored by git, points them to a local checkout for work across both repositories. The
  coordinator merges prismarine first, behind its gate. The pin bump in mcsm follows, behind the gate of mcsm. mcsm
  does not pin a prismarine commit that is not on `main`.
- **Shared machine infrastructure (2026-11-23).** Each machine has one heavy-job lock, one measure lock and one
  directory for the engine and the Flutter SDK. Both repositories use them. The scripts are in `tools/machine/` of
  prismarine. The Wine oracle tools stay in mcsm.

## Units that move

- **Generic units move, mixed units split, specific units stay (2026-11-23).** The 23 generic units of the inventory
  move as they are. The 22 mixed units split at a seam. Each seam is cut inside mcsm first and proven byte-identical
  with D1 and the corpus. The generic half then moves. Runners, app scripts, CI and the workspace root are copied as
  templates. The 21 units that are specific to Telltale or to an exe stay in mcsm.
- **The engine fork (2026-11-23).** prismarine owns the patched Flutter engine with its patches, its release scripts
  and flutter_gpu. The engine fork moves with its git history from mcsm, which keeps the history of every patch. The
  first engine release of prismarine renames the `Mcsm*` native exports to prismarine forms. The same release carries
  the patches of mcsm12, the compaction of the Dart old space at switch holds.
- **The renderer core, now (2026-11-23).** The frame plan format and its codec, the builder framework, the GPU runner
  and the cook model move now, into `prismarine_frame` and `prismarine_render`. The builders of the game stay in mcsm.
- **A slim scene layer in place of flutter_scene (2026-11-23).** prismarine carries no vendored flutter_scene. A slim
  glTF importer and scene-node layer on Flutter GPU, `prismarine_scene`, is under the renderer. It gets its own spec.
- **Generic Lua and audio (2026-11-23).** The Lua VM becomes an embeddable Lua for Dart, `prismarine_lua`, with double
  numbers by default. The audio becomes an event and bus engine, `prismarine_audio`. The exe profiles, the FMOD
  behaviour and the Telltale bindings become adapters in mcsm. Each gets its own spec.
- **Replay and snapshots in the core (2026-11-23).** The snapshot format, route recording and replay, the snapshot
  schedule, the shadow runner and the corpus runner form a framework, `prismarine_replay`. A game registers its own
  state with it. It gets its own spec.
- **The app shell with production (2026-11-23).** The player shell stays in mcsm. `prismarine_app` is designed
  together with the launcher and the common UI of production.

## Logo

- **The mark (2026-11-23).** The mark shows the back of the head of a prismarine Colossus, with its helmet and its
  tentacle beard. It is drawn from game data at the texel size of the prismarine soldier. The head has the skin of the
  soldier. The other parts have the skin of the Colossus reduced to the same grid. Its glyph glows. A contact shadow
  falls from the head onto the beard. The mark is the one exception to the rule against game data in git.
- **The lockup (2026-11-23).** The lockup is the mark followed by the word "prismarine" in Google Sans, in a light
  prismarine colour on every background, in the style of the Flutter lockup. The font has the OFL licence. The
  word "Google" is not part of any name of ours. The backgrounds are transparent.
- **Built with prismarine (2026-11-23).** A game built on prismarine carries a chip in the style of "Built with
  Flutter". The chip is the mark with "Built with" above "prismarine".
