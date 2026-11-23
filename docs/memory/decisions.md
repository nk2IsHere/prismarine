---
name: decisions
description: Product and technical decisions in force for prismarine, one short paragraph each with its date and spec; superseded ones are deleted
type: project
---

# Decisions

Each entry is in force; a superseded decision is rewritten or removed, never struck through.
Specs live in `docs/specs/`; the split from mcsm is [the split design](../specs/2026-11-23-prismarine-split-design.md).

## What prismarine is

- **A toolkit for games on Flutter and Dart (2026-11-21, 2026-11-23, owner).** Everything generic in mcsm (the Minecraft: Story Mode port) moves here, unit by unit, each case decided by the owner against mcsm's inventory; mcsm then builds on prismarine.
  Generic means no Telltale data, no shipped exe's behaviour and no game words in code or names; docs name mcsm only as where code came from.
- **Private, BSD-3 (2026-11-23, owner).** The repo is private for now and licensed BSD-3 from its first commit.
- **Its own private repo (2026-11-23, owner).** `private/` (gitignored) is prismarine's own private repo, separate from mcsm's; the machine notes and privacy patterns it needs are copied in, not shared.

## Layout and naming

- **Packages are `prismarine_<function>` (2026-11-23, owner).** Separate packages, so Flutter-free code stays usable from pure-Dart isolates and tools; no umbrella package.
- **Environment variables are `PRISMARINE_*` (2026-11-23).** A moved variable also reads its old `MCSM_*` name for one release.

## How mcsm uses it

- **A git pin with a local override (2026-11-23, owner).** mcsm pins prismarine's packages by commit as git dependencies; a gitignored `pubspec_overrides.yaml` points them at a local checkout for work across both.
  The coordinator lands both repos: prismarine first behind its gate, then mcsm's pin bump behind mcsm's gate; mcsm never pins an unlanded prismarine commit.
- **Shared machine infrastructure (2026-11-23, owner).** One heavy-job lock, one measure lock and one engine and Flutter SDK directory per machine, used by both repos; the scripts live in prismarine's `tools/machine/`. mcsm's Wine oracle tooling stays in mcsm.

## What moves

- **All generic units move; mixed units split at a seam; specific units stay (2026-11-23, owner).** Per mcsm's inventory: 23 generic units move as they are; 22 mixed units split, each seam cut inside mcsm first and proven byte-identical (D1, corpus), then the generic half moves; runners, app scripts, CI and the workspace root are copied as templates; the 21 Telltale- or exe-specific units stay in mcsm.
- **The engine fork (2026-11-23, owner).** Prismarine owns the patched Flutter engine, its patches, release scripts and flutter_gpu. The `Mcsm*` native exports are renamed to prismarine names at prismarine's first engine release, which also carries mcsm12's patches (Dart old-space compaction at switch holds).
- **The renderer core, now (2026-11-23, owner).** The frame plan format and codec, the builder framework, the GPU runner and the cook model move now (`prismarine_frame`, `prismarine_render`); the game's builders stay in mcsm.
- **A slim scene layer instead of flutter_scene (2026-11-23, owner).** prismarine carries no vendored flutter_scene: a slim glTF importer and scene-node layer on Flutter GPU (`prismarine_scene`) sits under our renderer. Own spec.
- **Lua and audio, redesigned generic (2026-11-23, owner).** The Lua VM becomes an embeddable Lua for Dart (`prismarine_lua`, double numbers by default) and the audio an event and bus engine (`prismarine_audio`); mcsm's exe profiles, FMOD semantics and Telltale bindings become mcsm adapters on them. Own specs.
- **Replay and snapshots are core (2026-11-23, owner).** The snapshot format, route recording and replay, the snapshot schedule, the shadow runner and the corpus runner are a prismarine framework (`prismarine_replay`); games register their state into it. Own spec.
- **The app shell waits for production (2026-11-23, owner).** mcsm's player shell stays in mcsm; `prismarine_app` is designed with production's launcher and common UI.

## Logo

- **The mark (2026-11-23, owner).** The back of a prismarine Colossus's head (head, helmet and the tentacle "beard"), drawn from mcsm's game data at the soldier's texel size: the head in the prismarine soldier's skin, the rest in the Colossus's skin cut to the same grid; its glyph glows; a contact shadow falls from the head onto the beard.
  It is the owner's second, deliberate exception to "no game data in git", covering this logo render only.
- **The lockup (2026-11-23, owner).** The mark, then "prismarine" in Google Sans (OFL; the word "Google" is not used in any name) in a light prismarine colour, as Flutter's lockup; transparent backgrounds, with a darker word for light backgrounds.
- **"Built with prismarine" (2026-11-23, owner).** Games built on it carry a chip in the style of "Built with Flutter": the mark, "Built with" over "prismarine".
