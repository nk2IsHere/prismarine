# prismarine_replay

prismarine_replay records the input of a game run frame by frame and replays it to the same state. A run also writes
snapshots of its state. A replay starts at the latest one before its target instead of at the beginning. A shadow
process writes the snapshots of a running game. A corpus runner replays a list of runs against a baseline before a
change goes in. The details are on [the area page](../../docs/areas/replay.md).

## Usage

You give the recorder the fields of each frame, such as the keys held and the cursor. `RouteRecorder.addFrame` writes
them as one JSON line after the frame's `dt`. `RouteReader.next` returns them in order on replay. The hash of the
lines so far identifies a route. A snapshot file holds that hash. A replay takes only the snapshots of its own route.

For snapshots, the replay start and the shadow you implement `ReplaySim` on your simulation and `ReplayGame` for your
game. `ReplayGame` makes and boots sims, applies a frame of input and writes and reads the state with the codecs of
`prismarine_snap`. `SnapshotFormat` holds the format string and the version of your snapshot files.

The corpus runner is in `package:prismarine_replay/corpus.dart`. You extend `Corpus` with the data and the recording of
your runs and give it a program that replays one run and writes its fingerprint.

## Example

The example records three frames and replays them. It is [`example/example.dart`](example/example.dart):

```dart
import 'package:prismarine_replay/prismarine_replay.dart';

const format = RouteFormat('exampleRoute');

void main() {
  // A run records the input of each frame.
  final recorder = RouteRecorder(format, {'seed': 1});
  for (final input in [2, 0, 5]) {
    recorder.addFrame(1 / 60, {'add': input});
  }
  // A replay applies the same input frame by frame.
  final route = RouteReader(recorder.lines, format: format);
  var total = 0;
  for (var f = route.next(); f != null; f = route.next()) {
    total += f['add']! as int;
  }
  final hash = routeHashText(route.hashAt(route.length));
  print('total $total, route hash $hash');
}
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools. The shadow and
the corpus runner start processes and need `dart:io`. `tool/corpus_remote.sh` runs on macOS and Linux and needs ssh and
rsync.
