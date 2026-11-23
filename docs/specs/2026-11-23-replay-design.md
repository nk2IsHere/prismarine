# Replay and snapshots: the design of prismarine_replay

This spec designs `prismarine_replay`, the framework for deterministic replay that the decision "Replay and snapshots in
the core" asks for. It starts from mcsm's route recording, state snapshots, snapshot shadow and regression corpus, the
units #34, #35, #36 and #44 of mcsm's inventory. mcsm is its first user and registers its own state and formats.

## Goals

- A game records the input of a run frame by frame and replays it to the same state, from the start or from a
  snapshot taken along the way.
- A game registers its state codecs, its route fields and its snapshot header fields. The framework owns the
  containers, the hash chain, the schedule, the files, the shadow process and the corpus runner.
- mcsm's formats are a registered set that keeps today's bytes. Every route that the owner and the corpus have
  recorded replays the same, every save and snapshot loads, the corpus stays at 32 same against baseline 5a2c9fd2 and
  D1 stays identical.
- The snapshot shadow stays optional. A game that does not start it pays nothing for it.

## Not in scope

- A new route or snapshot format. The formats below are mcsm's formats with their game fields left to the game.
- The sim and UI boundary of mcsm (inventory #35: `FrameSnapshot`, the extractor, the replica `GameView`, the packed
  poses, `PoseStore`, `NativePlanBlocks`, the mirror check). It is not about replay. Its native pose and plan blocks are
  a later lift into a frame package.
- mcsm's user store and its event log. The user store holds the game's property sets, save games and event stores. The
  event log holds the dialog lines that the debug panel reads. Neither has a generic part beyond the atomic file write,
  which the snapshot files have of their own.
- The fingerprints of the corpus and their comparison. The channels (cameras, agents, poses, events, dialog lines,
  sounds) and their tolerances are the game's.

## Package

`prismarine_replay` is pure Dart and depends on `prismarine_snap` only. It has two libraries.

| Library | Contents |
|---|---|
| `package:prismarine_replay/prismarine_replay.dart` | Route hash, route recorder and reader, host changes, the sim interface, snapshot formats and files, the schedule, pruning, the body tail, replay start, the headless snapshot writer, the shadow |
| `package:prismarine_replay/corpus.dart` | The corpus runner: the run list, the worker pool, the compiled worker, record, baseline, rebaseline, check, snapshots, chunks, solo costs, the expected-divergence note, the report |

`tool/corpus_remote.sh` in the package runs the corpus on another machine in a container. A game calls it with its
own settings.

`prismarine_lua` and the audio engine do not import `prismarine_replay`, and `prismarine_replay` imports neither. They
meet in the game, which registers their codecs into one `SnapRegistry`.

## Routes

A route is a file of JSON lines. The first line is the header, every other line is one frame. Blank lines are
skipped.

A `RouteFormat` holds the marker key of the header and its version. The header line is a JSON object whose first key
is the marker with the version as its value. A reader refuses a file whose first line lacks the marker. mcsm's format
is `RouteFormat('mcsmRoute', version: 1)`.

The game gives the header's other fields in their order. The reader reads three of them.

| Key | Value |
|---|---|
| `seed` | The seed of the run, an integer. Required. |
| `t0` | The simulated time at the first frame, 0 when absent |
| `frame0` | The frame count at the first frame, 0 when absent |

A frame line is a JSON object. Its first key is `dt`, the frame's step in seconds. The game's fields follow in the
order the game gives them. The host changes since the last frame come last, under `host`, when there are any.

`RouteRecorder` writes routes. It holds the lines, the hash after the last line, the frame count and an optional sink
that receives each line. `onLine` gets each frame line as it is recorded, which feeds the shadow. `resume` starts a
recording from the lines of an earlier route, for a run restored from a snapshot. Its route stays one continuous
recording.

`RouteReader` reads routes. It decodes each line once, keeps the hash after every line and plays frames in order
with `next`. `skipTo` moves to a frame after a restore. `addLine` adds a frame to a route that is still being recorded.
`prefixLines` reads the header and the first frames again as written.

### Route hash

