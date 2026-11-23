---
name: rules
description: How work is done on prismarine — writing, docs, engineering; machine and landing rules are mcsm's until they move here
type: feedback
---

# Rules

These rules bind every session and every agent.
Shared machines, git and landing follow mcsm's `docs/memory/rules.md` until they move here.

## Writing

- Write for the reader of that page, and only what they need: a README tells a newcomer what prismarine is; an area page tells a developer how a part works and how to check it.
- Leave out detail no one would miss: inventories of features, sizes, internal names, how we got here.
- Plain, everyday English, short sentences, one sentence per line in docs.
- Say what is, not what was: no dates in prose, no "(was X, now Y)", no "Update:" sections; history belongs in git.
- No time estimates; say what is done and what is next.
- State rules and decisions neutrally, without quotes or attributions.
- Commit messages say what changed and why, in a line or two.

## Docs

- Update the file that owns a fact instead of adding a new one: rules, decisions and state in `docs/memory/`, how a part works in `docs/areas/`, designs in `docs/specs/`, plans in `docs/plans/`.
- Rewrite, don't append; no status files.
- `state.md` stays one page and is rewritten when a landing changes what is live or in flight.
- A package that moves here takes its "how it works" with it, rewritten for prismarine; mcsm's page then links here.

## Engineering

- Generic only: no game data, and no game names in code, identifiers or package names.
- A moved file is moved verbatim (renames and imports only); any other change is its own commit with its reason.
- Files stay under 1,000 lines (hard) and aim for 500.
- Comments say why and cite sources as tags; no history, dates, run ids, agent names or plan pointers.
- Code a frame runs does not allocate: the alloc lint's counts only fall; a place that must allocate says why (`// alloc: <reason>`, `// alloc-cold: <reason>`).
- New native code is Rust, built by the package's build hook through `prismarine_cargo`; vendored C stays C behind a thin Rust wrapper; `unsafe` only at the FFI edge, each with a `// SAFETY:` comment.
- OS-specific code (memory, thread roles, file IO, process info) has a real path on Windows, Linux and macOS alike, with platform-independent tests of its logic.
- General infrastructure comes from established, maintained libraries; a library on a path that must be bit-identical is proven so, or it stays out.
- Dart is `dart format`ted, Rust `cargo fmt`ed; new code adds no analyzer, clippy, size or comment findings.
