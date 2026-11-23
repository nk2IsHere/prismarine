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
