# prismarine_profiler

The profiler finds the memory that a Dart app holds and the code that allocates it. It compares heap snapshots by
retaining path, reports allocation by call site with a flame graph and profiles windows of game time through the VM
service. The details are on [the area page](../../docs/areas/profiler.md).

## Usage

Run a tool from the root of the repository after `dart pub get`. `--help` prints the usage of a tool that has one.

| Tool | Use |
|---|---|
| `bin/heap_diff.dart <a.dartheap> <b.dartheap>…` | Compares heap snapshot files by retaining path and prints the growths |
| `bin/heap_owners.dart <ws> <frames.jsonl> <t>…` | Sums the heap of a running app by owner at game times |
| `bin/heap_report.dart heap\|live <ws> <frames.jsonl> …` | Groups the objects of chosen classes by retaining path, or prints their bytes over time |
| `bin/alloc_sites.dart <ws> <seconds> [out.json]` | Reports allocation by call site, weighted by bytes, on a VM with the heap sample patch |
| `bin/alloc_flame.dart <sites.json>` | Draws the stacks of an `alloc_sites` report as a flame graph in HTML or as a text tree |
| `bin/profile.dart <ws> <frames.jsonl> <outDir> <name>:<t0>:<t1>…` | Records CPU samples, GC pauses and the heap by class for windows of game time |
| `bin/observe.dart <outDir> "<name>:<t0>:<t1>…" <script> [args…]` | Runs a headless Dart program under the VM service and profiles it with `profile.dart` |

`<ws>` is the WebSocket URI of the VM service of a profile build. `frames.jsonl` is the clock file, one line per frame
with its game time, such as `{"t": 12.5}`. `FrameProfiler` of `prismarine_debug` writes it.

| Variable | Effect |
|---|---|
| `PRISMARINE_PROFILE_PERIOD` | The sampling period of `profile.dart` in µs, 1000 by default |
| `PRISMARINE_PROFILE_TRACE` | Classes, separated by commas, whose allocations `profile.dart` records with their stacks |
| `PRISMARINE_PROFILE_OURS` | Texts, separated by commas, of the file paths of own code for those stacks. By default every file outside the SDK and the pub cache is own code |
| `PRISMARINE_PROFILE_RAW` | A folder that gets the stack of every CPU sample of `profile.dart` |
| `PRISMARINE_OBSERVE_CLOCK` | The clock file of the program of `observe.dart`, `<outDir>/frames.jsonl` by default |
| `PRISMARINE_OBSERVE_DART_FLAGS` | Flags of the VM for the program of `observe.dart`, such as `--no-inline-alloc` |
| `PRISMARINE_OBSERVE_TIMEOUT` | The seconds after which `observe.dart` stops the program, 1800 by default |
| `PRISMARINE_PROFILER_PACKAGES` | The package config of `profile.dart` for `observe.dart` in a checkout without one, such as a checkout in the pub cache |

The `PROFILE_` and `OBSERVE_` forms of the variables are read when the `PRISMARINE_` forms are not set.
`PRISMARINE_OBSERVE_CLOCK` reads `BENCH_FRAMES` and the program gets the path in both variables.

## Example

Two snapshots of a profile build, at 60 s and at 600 s of game time, compared by retaining path:

    PRISMARINE_HEAP_SNAPSHOT=/tmp/heap:60,600 <your app>
    dart run tools/profiler/bin/heap_diff.dart /tmp/heap/heap-60.dartheap /tmp/heap/heap-600.dartheap --min=2

Allocation by call site between 30 s and 40 s of game time, per frame, then as a flame graph:

    dart run tools/profiler/bin/alloc_sites.dart <ws> 600 /tmp/sites.json \
      --clock=<run>/frames.jsonl --from=30 --to=40 --once
    dart run tools/profiler/bin/alloc_flame.dart /tmp/sites.json --html=/tmp/flame.html

## Platforms

The tools run on macOS, Linux and Windows.

## Checks

Run `dart test` in `tools/profiler`. The test of `heap_diff` writes two heap snapshots of the test process and takes a
few seconds.
