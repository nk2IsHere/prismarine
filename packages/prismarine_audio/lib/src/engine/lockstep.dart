import 'dart:math' as math;

import '../wav.dart';

import 'engine.dart';

/// An [AudioSink] in lockstep with a game. The renderer renders up to the
/// game's time, and each command applies at the frame of its game time.
class LockstepAudio implements AudioSink {
  LockstepAudio(this.engine, {this.wav, this.record});
  final AudioRenderer engine;
  final WavWriter? wav;

  /// Receives every command with the frame that it applies at, which is the
  /// render head for a command without a time.
  final void Function(int? frame, AudioCommand c)? record;

  /// Renders up to [seconds] of game time.
  void advanceTo(double seconds) {
    final target = (seconds * 48000).round();
    while (engine.position < target) {
      final n = math.min(1024, target - engine.position);
      final b = engine.render(n);
      wav?.add(b);
    }
  }

  /// Applies [c] at the game time [at] in seconds, or at the render head.
  @override
  void command(AudioCommand c, {double? at}) {
    final frame = at == null ? null : (at * 48000).round();
    record?.call(frame ?? engine.position, c);
    frame == null ? engine.apply(c) : engine.schedule(c, at: frame);
  }
}
