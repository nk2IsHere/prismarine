# prismarine_debug

prismarine_debug holds debug tools for a real-time game on Flutter. It has a ring of the frames that the window showed,
a review that marks problems on them and saves an issue, a glitch catcher, a per-frame profiler, a log of GPU passes,
heap snapshots, the replay of a frame plan and a debug panel with a frame graph. The details are on [the area
page](../../docs/areas/debug.md).

## Usage

`FrameSamples` keeps the timings of the last 240 frames in the groups of the frame graph. You subclass `FrameSample` and
sort the time of each section into a group in `sort`. Call `beginFrame` at the start of a frame, `add` on the sample
with each timed section and `endFrame` at its end. `DebugPanelShell` shows your header lines, the frame graph and your
sections. A `PanelSection` keeps its open state across rebuilds.

`FrameHistory` keeps the last seconds of shown frames in a ring of textures. `ReviewView` shows the ring over a paused
game, where you mark frames and save an `Issue`, which `writeIssue` writes into a folder. `GlitchCatcher` compares each
frame of the ring with its neighbours and saves one-frame artefacts. `FrameProfiler` writes the timings of each frame as
JSON lines. `installGpuPassLog`, `HeapSnapshots` and `replayPlan` cover the GPU passes, the heap and the replay of a
saved plan.

The package needs the flutter_gpu of the patched engine. Its pubspec takes it from `third_party/flutter_gpu` through
`dependency_overrides`.

## Example

The example times each frame into two groups and shows the panel with one section of its own. It is
[`example/example.dart`](example/example.dart):

```dart
import 'package:flutter/material.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

/// The groups of the frame graph, bottom to top.
final groups = [
  FrameGroupStyle('game', const Color(0xFF4FC3F7)),
  FrameGroupStyle('render', const Color(0xFFFFB74D)),
];

/// A frame's sample. It sorts each timed section into its group.
class GameSample extends FrameSample {
  GameSample() : super(2);

  @override
  void sort(String section, double v) {
    ms[section.startsWith('render') ? 1 : 0] += v;
  }
}

class GameSamples extends FrameSamples {
  GameSamples() : super(groups);

  @override
  FrameSample newSample() => GameSample();
}

final samples = GameSamples();

/// Times one frame of the game into the graph.
void frame(void Function() update, void Function() render) {
  final f = samples.beginFrame();
  final sw = Stopwatch()..start();
  update();
  f.add('game.update', sw.elapsedMicroseconds / 1000);
  sw.reset();
  render();
  f.add('render.record', sw.elapsedMicroseconds / 1000);
  samples.endFrame(f);
}

/// The debug panel with a header line and one section of your own.
Widget debugPanel(int objects) => DebugPanelShell(
  samples: samples,
  header: (context, p) => [
    Text('${samples.fps.toStringAsFixed(0)} fps', style: p.text.titleSmall),
  ],
  sections: (context, p) => [
    PanelSection(
      'Scene',
      open: p.open,
      children: [Text('$objects objects', style: p.small)],
    ),
  ],
);
```

## Platforms

The package runs in Flutter apps on macOS, Linux and Windows. `WindowSurfaceReader` reads the surface of the window
after compositing. It and `physFootprint` are for macOS only. Heap snapshots work in profile and debug builds.
