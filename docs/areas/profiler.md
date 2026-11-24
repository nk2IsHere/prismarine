# Profiler

The tools in `tools/profiler/`, the package `prismarine_profiler`, find the memory that a Dart app holds and the code
that allocates it. They read heap snapshots and attach to the VM service of a profile build. The heap snapshots come
from `HeapSnapshots` of `prismarine_debug` and the clock of game time from the `frames.jsonl` of its `FrameProfiler`.
The [README](../../tools/profiler/README.md) lists the tools, their options and the variables.

## Heap snapshots

`heap_diff` reads snapshot files and builds the dominator tree of each with `HeapDominators`. The retained size of an
object is its own size and its external memory, summed over the objects that it dominates. The external memory is the
size that finalizers report, such as for the buffers and textures of Flutter GPU. Weak references, finalizer entries
and the entries of an Expando whose key is not reached by another path do not retain. The tool groups the retained
sizes by the path of classes and fields from the root and prints the groups side by side for each snapshot, then the
largest growths and the classes. A closure and a context show the name of their function. In a path, `#<n>` is the
slot of the root that holds the roots of one isolate and `~` marks an object that is reached by more than one path.
`--who=<path end>` prints the referrers of a group.

A snapshot of 1 GB takes about 2 minutes and 10 GB of memory. For a large snapshot, compile the tool first with
`dart compile exe tools/profiler/bin/heap_diff.dart`, with `--target-os` and `--target-arch` for another machine.

`heap_owners` and `heap_report` take their snapshots from a running app at game times. `heap_owners` sums every object
under the first classes of own code on its path from the roots. `--ours` selects the libraries of own code.
`heap_report heap` groups the objects of chosen classes, such as `_Uint8List`, by their first retaining path.

## Allocation sites

`alloc_sites` needs the Dart patch `dart/0001` of the engine fork in a profile engine and a profile build of the app.
With `--no-inline-alloc` and `--heap_sample_traces=<bytes>` as Dart flags, the VM records one allocation per that many
bytes as an allocation trace with its weight in bytes. A Flutter app takes its Dart flags in one `dart-flags` engine
switch with commas between them, such as `--no-inline-alloc,--heap_sample_traces=65536`. The engine refuses
`--profiler` there, and `alloc_sites` turns the profiler on through the VM service. AOT code must be compiled with
`--no-inline-alloc` too, through `--extra-gen-snapshot-options` of `flutter build`. The tool prints the bytes per
frame by class, by site and by function and writes every stack to its JSON. `alloc_flame` draws these stacks as a flame
graph, where the many small allocations of one piece of code add up.

Use `--once`. A read every second over the time since the last read loses the samples that reach the buffer late, about
40 % of them in a real-time app. Compare the total of a report with the GC log of the same run, `--verbose_gc` beside
the sampling, before you trust it. A profile build boxes some doubles that a release build keeps unboxed. Measure the
effect of a change on a release build with `--verbose_gc`.

## VM-service profiler

`profile.dart` records CPU samples, GC pauses and the heap by class for windows of game time and writes one JSON per
window. The allocation profile of the VM gives the contents of the heap and not an allocation rate. Its accumulated
figures equal the current ones and its reset does not clear them. `observe.dart` runs a headless Dart program under
the VM service and profiles it the same way. The program writes the clock file itself.

## Checks

Run `dart test` in `tools/profiler`. The test of the heap tools writes heap snapshots of the test process.
