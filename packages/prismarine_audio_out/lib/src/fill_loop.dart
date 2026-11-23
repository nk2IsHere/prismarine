import 'dart:async';
import 'dart:typed_data';

/// Keeps rendered − consumed ≥ [lead] seconds at 48 kHz by rendering blocks
/// of [block] frames into [push]. It polls every [period] on the isolate
/// that owns it, the render isolate. Hitches of the UI isolate then cannot
/// starve the stream.
class FillLoop {
  FillLoop({
    required double Function() consumed,
    required Float32List Function(int frames) render,
    required void Function(Float32List block) push,
    required this.lead,
    required this.block,
    this.period = const Duration(milliseconds: 5),
    this.onError,
  }) : _consumed = consumed,
       _render = render,
       _push = push;

  final double Function() _consumed;
  final Float32List Function(int frames) _render;
  final void Function(Float32List block) _push;
  final double lead;
  final int block;
  final Duration period;

  /// Receives the error of a block whose render threw. The block plays as
  /// silence and the loop continues. An uncaught error would end the isolate
  /// with the stream and the audible clock that an app may use for pacing.
  final void Function(Object error, StackTrace stack)? onError;

  Timer? _timer;
  var _stopped = false;
  var _requested = 0;

  /// The number of frames rendered and pushed so far.
  int get requestedFrames => _requested;

  /// Polls once and renders until the lead is met.
  void fill() {
    if (_stopped) return;
    while (_requested / 48000 - _consumed() < lead) {
      Float32List b;
      try {
        b = _render(block);
      } catch (e, st) {
        onError?.call(e, st);
        b = Float32List(block * 2);
      }
      _push(b);
      _requested += block;
    }
  }

  /// Fills now and every [period].
  void start() {
    fill();
    _timer ??= Timer.periodic(period, (_) => fill());
  }

  /// Stops for good. [fill] does nothing afterwards.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}
