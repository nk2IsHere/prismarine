import 'dart:math' as math;

import '../wav.dart';

import 'engine.dart';

/// Audio in lockstep with the runtime (capture mode): the engine renders up
/// to the runtime's time, and commands land at their runtime time, exactly.
class LockstepAudio implements AudioSink {
  LockstepAudio(this.engine, {this.wav, this.record});
  final AudioRenderer engine;
  final WavWriter? wav;

  /// Sees every command with the frame it applies at (null: at the render
  /// head), e.g. to write a session log (session.dart).
  final void Function(int? frame, AudioCommand c)? record;

  /// Renders up to [seconds] of runtime time.
  void advanceTo(double seconds) {
    final target = (seconds * 48000).round();
    while (engine.position < target) {
      final n = math.min(1024, target - engine.position);
      final b = engine.render(n);
      wav?.add(b);
    }
  }

  /// [c] at runtime time [at] (seconds), or at the render head.
  @override
  void command(AudioCommand c, {double? at}) {
    final frame = at == null ? null : (at * 48000).round();
    record?.call(frame ?? engine.position, c);
    frame == null ? engine.apply(c) : engine.schedule(c, at: frame);
  }
}
