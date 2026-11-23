# Plan: the audio engine

From [the audio engine design](../specs/2026-11-23-audio-engine-design.md). The work is on branch `prismaudio` in both
repositories. Each task ends with the package tests of what it touched, `dart analyze`, `dart format`, `cargo fmt`,
clippy and `cargo test` for a crate it touched.

The parity sets of mcsm hold the bits of every task. A baseline from mcsm's `main` holds the Dart checksum of each
set and the native replay's result. After each task that changes render code, each set runs again and must give the
same checksum, with the native replay identical.

## Step 1: the cut inside mcsm

1. The typed model in `mcsm_audio/lib/src/model/`, with the names and enums of the design. `EffectDef` replaces the
   JSON records of effects, `WaveformDef` carries its key and path, and the behaviour fields replace `fmod109`,
   `EventBank.fills` and the format version.
2. The adapter `mcsm_audio/lib/src/fmod/`: `EventBank` and `SliceAudio` read `events.json` and `bank.json` and build
   the typed model. The low-level voice event is built there.
3. The render code reads the typed model: strips, the graph, snapshots, the event formats, the instance, its sounds
   and its timeline, the player and the blob writer. The blob carries the typed model. The crate's `model.rs` reads
   the new blob, and the crate's render takes the behaviour fields in place of version flags.
4. The generic commands with `AudioRules`. The bridge, the session log, the snapshot codec of the bridge, the
   output, `NativeMixerPort` and the parity tool use them. The codec keeps its tags and bytes, checked by a test that
   writes every command form and compares the bytes with a stored copy.
5. The parity sets and the synthetic checksum, unchanged.

## Step 2: the move

1. prismarine: the model, the mixer, the events and the engine into `prismarine_audio/lib/src/`, the parity writer
   into the separate library `package:prismarine_audio/testing.dart`. Comments follow prismarine's writing rules and
   hold no game or FMOD words. Tests that need no game data move with the code.
2. prismarine: the crate's engine into `prismarine_audio_out/native/src/mix/` with `dmath.rs`, the FFI as
   `prismarine_mix_*`, `NativeAudioEngine` and `NativeMixerPort` into `prismarine_audio_out/lib/`, the
   `parity` example into the crate.
3. mcsm: imports from the two packages, the copies deleted, `mcsm_audio_out/native` deleted with the user defines in
   the pubspecs of `mcsm_audio_out` and the player. The rules of mcsm that name `dmath.rs` point to prismarine.
4. The parity sets, unchanged, with the parity example of prismarine.

## Step 3: allocation

1. The roots of prismarine's alloc lint gain the render, the apply, the lockstep step and the post.
2. The render keeps its buffers: per strip as today, the outputs of instances by bus in kept buffers in first-use
   order, the queue sorted in place, the problems in a kept set. The count of the roots falls to the starts of
   instances, each marked.
3. The parity sets, unchanged.

## Step 4: the project format and docs

1. `AudioProject.fromJson` and `toJson` with defaults for the behaviour fields, and a test that the round trip of the
   synthetic project gives the same blob.
2. The synthetic project in `prismarine_audio/test/` with generated samples, rendered by the Dart engine in a test
   with a stored checksum, and by the crate in `cargo test` from a blob that the Dart test writes.
3. The page `docs/areas/audio.md` with the table of effect kinds and their parameters, the README and the example of
   the package, and `docs/areas/audio_out.md` for the native engine. The state page, the decisions and the goals.
4. mcsm: `docs/areas/audio.md` links to prismarine's pages and keeps the adapter, the bridge and the checks against
   FMOD. The rules that name the Dart render and `dmath.rs` change with it.

## Hand-back

The report lists the commits of both branches, the tests per OS, the alloc totals of both repositories and every
place that could change audio bits, sim timing or snapshot bytes.
