# prismarine — a toolkit for games on Flutter and Dart

Generic engine code, moved out of mcsm (the Minecraft: Story Mode port) unit by unit; mcsm builds on it through a pinned git dependency.

## Read first
- [docs/memory/state.md](docs/memory/state.md): where prismarine is now.
- [docs/memory/decisions.md](docs/memory/decisions.md): what is decided.
- [docs/specs/2026-11-23-prismarine-split-design.md](docs/specs/2026-11-23-prismarine-split-design.md): the split from mcsm, its packages, gates and migration steps.
- mcsm's `docs/memory/rules.md` binds work here too (shared machines, git and landing, verification, engineering) until prismarine has its own rules page.

## Hard rules
- No game data in this repo, and no game names in code, identifiers or package names; docs name mcsm only as where code came from. The one exception is the logo (the owner's, 2026-11-23).
- A moved file is moved verbatim; mcsm's outputs (D1 frames and audio, corpus, slices) stay byte-identical across every step.
- Commit by pathspec only; commits carry no Co-Authored-By or Claude trailer.
- Code files stay under 1,000 lines; comments say why, cite sources as tags, carry no history.
- Update the file that owns a fact; rewrite, don't append; history belongs in git.
