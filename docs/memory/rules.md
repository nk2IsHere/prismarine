---
name: rules
description: Rules for work on prismarine, covering docs and engineering, with machine and landing rules from mcsm for now
type: feedback
---

# Rules

These rules bind every session and every agent. The rules for shared machines, git and landing are in mcsm's
`docs/memory/rules.md` until they move here.

## Writing

Every text that a person reads follows the [writing rules](writing.md).

## Docs

- A fact has one owner. Rules, decisions and state are in `docs/memory/`, the workings of a part in `docs/areas/`,
  designs in `docs/specs/` and plans in `docs/plans/`.
- A changed fact is rewritten in its file. History belongs in git.
- No status files exist.
- `state.md` stays one page. A merge that changes what is live or in progress rewrites it.
- A package that moves here gets an area page written for prismarine.

## Engineering

- Code is generic. The repository holds no game data except the logo. Code, identifiers and package names hold no
  game names.
- A moved file keeps its content. Only renames and imports change. Any other change is its own commit with its reason
  in the message.
- A file stays under 1,000 lines and aims for 500.
- Code that a frame runs does not allocate. The counts of the alloc lint only fall. A place that must allocate carries
  `// alloc: <reason>` or `// alloc-cold: <reason>`.
- New native code is Rust, built by the build hook of its package through `prismarine_cargo`. Vendored C stays C
  behind a thin Rust wrapper. `unsafe` is only at the FFI edge. Each such block has a `// SAFETY:` comment.
- OS-specific code, such as memory, thread roles, file IO and process info, has a real path on Windows, Linux and
  macOS. Its logic has tests that run on every platform.
- General infrastructure comes from established, maintained libraries. A library on a path that must be bit-identical
  is proven bit-identical or is not used.
- Dart is formatted with `dart format` and Rust with `cargo fmt`. New code adds no analyzer, clippy, size or comment
  findings.