The hash after a line is 64-bit FNV-1a over the UTF-16 code units of the line and then a line feed. It starts at
0xcbf29ce484222325. From hash h, each unit c gives h = (h xor c) · 0x100000001b3, and the line end gives
h = (h xor 10) · 0x100000001b3. The header line is hashed first, then each frame line as written. A snapshot refers to
its route by the hash after the header and its first frames, as 16 hex digits.

The hash runs over the text of the lines. A game keeps its route bytes by building each line from the same values in
the same key order. The recorder joins the game's fields between `dt` and `host` and adds nothing else.

### Host changes

A host change is a change that the host makes to the simulation outside its input, such as a graphics setting that
the player changed or a result that the renderer read back. `HostChange` is an interface with `toJson`. The game
passes each change to `RouteRecorder.hostChange` as it is made. The recorder adds them to the next frame line under
`host`, in order. On replay the game applies the frame's `host` list before the step, at the point of its own
choosing within its input.

## The sim interface

`ReplaySim` is the simulation as the framework sees it.

| Member | Use |
|---|---|
| `time` | The simulated time in seconds, for the schedule, the header and pruning |
| `frame` | The frames stepped so far, for the header |
| `sceneOpens` | A count that grows when a scene opens. The schedule takes a snapshot after an open. |
| `frameHeld` | True on a frame that the host does not draw anyway. The schedule prefers such a frame. |
| `step(dt)` | Runs one frame of `dt` seconds with the host objects that a headless run has |

`ReplayGame<S extends ReplaySim, R extends RouteReader>` is the game side of a replay.

| Member | Use |
|---|---|
| `snapshots` | The snapshot format |
| `route(lines, path:)` | Reads a route into the game's reader type |
| `open(route, config)` | Makes a sim as the recorded host made it, without a boot |
| `boot(sim, route, config)` | Boots the sim at the start of its route |
| `started(sim, config)` | Runs after the boot or the restore. It makes the host objects that a snapshot's tail fills. |
| `input(sim, route)` | Applies the next frame of the route before its step. Returns its dt, or null at the end. |
| `writeState(sim)` | Writes the state of the sim as a snapshot body |
| `readState(sim, body)` | Reads a body into a sim from `open` |
| `snapshotFields(sim)` | The game's fields of a snapshot header |
| `snapshotDirs(route)` | The folders that hold the snapshots of a route |

The interface covers the three parts that the decision asks for. `step` is the step. Host changes go through the
recorder and the game's `input`. The state codecs are `writeState` and `readState` over the game's `SnapRegistry`.

## Snapshot files

A `SnapshotFormat` holds the format string of the header and the version of the body. mcsm's is
`SnapshotFormat('mcsm.snapshot/1', 15)`. A file is one JSON header line, then the body compressed with zlib at level 6.
A reader reads the header up to the first line feed, at most 64 KiB, and skips a file whose format or version differs.
A file is written to `<name>.tmp` and renamed.

The header keys come in this order. The game's fields follow the route hash.

| Key | Value |
|---|---|
| `format`, `version` | The format string and the body version |
| `frames` | The route frames played before the snapshot |
| `time`, `frame` | The simulated time and the frame count |
| `routeHash` | The route hash after the header and the first `frames` frames, as 16 hex digits |
| game fields | `snapshotFields`, such as mcsm's `logLines`, `logKept` and `scene` |
| `bodyBytes`, `writeMs` | The size of the body and the time its write took, in ms with two decimals |
| `reason` | The reason for the snapshot, when given |

A snapshot of `frames` route frames has the file name of `frames` padded to nine digits with `.snap`. A snapshot
belongs to a route when the route's hash after `frames` frame lines equals the header's `routeHash`. `latestFor` takes
the matching snapshot with the most frames at or before a frame, and `latestBeforeTime` the one at or before a time.

`prune` keeps every snapshot of the last 600 s of simulated time and, before that, the latest of each 300 s span.
`write` compresses and writes a file on a worker isolate and then prunes its folder.

## Snapshot bodies

