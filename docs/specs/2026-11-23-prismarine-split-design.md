# Prismarine: the split from mcsm

Prismarine is our toolkit for building games on Flutter and Dart.
It starts as everything generic in mcsm (the Minecraft: Story Mode port), moved here unit by unit; mcsm then builds on it.
The decisions behind this spec are in [decisions](../memory/decisions.md); the unit-by-unit survey of mcsm is mcsm's `data/work/coordinator/prismarine/inventory.md` (snapshot of mcsm `main` at 5a2c9fd2).

## Goals

- Everything in mcsm that is not about Telltale data or a shipped exe's behaviour lives in prismarine, with no game words in its code or names (docs name mcsm only as where code came from).
- mcsm keeps every byte it produces: the D1 reference frames and audio, the regression corpus, the slices. A move that changes an output is a bug in the move.
- Prismarine stands alone: its own gate, docs, sample app and private repo; no edge back into mcsm.
- The redesigns the owner chose (a slim scene layer, a generic Lua, a generic audio engine, replay as a framework) each get their own spec; this one moves code and cuts seams.

## Not in scope

- New features. The app shell (`prismarine_app`) comes with production's launcher and common UI.
- Public release. The repo is private; it is licensed BSD-3 from its first commit so that a later release changes nothing.
- Telltale and FMOD readers, exe-faithful systems (chores, Lua profiles, dialog flow, particles, Enlighten, both looks' passes, the UCRT maths), the slicer, the oracle, the corpus and the episode tools. They stay in mcsm.

## Repo

```
~/Desktop/prismarine                       origin: a private GitHub repo
  LICENSE (BSD-3)  README.md  CLAUDE.md
  docs/memory/{state,rules,decisions,goals}.md  docs/areas/  docs/specs/  docs/plans/
  pubspec.yaml                     pub workspace of the pure-Dart packages
  packages/prismarine_<function>/  see "Packages"
  apps/prismarine_sample/          the smallest app on the patched engine: render, loop, debug, pad
  third_party/                     flutter_engine (patches, release scripts), flutter_gpu
  tools/lint/ tools/profiler/ tools/gpu_smoke/ tools/toolchain/ tools/machine/
  templates/runners/{macos,linux,windows}/  templates/scripts/
  private/                         its own private repo (gitignored here), local only
```

- Packages are named `prismarine_<function>`; Flutter-free packages stay usable from pure-Dart isolates and tools.
- Environment variables are `PRISMARINE_*`; each moved variable also reads its old `MCSM_*` name for one release, so mcsm's scripts keep working while they are renamed.
- The engine's native exports keep their `Mcsm*` forms until prismarine's first engine release. A new patch on top of the existing ones renames them (`Prismarine*`) with the feature bits unchanged and flutter_gpu in lockstep.

## Packages

| Package | From mcsm | Contents |
|---|---|---|
| `prismarine_kept` | mcsm_kept | Collections that keep their storage on clear |
| `prismarine_snap` | mcsm_snap | Identity-preserving object-graph codec |
| `prismarine_math` | mcsm_math libm, clamps | Rust libm ported to Dart, the same bits on every OS |
| `prismarine_jobs` | mcsm_jobs | Worker isolate pool, thread roles and QoS per OS, MemoryRoom |
| `prismarine_cargo` | mcsm_cargo | A package's Rust crate built from its Dart build hook |
| `prismarine_pad` | mcsm_pad | SDL3 gamepads |
| `prismarine_assets` | mcsm_convert gltf/, image/; the cook's pools and texture arrays | glTF builder and validator, KTX2, PNG, BC decode |
| `prismarine_frame` | mcsm_render; mcsm_look's plan core | `FramePlan`, the plan codec, plan JSON, float bits, packed scene rows, the cook model |
| `prismarine_render` | mcsm_look_scene's runner | Records a `FramePlan` on Flutter GPU behind a `RenderAssets` interface |
| `prismarine_shaders` | tools/mcsm shader toolchain | impellerc bundles, the shard cache, precompiled Metal |
| `prismarine_audio` | mcsm_audio's `PcmSource`, formats, `WavWriter` | The audio interfaces (the generic engine comes with its own spec) |
| `prismarine_audio_out` | mcsm_audio_out's device and decoders | cpal output, push ring, minimp3 and stb_vorbis, the decode cache |
| `prismarine_scene` | mcsm_slice_scene's file bundle, paced loads, sampling | Asset bundles and paced loading; becomes the slim scene layer (own spec) |
| `prismarine_loop` | the player's gc_pacing, frame_pace, metal_frames, mem_log, line_writer; platform focus, cursor, mouse look | The real-time loop's pieces |
| `prismarine_debug` | the player's frame ring, F7 review, glitch catcher, profiler, pass log, heap snapshot, plan replay; the F1 panel's shell and frame graph | Debug tools; games register their own panel sections |

Tools: the lints (analyze, alloc, same_code, privacy_check, check_links, docs_index, code_shape with generic rules), the heap and allocation profiler, gpu_smoke, the toolchain, and the machine scripts (heavy-job and measure locks, the shared engine and Flutter directory).

## How mcsm depends on prismarine

- mcsm's pubspecs name each prismarine package as a git dependency pinned by commit (`git: {url, path, ref: <sha>}`).
  A gitignored `pubspec_overrides.yaml` points them at `~/Desktop/prismarine` (or an agent's prismarine worktree) for work across both repos.
- The pin is the version: no semver while mcsm is the only user. Prismarine's state page names what each landing changed, so a pin bump is made knowingly.
- mcsm's build mirror (`sync.sh`) resolves the pinned checkout into the shared pub cache, so Flutter builds see the same code the gate saw.
- The engine stays a separate artefact. Prismarine's `third_party/flutter_engine/RELEASE` names the release; mcsm's scripts read it through the pinned checkout; one engine and Flutter directory per machine serves both repos.

## Gates and landing

- **Prismarine's gate:** privacy (with a stricter list: any game asset name, slice path or game word fails), links, docs index, code_shape (generic rules), alloc (its own roots: the runner's record, the plan codec, the frame loop), analyze and format, the lints' tests, its packages' tests, clippy and `cargo test` for its crates, the sample app built on the patched engine, gpu_smoke when the engine changed.
- **mcsm's gate:** its chains as today, plus: the prismarine pin resolves and is an ancestor of prismarine's `main`, and the lints run from the pinned checkout.
- **Landing a change across both** (the coordinator lands both): prismarine first, behind its gate; then the mcsm commit that bumps the pin, behind mcsm's gate (with D1 and the corpus when behaviour can change). No mcsm landing pins an unlanded prismarine commit.
- **A pin bump** whose prismarine range `same_code` proves comment- or layout-only skips the corpus; any other bump follows mcsm's corpus rule.
- **Ratchets:** each repo keeps its own baselines. A verbatim move lowers mcsm's counts (`--allow-moves`) and starts prismarine's from the moved code.
- **Rules that span both repos:** a change to the mixer maths goes into mcsm's `dmath.rs` and prismarine's `libm.dart` together; the 1,000-line limit and the comment rules hold in both.

## Machines

- One heavy-job lock and one measure lock per machine, shared by both repos' agents; the scripts live in prismarine's `tools/machine/`, mcsm's scripts call them.
- One engine and Flutter SDK directory per machine for both repos; engine releases still build incrementally per machine (new patches only).
- The Wine oracle tooling and its locks stay in mcsm.
- Prismarine's private repo holds its own gate script and privacy patterns; machine notes it needs are copied from mcsm's, not shared.

## Migration

Each step is one landing in each repo that keeps mcsm's gate green, D1 byte-identical and the corpus unchanged.
A step's mcsm side is imports, pubspecs and deletions only, except the seams named in steps 5 and 8, which are cut inside mcsm first and landed on their own.

1. **Skeleton:** the repo, licence, docs, workspace, the lints copied with generic rules, the gate in its private repo, an empty sample app. mcsm unchanged.
2. **Leaf packages:** kept, snap, math (libm and clamps; the UCRT maths stay as `mcsm_math`), jobs, cargo, pad. mcsm pins prismarine, rewrites imports and deletes the old packages.
3. **Lints and machine scripts:** mcsm's gate runs the lints from the pinned checkout; code_shape's exe-address and season-name rules become mcsm's rule set; the heavy-job and measure locks move to `tools/machine/`.
4. **Frame core:** mcsm_render and mcsm_look's plan core become `prismarine_frame`. mcsm_look re-exports them for one landing.
5. **Runner:** cut `RenderAssets` inside mcsm (land), then move the runner to `prismarine_render`. The scene rows' field layouts, which follow the game's shader buffers, become layouts that mcsm registers, so `prismarine_frame` keeps only the row format; `assets.dart`, `tt_meshes.dart` and the S1 shaders stay in an mcsm package. Frame times measured before and after on the workstation (a hot path: no new indirection per draw).
6. **Shaders:** the shader toolchain becomes `prismarine_shaders`; one small slice resliced into a private directory matches the live one byte for byte; cache keys unchanged.
7. **Assets:** glTF, KTX2, PNG, BC and the cook's pools become `prismarine_assets`; the same byte-for-byte slice check.
8. **Audio output:** cut `PcmSource` and the decode cache's key inside mcsm (land), then move the interfaces to `prismarine_audio` and split the Rust crate: output (prismarine) and mixer (mcsm). The parity test and D1's `audio.wav` stay identical.
9. **Loop and debug:** `prismarine_loop`, then `prismarine_debug` with the panel shell; mcsm registers its sections. Checked with a real-time recording on the workstation.
10. **Scene assets:** `FileAssetBundle`, paced loading and sampling become `prismarine_scene`; Telltale cameras and component types stay.
11. **Engine:** `third_party/flutter_engine`, `flutter_gpu` and `tools/gpu_smoke` move with their git history from mcsm. The commits that touched these paths are rewritten to the new paths and merged into prismarine, so the history of every engine patch stays in `git log`. mcsm reads the release through the pin; the same release and archives (no build in this step).

After the last move:

- A README for each package, with its purpose, its use, a short example and its platforms.
- The root README gets workspace setup and building for each platform.
- GitHub workflows for the lints, the tests, clippy and `cargo test` on Linux, macOS and Windows.
- The sample app becomes a real example, through its own spec: Crytek Sponza from the Khronos glTF sample assets
  (CC BY 3.0, fetched by a script, not committed), drawn by a small generic plan builder with glTF metallic-roughness
  shaders, a directional light with shadows, moving coloured point lights, a fly camera with gamepad support and the
  debug panel. It doubles as the gate's smoke test and a performance scene on all three platforms.

Then prismarine's first engine release:

- **First engine release (prismarine's):** mcsm12's patches (Dart old-space compaction at switch holds: dart/0003, 0029, flutter_gpu G16, G17) plus one new patch on top that renames the `Mcsm*` exports to prismarine forms. The existing patches stay unchanged, so each machine applies only the new patches. Built for every target incrementally, gpu_smoke on each.

Later, each through its own spec and plan, in this order:

- **Slim scene layer:** `prismarine_scene` grows into a glTF importer and scene-node layer on Flutter GPU, under our renderer; mcsm's vendored flutter_scene goes once nothing uses it. The old S1 look's patches (shadow binder, display tone mapping, render textures, translucent depth) go with it.
- **Replay:** `prismarine_replay`: the route container and hash chain, the snapshot schedule and pruning, the shadow-process runner, a deterministic-sim interface; mcsm registers its state (Lua, chores, session). Recorded routes must still replay.
- **Lua:** `prismarine_lua`, an embeddable Lua for Dart with double numbers by default; mcsm's float32 numbers, CRT text and exe profiles become an mcsm profile on it. Lua fidelity stays exact.
- **Audio engine:** prismarine's event and bus engine; FMOD Studio 1.x semantics and the Telltale bridge become mcsm adapters. The parity test stays identical.
- **App shell:** with production's launcher and common UI.

## Risks

- **Byte-identical outputs.** Slices, frames and audio are compared byte for byte; a moved file is moved verbatim, and each step runs D1 (and the corpus where the inventory says behaviour can change).
- **Hot paths.** The runner, the plan codec and the loop are on the frame path; seams must not add a call per draw. The alloc lint must still see them: prismarine lists its own roots for code mcsm's frame reaches.
- **Two-repo landings.** An mcsm landing on an unlanded prismarine commit would make history unreproducible; mcsm's gate refuses it.
- **Worktrees and mirrors.** Agents get a worktree in each repo and an override pointing mcsm at their prismarine worktree; the build mirror must follow the override, not `~/Desktop/prismarine`.
- **Game data.** Prismarine holds no game data, except its logo (the owner's exception, 2026-11-23), in `docs/logo/`.
