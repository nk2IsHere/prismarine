# prismarine_loop

prismarine_loop holds parts of a real-time frame loop on Flutter. These are frame pacing, GC pacing, a frame limiter for
Metal, a memory census, a JSON-lines writer and the focus, cursor and mouse-look state of a desktop window. The details
are on [the area page](../../docs/areas/loop.md).

## Usage

`FramePace` steps the game on every n-th display frame, with n from 1 to 4. A scene that the machine cannot draw at the
full rate then plays evenly at a half, a third or a quarter of it. Call `begin` at the start of each tick with the time
in microseconds. It returns -1 for a tick that steps nothing. `stepSeconds` gives the game time of the step. Call `end`
after the step with the times of its stages. The pace changes its rate at most once a second.

`GcPacing` keeps the idle collections of the Dart VM out of the frame. Call `beginFrame` when a frame starts and
`endFrame` when its Dart work is done. With the patched engine you pass the calls of flutter_gpu for collections at the
idle point of the frame and for the compaction of the old space at a scene switch.

`MetalFrameLimiter.create` returns a limiter on macOS and null elsewhere. Call its `beginFrame` at the start of every
frame. It bounds the frames in flight on Metal to two.

`JsonLineWriter` writes one JSON object per line without allocating. `MemLog` gives each isolate a census line at an
interval. `WindowFocus`, `OsCursorHider` and `MouseLook` hold the focus, cursor and mouse-look state of a game window.
Your runner provides their native side, which the area page describes.

## Example

The example is a game loop on a `Ticker`. It is [`example/example.dart`](example/example.dart):

```dart
import 'package:flutter/scheduler.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

/// A game loop on the frames of Flutter. The game steps on every n-th
/// display frame. The Dart VM collects between frames.
class GameLoop {
  GameLoop(this.step);

  /// Advances the game by the given seconds.
  final void Function(double seconds) step;

  final pace = FramePace();
  final gc = GcPacing(enabled: true);
  final limiter = MetalFrameLimiter.create();
  final clock = Stopwatch()..start();
  late final ticker = Ticker(_tick);

  void start() => ticker.start();

  void _tick(Duration _) {
    limiter?.beginFrame();
    gc.beginFrame();
    final now = clock.elapsedMicroseconds;
    if (pace.begin(now) >= 0) {
      final started = clock.elapsedMicroseconds;
      step(pace.stepSeconds);
      final simMs = (clock.elapsedMicroseconds - started) / 1000;
      pace.end(
        clock.elapsedMicroseconds,
        presented: true,
        shown: 0,
        simMs: simMs,
        uiMs: 0,
        buildMs: 0,
        gpuMs: 0,
      );
    }
    gc.endFrame();
  }

  void stop() {
    ticker.dispose();
    gc.stop();
  }
}
```

## Platforms

The package runs in Flutter apps on macOS, Linux and Windows. The frame limiter and the mouse-look host are for macOS
only. The GC calls at the idle point need the patched engine and are left out on the stock engine.