The body is the game's. The game writes it with `prismarine_snap` and its own registry. The framework adds one
section to the end, the tail. The tail is one object that the reader's host makes only after the restore, such as an
audio bridge. `writeSnapshotTail` writes a boolean and, when the tail is there, the object as its own section.
`SnapshotTail` reads it later into the object that the host made, and checks that no bytes are left.

The codec tags of `prismarine_snap` are part of the stream. A game keeps its snapshots readable by keeping its tags,
its field order and the order of its known roots. `prismarine_lua` keeps the tags `lua.Table`, `lua.Closure`,
`lua.Native`, `lua.Thread`, `lua.Userdata`, `lua.UpVal`, `lua.Proto`, `lua.Chunk`, `lua.Rng` and `lua.Vm` with their
bytes. mcsm's audio bridge keeps its codec and its command bytes. Both were agreed with the designs of those packages.

## Schedule

`SnapshotSchedule` takes a snapshot at the first frame after a scene opens, at most one per 20 s of simulated time, and
every 180 s otherwise. A periodic snapshot waits up to 30 s for a held frame. `PRISMARINE_SNAPSHOT_EVERY=<s>` takes one
every s seconds and at scene opens at most that often, without the wait. The variable also reads its
`MCSM_SNAPSHOT_EVERY` form for one release.

## Replay start and headless snapshots

`openReplay` opens a route's sim at the latest snapshot before a target frame or time when one fits, else boots it
from the start. A snapshot that does not read is logged, and the replay starts from the beginning.
`ReplaySnapshots` writes the snapshots of a headless replay into a folder after each frame that the schedule picks, or
at a frame that the caller picks. It prunes the folder as a run does, or keeps every snapshot for a corpus baseline.

## Shadow

The shadow is a second process that replays a run's route as it is recorded and writes the run's snapshots. The
playing simulation does not stop to write one, and the collections of the shadow stay out of the player's isolate
group. A game runs it only in development builds. A run without a shadow writes no snapshots and pays nothing.

The protocol is lines on the standard streams. The input is one JSON line of configuration, then the route's lines
as they are recorded, header first. The output is log lines. The shadow ends when its input ends. The framework reads
two configuration keys, `dir` for the snapshot folder and `restoredFrom` for the snapshot that the run was restored
from. The game reads the rest.

| Part | Contents |
|---|---|
| `runShadow(game, config, lines)` | The loop. It opens the sim at the header, waits for the frames up to the restored snapshot, restores or boots, then plays every frame that arrives and writes the scheduled snapshots. A state that the codecs miss is logged once and ends the writing. |
| `shadowMain(game)` | A process entry: reads the standard input and runs the loop |
| `ShadowProcess` | The host side: starts the executable, sends the configuration and the lines so far, sends each new line and closes the input at the end |

The game builds its shadow executable from its own entry, which calls `shadowMain` with its `ReplayGame`.

## Corpus runner

The corpus is a list of runs that replay headless with a fingerprint of their behaviour per frame. A check compares a
tree's fingerprints with a baseline frame by frame. The runner is the framework. The fingerprint, its comparison and
the way a run is recorded are the game's.

| Command | Effect |
|---|---|
| `record` | Records each run's route through the game into `<corpus>/runs/<id>/` with a `meta.json` |
| `baseline`, `rebaseline` | Replays each route and writes its fingerprint, its result and its snapshots into `<corpus>/baseline/`, with `BASELINE.json` |
| `check` | Replays the routes on this tree against the baseline, in chunks from the baseline's snapshots, and reports the first divergence per run and channel |
| `snapshots` | Writes the baseline's snapshots again for a baseline made before |

The runner compiles the game's corpus entry once with `dart build cli` and runs it as workers, one replay each. A run
is cut at its baseline snapshots into chunks that replay in parallel. Each chunk starts from the state of the baseline
at its snapshot and plays to the next one. A chunk that diverges plays on as a whole run would.

