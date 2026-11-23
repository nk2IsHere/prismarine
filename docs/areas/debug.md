# prismarine_debug

The package holds debug tools for a real-time game on Flutter: a ring of the frames that the window showed, a review
that marks what is wrong on them and saves an issue, a glitch catcher, a per-frame profiler, a log of GPU passes, heap
snapshots, the replay of a frame plan and a debug panel with a frame graph. It is a Flutter package. It needs the
engine fork's flutter_gpu, which its pubspec takes from `third_party/flutter_gpu`.

## Frame history and review

`FrameHistory` keeps the last seconds of shown frames in a ring of textures at 640 by 360. It copies each frame on the
GPU with the `FrameCopy` that your application gives, a full-screen pipeline and the slot of the texture that its
fragment stage samples. Call `painted` after each 3D frame with the frame's `HistoryMeta`, or with null for a frame that
repeats the last one. When it returns true, pass the frame's image to `add`. Call `paintedLayer` with the image of each
UI layer that is drawn over the frame. Nothing is read back while the game plays.

`ReviewView` shows the ring over a paused game. You step through the frames and mark points, arrows, pen strokes or
boxes on them. Each frame takes a note. Saving builds an `Issue` and passes it to your `onSave` with each marked frame
as a PNG, once plain and once with its marks. `writeIssue` writes these files into the folder of your dump, together
with `issue.json` and lines appended to its README. The `IssueCommands` function that you pass adds lines per frame,
such as the commands that replay it.

## Glitch catcher

`GlitchCatcher` reads back every frame of the ring and compares it with the frames before and after it. A bright,
nearly grey patch that neither neighbour has, while the neighbours agree, is a one-frame artefact. The catcher writes
the three frames and a mask of the flagged pixels into its folder, with one line each in `caught.jsonl`. On macOS,
`WindowSurfaceReader` reads the surface that the window shows after Flutter's compositing. The catcher checks those
frames too. `writeShownFrames` writes the newest frames of the ring into a dump.

## Profiler

`FrameProfiler` writes `frames.jsonl` with one object per frame, `timings.jsonl` with Flutter's frame timings,
`stalls.jsonl` with first-use pipeline compiles and, on close, `summary.txt` with p50, p95 and the maximum of each
section over each of its windows. Call `beginFrame` at the start of each frame and `add` with each timed section. Pass
`stall` to the hook of your renderer for pipeline compiles. `LoopMonitor` measures the time the event loop was held
outside the work that `UiWork` counts. `physFootprint` gives the footprint of the process on macOS.

## Debug panel

`DebugPanelShell` is the panel. It shows your header lines, the frame graph and then your sections on a dark card that
scrolls as a whole. `PanelSection` is a collapsible section whose open state the shell keeps across rebuilds.
`FrameSamples` holds the timings of the last 240 frames in the groups of the graph, each a `FrameGroupStyle` with a
label and a colour. Subclass `FrameSample` and put the time of each section into its groups in `sort`. The graph
repaints every frame on `FrameSamples.graph`, while the rest of the panel can rebuild less often. The build time of the
shell goes into the open frame as `panel.build`.

## Other tools

`installGpuPassLog` writes a line per submitted command buffer with the pass that submitted it, which gives the command
buffers of a Metal System Trace their passes. Set the function that it returns as the submission hook of your
renderer. `HeapSnapshots` writes the heap of the isolate group at chosen game times in profile and debug builds.
`replayPlan` runs a frame plan from its JSON form on a `FrameRunner` of `prismarine_render` and writes the bytes of each
target. `encodePng` encodes RGBA rows as a PNG at zlib level 1.

| Variable | Effect |
|---|---|
| `PRISMARINE_CATCH_SAVE` | `<t0>:<t1>` keeps every window frame between those game times in `window_all/`. |
| `PRISMARINE_HEAP_SNAPSHOT` | `<dir>:<t>,<t>…` writes a heap snapshot into the folder at each game time. |
| `PRISMARINE_REPLAY_BENCH` | `<n>` records a replayed plan n more times and logs the time of the record. |
| `PRISMARINE_REPLAY_MIP` | `<m>` writes mip m of each replayed target too. |

Each variable also reads its `MCSM_` form when the `PRISMARINE_` form is not set.

## Checks

Run `flutter test` in `packages/prismarine_debug`.
