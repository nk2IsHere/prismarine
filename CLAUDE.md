# prismarine

prismarine is a toolkit for making games with Flutter and Dart. mcsm uses it through a git dependency pinned by
commit.

## Read first

- [docs/memory/state.md](docs/memory/state.md) has the current state.
- [docs/memory/decisions.md](docs/memory/decisions.md) lists the decisions in force.
- [docs/memory/rules.md](docs/memory/rules.md) and [docs/memory/writing.md](docs/memory/writing.md) are the rules for
  all work here.
- [docs/specs/2026-11-23-prismarine-split-design.md](docs/specs/2026-11-23-prismarine-split-design.md) is the design
  of the split from mcsm, with its packages, gates and migration steps.

## Hard rules

- The repository holds no game data except the logo. Code, identifiers and package names hold no game names.
- A moved file keeps its content. The outputs of mcsm, its D1 frames and audio, its corpus and its slices, stay
  byte-identical across every step.
- A commit takes explicit paths. Commits carry no Co-Authored-By or Claude trailer.
- A code file stays under 1,000 lines.
- Every text that a person reads follows the writing rules.