The worker protocol is a command line. The runner calls the worker with `replay <route>`, the game's arguments for the
run, `--out=<fingerprint>`, `--result=<json>`, and as needed `--baseline=<fingerprint>`, `--from-snap=<snapshot>`,
`--to-frames=<n>`, `--snaps=<dir>`, `--snap-frames=<n>` and `--until=<s>`. The worker exits with 0 when the run is
the same or has no baseline, 1 when it diverged, 2 on an error and 3 when the snapshot of the chunk does not read.
The result JSON has the keys `route`, `frames`, `end`, `wall`, `first` (the divergences with `channel`, `frame`, `t`,
`scene` and `detail`), `baselineLeft`, `fromFrame`, `snaps`, `stopped` and `sliceEnded`.

`CorpusGame` is the game side of the runner.

| Member | Use |
|---|---|
| `sliceOf(run)`, `sliceId(slice)` | The data that a run plays and its identity. A changed identity adds a note to the report. |
| `replayArgs(run)` | The worker's arguments for a run beyond the framework's |
| `passes(arg)` | True for a command-line option that the runner passes on to every worker, such as a tolerance |
| `beforeRecord()`, `record(run, dir, meta)` | Records one run's route and fills its meta |

The note of expected divergences has one line per entry, `<id or glob> [<channel>,…] # why`. A divergence that the
note does not list fails the check.

`corpus_remote.sh` ships a tree's committed head to another machine with `git archive`, builds the corpus entry there
in a container, runs a command and copies the report back. Its settings are the host, the remote root, the container
image, the corpus entry of the tree and the data folder. The game's script sets them and copies its own data.

## mcsm's registered set

mcsm keeps its formats and registers them.

| Part | mcsm |
|---|---|
| Route format | `mcsmRoute` 1. Header `slice`, `seed`, `start`, `t0`, `frame0`, `window`, `dusters`. Frame fields `window`, `focus`, `god`, `godNoMash`, `cursor`, `keys`, `pad`, `events`, `probe`. Host changes touch, `renderQuality`, `pref`, `dust`. |
| Recorder and reader | `InputRecorder` extends `RouteRecorder` with the session's hooks. `InputReplay` extends `RouteReader` with the start, the window, the probe chunks and `beforeTick`. |
| Snapshot format | `mcsm.snapshot/1` with body version 15 and the header fields `logLines`, `logKept` and `scene` |
| Snapshot body | `GameSessionSnapshots` on `gameSnapRegistry`, with the Lua, runtime, flow and game codecs and the audio bridge as the tail |
| Replay game | `GameReplay`, whose sim is the session with its audio bridge |
| Shadow | `apps/mcsm_shadow` calls `shadowMain` with `GameReplay`. The player starts it through `ShadowProcess`. |
| Corpus | `tool/corpus.dart` with `corpus.json`, the episode probe for new games, the fingerprint and its comparison as the worker. `corpus_ws.sh` sets the workstation, the container and the slice copy and calls `corpus_remote.sh`. |
| Stays | The user store, the event log, the run folder layout and its store snapshots, the fixed time seed |

The code of mcsm keeps its paths, flags and outputs. The gate keeps calling `packages/mcsm_game/tool/corpus_ws.sh`.

## Byte compatibility

The framework changes no byte of a route, a snapshot or a fingerprint. Three checks prove it on each change that
touches these paths.

1. Unit tests in `prismarine_replay` fix the hash of known lines, the header and frame line text for given fields, the
   snapshot header text for given fields and the file bytes for a given body.
2. A short corpus run replays from its baseline's snapshots with `corpus.dart check --only=<id>` on the workstation.
   The baseline snapshots read and the fingerprints match.
3. A route and the snapshots of a headless replay written by `main` and by the branch are compared byte for byte, the
   `writeMs` of the headers aside.

The coordinator runs the whole corpus and D1 before landing.

## Risks

- **Route bytes.** A field built in another order or a number in another form forks every route. The recorder joins
  the game's map as given and the tests fix the text.
- **Snapshot bytes.** A changed codec tag or field order makes every snapshot unreadable, and a reader skips files of
  another version. The tail section keeps its framing.
- **The corpus gate.** `corpus-same.sh` compares the compiled corpus tool of `main` and of the landing. Code that moves
  to prismarine changes the program, and the corpus runs for the landing that moves it.
- **The gate's scripts.** The land gate calls `corpus_ws.sh sync` and `check` and reads its exit code. Both keep their
  paths, arguments and exit codes.
