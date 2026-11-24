# prismarine_replay

The package replays a game run exactly. A route records the input of each frame. A snapshot holds the state of the
simulation between two frames. A replay starts at the latest snapshot before its target. A shadow process writes
the snapshots of a running game. The corpus runner replays a list of runs against a baseline. The design is in
[the replay design](../specs/2026-11-23-replay-design.md).

## Routes

A route is a file of JSON lines. The header line starts with the marker of the `RouteFormat` and holds the `seed` of
the run, with `t0` and `frame0` when the run did not start at time 0. Each frame line starts with `dt` and has the
fields that your game records, such as the keys held. The host changes of the frame come last under `host`. A host
change is a change outside the input, such as a graphics setting that the player changed. Your game passes it to
`RouteRecorder.hostChange` as it is made and applies it again on replay.

The route hash after a line is 64-bit FNV-1a over the UTF-16 code units of the line and a line feed, from the hash
after the line before. It identifies a route up to a frame. Two routes with the same lines up to frame 1,000 have the
same hash there.

## Snapshots

A snapshot file is a JSON header line and the body compressed with zlib. Its name is the number of route frames played
before it, padded to nine digits, such as `000012345.snap`. The header holds the format, the body version, the frames,
the simulated time, the route hash and the fields of your game. A reader skips a file of another format or version. A
replay takes the snapshot with the most frames at or before its target whose route hash matches its route.

The body is yours. You write it with the codecs of `prismarine_snap` in `ReplayGame.writeState` and read it in
`readState`. An object that the host makes only after a restore, such as an audio bridge, goes at the end with
`writeSnapshotTail` and is read later through `SnapshotTail`. A codec tag and the order of the fields are part of the
bytes. A changed tag or order makes older snapshots unreadable. A changed body needs a new version.

| Setting | Effect |
|---|---|
| `SnapshotSchedule` | A snapshot after the first frame of each scene open, at most one per 20 s. One every 180 s otherwise, on a held frame when one comes within 30 s |
| `PRISMARINE_SNAPSHOT_EVERY` | One snapshot every given number of seconds and at scene opens at most that often, without the wait. It also reads `MCSM_SNAPSHOT_EVERY`. |
| `SnapshotFormat.prune` | Keeps every snapshot of the last 600 s and the latest of each 300 s before that |

## Shadow

The shadow is a process of your game that calls `shadowMain` with your `ReplayGame`. Its input is a configuration line
and then the route as it is recorded. It replays the route and writes the snapshots of the run into the folder `dir` of
the configuration. The running game does not stop for a snapshot. The host starts it with `ShadowProcess.start` and
sends it each new line. It costs a process and its memory. A release build does not need to start it.

## Corpus

The corpus runner replays a list of runs and compares the fingerprint of each frame with a baseline. You extend
`Corpus` with the data of a run, its arguments and its recording. Your corpus program replays one run as a worker.
The runner compiles the program once, runs the workers in parallel and cuts long runs at their baseline snapshots into
chunks. A check reports the first divergence of each run per channel and fails on one that the note of expected
divergences does not list.

## Checks

Run `dart test` in `packages/prismarine_replay`.
